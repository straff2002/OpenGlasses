import Foundation

/// Apple Music on the phone (Plan GS P0 + MusicKit phase).
///
/// Two paths, one provider:
/// - **Catalogue** (MusicKit): when the wearer has allowed Apple Music access and their account can
///   play catalogue content, play-by-name searches the whole Apple Music catalogue and plays the
///   best match on the system player.
/// - **Library** (MediaPlayer): otherwise — and whenever the catalogue finds nothing — it plays
///   from the wearer's own library, exactly as the tool always has.
///
/// It is never a dead end: a catalogue miss falls through to the library, and when the library has
/// nothing either the answer is one sentence that says why (no subscription, no access, Medical
/// Local Only). Both seams are injected; tests never reach MediaPlayer or MusicKit.
@MainActor
final class AppleMusicProvider: MusicProvider {

    let id: MusicProviderID = .appleMusic
    let capabilities: Set<MusicCapability> = [.transport, .nowPlaying, .playByName, .search, .addToLibrary]

    private let library: MusicLibraryPlaying
    private let catalog: MusicCatalogServing
    private let catalogueAllowed: () -> Bool
    private let canPromptForAccess: () -> Bool

    /// - Parameters:
    ///   - catalogueAllowed: false under Medical Local Only — catalogue search terms go to Apple,
    ///     so they stay on the phone and only the library is searched.
    ///   - canPromptForAccess: whether the system permission prompt can be shown now (the app is
    ///     in the foreground). A locked phone cannot show it.
    init(library: MusicLibraryPlaying,
         catalog: MusicCatalogServing,
         catalogueAllowed: @escaping () -> Bool,
         canPromptForAccess: @escaping () -> Bool) {
        self.library = library
        self.catalog = catalog
        self.catalogueAllowed = catalogueAllowed
        self.canPromptForAccess = canPromptForAccess
    }

    // MARK: - Catalogue access

    enum CatalogueAccess: Equatable {
        case available
        case noSubscription
        case blockedLocalOnly
        case denied
        /// Access was never asked for and the prompt cannot be shown right now.
        case needsPhone
        /// The subscription check failed (offline, service error).
        case unavailable
    }

    func catalogueAccess() async -> CatalogueAccess {
        guard catalogueAllowed() else { return .blockedLocalOnly }
        var status = catalog.authorizationStatus
        if status == .notDetermined {
            guard canPromptForAccess() else { return .needsPhone }
            status = await catalog.requestAuthorization()
        }
        switch status {
        case .authorized: break
        case .notDetermined: return .needsPhone
        case .denied, .restricted: return .denied
        }
        switch await catalog.canPlayCatalogContent() {
        case true?: return .available
        case false?: return .noSubscription
        case nil: return .unavailable
        }
    }

    // MARK: - MusicProvider

    func nowPlaying(speaker: MusicSpeaker?) async -> NowPlayingSummary? {
        library.nowPlaying()
    }

    func perform(_ command: MusicCommand, speaker: MusicSpeaker?) async -> MusicCommandResult {
        switch command {
        case .play:
            library.play()
            return .done(transportLine("Playing", fallback: "Playing."))
        case .pause:
            library.pause()
            return .done("Music paused.")
        case .toggle:
            if library.isPlaying {
                library.pause()
                return .done("Music paused.")
            }
            library.play()
            return .done(transportLine("Playing", fallback: "Playing."))
        case .next:
            library.skipToNext()
            return .done(transportLine("Skipped to", fallback: "Skipped."))
        case .previous:
            library.skipToPrevious()
            return .done(transportLine("Going back to", fallback: "Went back."))
        case .shuffle:
            library.shuffleAll()
            return .done("Shuffling your library.")
        case .volumeUp, .volumeDown, .volumeSet:
            return .unsupported("Avenkin can't change the phone's volume. Use the volume buttons, or name a speaker.")
        case .nowPlaying:
            return .done(MusicPhraser.nowPlaying(library.nowPlaying()))
        case .search(let query):
            return await search(query)
        case .playByName(let request):
            return await play(request)
        case .addToLibrary(let request):
            return await addToLibrary(request)
        case .devices:
            return .unsupported(MusicPhraser.speakersNeedHomeAssistant)
        }
    }

    // MARK: - Play by name

    private func play(_ request: MusicPlayRequest) async -> MusicCommandResult {
        guard !request.phrase.isEmpty else { return .failed("What should I play?") }
        let access = await catalogueAccess()
        var catalogueFailed = false
        if access == .available {
            do {
                let candidates = try await catalog.search(term: request.searchTerm,
                                                          kinds: Self.searchKinds(for: request.kind), limit: 10)
                if let best = MusicCatalogRanker.best(for: request, among: candidates) {
                    try await catalog.play(best, shuffle: request.shuffle || best.kind == .artist)
                    return .done(MusicPhraser.playing(best))
                }
            } catch {
                catalogueFailed = true
            }
        }

        if let match = library.play(request) {
            return .done(MusicPhraser.playingFromLibrary(match))
        }

        switch access {
        case .available:
            return .failed(catalogueFailed
                           ? MusicPhraser.notInLibrary(request) + " " + MusicPhraser.catalogueUnavailable
                           : MusicPhraser.notFound(request))
        case .noSubscription:
            return .failed(MusicPhraser.needsSubscription(request))
        case .blockedLocalOnly:
            return .failed(MusicPhraser.notInLibrary(request) + " " + MusicPhraser.catalogueBlockedLocalOnly)
        case .denied:
            return .failed(MusicPhraser.accessDenied)
        case .needsPhone:
            return .failed(MusicPhraser.accessNeedsPhone)
        case .unavailable:
            return .failed(MusicPhraser.notInLibrary(request) + " " + MusicPhraser.catalogueUnavailable)
        }
    }

    /// The catalogue types a search asks for.
    static func searchKinds(for kind: MusicItemKind) -> [MusicItemKind] {
        kind == .any ? [.song, .album, .artist, .playlist, .station] : [kind]
    }

    // MARK: - Search

    private func search(_ query: String) async -> MusicCommandResult {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failed("What should I search for?") }
        // Search needs access but not a subscription: anyone can browse the catalogue.
        if catalogueAllowed(), await accessForBrowsing() {
            do {
                let request = MusicRequestParser.request(from: trimmed)
                let candidates = try await catalog.search(term: request.searchTerm,
                                                          kinds: Self.searchKinds(for: request.kind), limit: 10)
                let top = MusicCatalogRanker.ranked(for: request, among: candidates).prefix(5).map(\.candidate)
                if !top.isEmpty { return .done(MusicPhraser.searchResults(Array(top))) }
            } catch {
                // Fall through to the library.
            }
        }
        return .done(MusicPhraser.librarySearchResults(library.search(trimmed, limit: 5), query: trimmed))
    }

    private func accessForBrowsing() async -> Bool {
        var status = catalog.authorizationStatus
        if status == .notDetermined, canPromptForAccess() {
            status = await catalog.requestAuthorization()
        }
        return status == .authorized
    }

    // MARK: - Add to library

    private func addToLibrary(_ request: MusicPlayRequest?) async -> MusicCommandResult {
        switch await catalogueAccess() {
        case .available: break
        case .noSubscription: return .failed(MusicPhraser.addNeedsSubscription)
        case .blockedLocalOnly: return .failed(MedicalEgressRefusal.userMessage)
        case .denied: return .failed(MusicPhraser.accessDenied)
        case .needsPhone: return .failed(MusicPhraser.accessNeedsPhone)
        case .unavailable: return .failed("Apple Music isn't answering right now. Try again in a moment.")
        }

        let candidate: MusicCatalogCandidate
        do {
            if let request, !request.phrase.isEmpty {
                let found = try await catalog.search(term: request.searchTerm,
                                                     kinds: Self.addableKinds(for: request.kind), limit: 10)
                guard let best = MusicCatalogRanker.best(for: request, among: found) else {
                    return .failed(MusicPhraser.notFound(request))
                }
                candidate = best
            } else {
                guard let id = library.nowPlaying()?.catalogID,
                      let song = try await catalog.song(catalogID: id) else {
                    return .failed(MusicPhraser.nothingToAdd)
                }
                candidate = song
            }
        } catch {
            return .failed("Apple Music isn't answering right now. Try again in a moment.")
        }

        do {
            try await catalog.addToLibrary(candidate)
            return .done(MusicPhraser.addedToLibrary(title: candidate.title, artist: candidate.artist))
        } catch MusicCatalogFailure.alreadyInLibrary {
            return .done(MusicPhraser.alreadyInLibrary(title: candidate.title))
        } catch MusicCatalogFailure.notSubscribed {
            return .failed(MusicPhraser.addNeedsSubscription)
        } catch MusicCatalogFailure.notAuthorized {
            return .failed(MusicPhraser.accessDenied)
        } catch {
            return .failed("I couldn't add that to your library just now.")
        }
    }

    /// Only songs, albums and playlists can be added to a library; artists and stations cannot.
    static func addableKinds(for kind: MusicItemKind) -> [MusicItemKind] {
        switch kind {
        case .song, .album, .playlist: return [kind]
        default: return [.song, .album, .playlist]
        }
    }

    // MARK: - Helpers

    private func transportLine(_ prefix: String, fallback: String) -> String {
        guard let summary = library.nowPlaying(), let title = summary.title else { return fallback }
        if let artist = summary.artist, !artist.isEmpty { return "\(prefix) \(title) by \(artist)." }
        return "\(prefix) \(title)."
    }
}
