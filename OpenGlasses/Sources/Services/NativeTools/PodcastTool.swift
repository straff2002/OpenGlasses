import Foundation
import UIKit

/// `play_podcast` (Plan JF): "play the latest episode of The Daily" looks the show up in Apple's
/// public podcast directory, picks the episode, and opens it in the Podcasts app.
///
/// Apple offers no API that plays a podcast inside another app's player, so the tool hands the
/// episode's podcasts.apple.com link to the system as a universal link, which the Podcasts app
/// claims. Pausing, skipping and "what's playing" stay with the glasses' temple taps, and the
/// description says so, so the model never promises them. Everything the tool depends on arrives
/// through `PodcastToolEnvironment`, so tests drive it with fakes.
struct PodcastTool: NativeTool {
    let name = "play_podcast"
    #if AVENKIN_PHONE_ONLY
    private static let transport = "It cannot pause, skip or say what Podcasts is playing."
    #else
    private static let transport = "It cannot pause, skip or say what Podcasts is playing — the glasses' temple taps do that."
    #endif
    let description = """
        Play a podcast by name in the Apple Podcasts app. Looks the show up in Apple's podcast directory and opens \
        the chosen episode in Podcasts, which plays it. Use for "play the latest episode of X", "put on the X podcast", \
        "play an episode of X about Y". Actions: play ('query' = the show; optional 'episode' = 'latest' or words \
        from the episode), search ('query' = words; lists matching shows). \(Self.transport) Music and Apple Music go to music_control, not here.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "play (default) or search",
            ],
            "query": [
                "type": "string",
                "description": "The show's name as the wearer said it, e.g. 'The Daily', '99% Invisible'",
            ],
            "episode": [
                "type": "string",
                "description": "Optional: 'latest', or words from the episode the wearer wants ('the one about elevators')",
            ],
        ],
        "required": ["query"],
    ]

    var makeEnvironment: @MainActor () -> PodcastToolEnvironment = { PodcastToolEnvironment.live() }

    func execute(args: [String: Any]) async throws -> String {
        guard MedicalEgressGuard.allows(.podcastDirectory) else { return MedicalEgressRefusal.userMessage }
        let action = (args["action"] as? String)?.lowercased() ?? "play"
        guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return PodcastPhraser.whichPodcast
        }
        let environment = await MainActor.run { makeEnvironment() }

        if action == "search" {
            let shows: [PodcastShow]
            do {
                shows = try await environment.directory.searchShows(matching: MusicRequestParser.spokenForm(query), limit: 5)
            } catch {
                return PodcastPhraser.directoryUnreachable
            }
            return PodcastPhraser.found(shows, for: query)
        }

        guard let request = PodcastRequestParser.parse(query: query, episode: args["episode"] as? String) else {
            return PodcastPhraser.whichPodcast
        }

        let shows: [PodcastShow]
        do {
            shows = try await environment.directory.searchShows(matching: request.show, limit: 5)
        } catch {
            return PodcastPhraser.directoryUnreachable
        }
        guard let show = PodcastRanker.bestShow(for: request, in: shows) else {
            return PodcastPhraser.noShow(request.show)
        }

        let episodes = (try? await environment.directory.episodes(ofShow: show.id, limit: 25)) ?? []
        guard let pick = PodcastRanker.pickEpisode(request.episode, from: episodes) else {
            // The directory listed no episodes: the show's own page is the best there is.
            guard let url = PodcastDeepLink.openable(show.pageURL) else { return PodcastPhraser.noLink(show.title) }
            environment.playbackRequested()
            guard await environment.open(url) else { return PodcastPhraser.podcastsAppMissing }
            return PodcastPhraser.openingShow(show)
        }
        guard let url = PodcastDeepLink.openable(pick.episode.pageURL) else { return PodcastPhraser.noLink(show.title) }
        environment.playbackRequested()
        guard await environment.open(url) else { return PodcastPhraser.podcastsAppMissing }
        return PodcastPhraser.opening(pick, of: show, asked: request.episode)
    }
}

/// What `play_podcast` needs from the world.
struct PodcastToolEnvironment {
    var directory: any PodcastDirectorySearching
    /// Hands a podcasts.apple.com link to the system as a universal link only; false when no app
    /// claims it, which on an iPhone means Podcasts is not installed.
    var open: @MainActor (URL) async -> Bool
    /// Tells the temple-tap trigger to stand down before another player takes Now Playing.
    var playbackRequested: () -> Void

    @MainActor
    static func live() -> PodcastToolEnvironment {
        PodcastToolEnvironment(
            directory: AppleLookupPodcastDirectory(),
            open: { url in
                await withCheckedContinuation { continuation in
                    UIApplication.shared.open(url, options: [.universalLinksOnly: true]) {
                        continuation.resume(returning: $0)
                    }
                }
            },
            playbackRequested: {
                NotificationCenter.default.post(name: MediaTriggerService.userPlaybackRequested, object: nil)
            })
    }
}

/// The sentences `play_podcast` speaks. Pure.
enum PodcastPhraser {
    static let whichPodcast = "Which podcast would you like?"
    static let directoryUnreachable = "I couldn't reach the podcast directory just now."
    static let podcastsAppMissing = "The Podcasts app doesn't seem to be installed on this phone."

    static func noShow(_ name: String) -> String {
        "I couldn't find a podcast called \(name)."
    }

    static func noLink(_ show: String) -> String {
        "I found \(show), but the directory gave no link I can open."
    }

    static func openingShow(_ show: PodcastShow) -> String {
        "Opening \(show.title) in Podcasts."
    }

    static func opening(_ pick: PodcastRanker.EpisodePick, of show: PodcastShow, asked: PodcastEpisodeHint) -> String {
        let episode = pick.episode.title
        switch asked {
        case .unspecified, .latest:
            return "Opening the latest episode of \(show.title) in Podcasts: \(episode)."
        case .about where pick.matchedTopic:
            return "Opening \(episode), from \(show.title), in Podcasts."
        case .about(let topic):
            return "I couldn't find an episode of \(show.title) about \(topic), so I'm opening the latest one in Podcasts: \(episode)."
        }
    }

    static func found(_ shows: [PodcastShow], for query: String) -> String {
        guard !shows.isEmpty else { return "I couldn't find any podcasts matching \(query)." }
        let list = shows.prefix(5).map { show -> String in
            if let author = show.author, !author.isEmpty { return "\(show.title) by \(author)" }
            return show.title
        }.joined(separator: "; ")
        return "Podcasts matching \(query): \(list). Say which one to play."
    }
}
