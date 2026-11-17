import Foundation

/// A link that offers an add-on: `openglasses://install-addon?url=https://…` (or `avenkin://`).
/// A QR code carries the same link.
struct AddOnLinkRequest: Equatable, Sendable {
    let fileURL: URL
}

/// The ways an add-on file reaches the phone, as pure checks (Plan GF P2).
///
/// Like the skill-pack and vault links, `install-addon` is outside the `DeepLinkTrust` token gate:
/// a scanned code cannot carry the app-group token, and the link never acts on its own. It raises
/// a question naming the host; only a yes fetches (over the hardened client, one small JSON file,
/// HTTPS only); the file is validated; and only the sheet's button installs.
enum AddOnIngest {

    static let linkHost = "install-addon"
    /// The extension of an add-on file shared by AirDrop, Mail or Files.
    static let fileExtension = "addon"

    enum ParseError: Error, Equatable {
        case notAnAddOnLink
        case missingURL
        /// Not `https`, or carrying a user, a password or a fragment.
        case insecureSource
    }

    static func parse(_ url: URL) -> Result<AddOnLinkRequest, ParseError> {
        guard DeepLinkScheme.isApp(url), url.host == linkHost else { return .failure(.notAnAddOnLink) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value, !raw.isEmpty,
              let fileURL = URL(string: raw) else {
            return .failure(.missingURL)
        }
        guard isPermittedSource(fileURL) else { return .failure(.insecureSource) }
        return .success(AddOnLinkRequest(fileURL: fileURL))
    }

    /// HTTPS to a named host, with no credentials or fragment. There is no plain-HTTP or LAN
    /// exception: an add-on file is small and public, and the hardened client refuses private
    /// addresses anyway.
    static func isPermittedSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        if let port = url.port, port != 443 { return false }
        return true
    }

    /// An `.addon` file, offered by the system.
    static func isAddOnFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    /// Whether bytes say they are an add-on — a bare file or its signed envelope — by their
    /// `format` tag. Used to tell an add-on saved as `.json` from the other JSON the app opens; the
    /// validator still judges everything.
    static func looksLikeAddOn(_ data: Data) -> Bool {
        guard data.count <= AddOnSignature.maxEnvelopeBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = object["format"] as? String else { return false }
        return format == RecipeAddOnManifest.formatTag || format == AddOnSignature.envelopeFormat
    }

    /// Read a file the system handed over, refusing anything larger than an envelope can be.
    static func readFile(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= AddOnSignature.maxEnvelopeBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The host a link names, as the question shows it.
    static func displayHost(_ url: URL) -> String { url.host?.lowercased() ?? "unknown" }
}

/// The add-on sheets' state machine (Plan GF P2): a link's fetch question, the install and update
/// sheets, a source edit that grew, and what happened. Nothing is written until `accept`.
@MainActor
final class AddOnInstallService: ObservableObject {

    struct FetchOffer: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let host: String
        let expiresAt: Date
    }

    /// What a sheet is showing, and what its button will do.
    struct Review: Identifiable, Equatable {
        enum Kind: Equatable {
            case install
            case update(AddOnUpdateDiff?)
            /// A source edit that may now do more than the installed version.
            case edit(AddOnUpdateDiff)
        }
        let id: UUID
        let candidate: AddOnCandidate
        let kind: Kind
        let origin: AddOnOrigin
        /// For an add-on the assistant built: what its test did, for the sheet's Tested panel.
        var tested: AddOnTestedSummary? = nil
    }

    enum Prompt: Identifiable, Equatable {
        case confirmFetch(FetchOffer)
        case fetching(String)
        case review(Review)
        case refused([String])
        case done(String)

        var id: String {
            switch self {
            case .confirmFetch(let offer): return "fetch-\(offer.id)"
            case .fetching(let host): return "fetching-\(host)"
            case .review(let review): return "review-\(review.id)"
            case .refused(let lines): return "refused-\(lines.joined(separator: "|"))"
            case .done(let message): return "done-\(message)"
            }
        }
    }

    @Published var prompt: Prompt?

    static let offerLifetime: TimeInterval = 5 * 60

    private let store: AddOnStore
    private let context: @MainActor () -> AddOnAdmission.Context
    private let fetch: (URL) async throws -> Data
    private let networkDecision: UntrustedNetworkFeaturePolicy.Decision
    private let now: () -> Date
    /// Called after anything is installed or saved, to rebuild the registry. Settable so the app
    /// can wire it once it exists.
    var onChange: @MainActor () -> Void
    /// Told when the wearer accepts or turns down the sheet for an add-on the assistant built, so
    /// its draft and test trace are deleted either way (kept only as the installed add-on).
    var onSelfBuiltResolved: (@MainActor (_ sessionID: String, _ installed: Bool) -> Void)?
    private var pendingOffer: FetchOffer?

    init(store: AddOnStore,
         context: @escaping @MainActor () -> AddOnAdmission.Context,
         fetch: @escaping (URL) async throws -> Data = AddOnInstallService.liveFetch,
         networkDecision: UntrustedNetworkFeaturePolicy.Decision =
            UntrustedNetworkFeaturePolicy.currentDecision(for: .addOnDeepLinkFetch),
         now: @escaping () -> Date = Date.init,
         onChange: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.context = context
        self.fetch = fetch
        self.networkDecision = networkDecision
        self.now = now
        self.onChange = onChange
    }

    // MARK: - Arrivals

    /// A link arrived. Nothing is fetched: the wearer is asked first, with the host named.
    func open(_ request: AddOnLinkRequest) {
        pendingOffer = nil
        guard networkDecision.allowsRequest else {
            prompt = .refused([UntrustedNetworkFeaturePolicy.unavailableMessage])
            return
        }
        let offer = FetchOffer(id: UUID(), url: request.fileURL, host: AddOnIngest.displayHost(request.fileURL),
                               expiresAt: now().addingTimeInterval(Self.offerLifetime))
        pendingOffer = offer
        prompt = .confirmFetch(offer)
    }

    /// The wearer said yes to fetching. Single use, and only for the offer still showing.
    func approveFetch(_ offer: FetchOffer) async {
        guard let pending = pendingOffer, pending == offer else {
            prompt = .refused([String(localized: "That request is no longer valid. Open the link again.")])
            return
        }
        pendingOffer = nil
        guard now() <= offer.expiresAt else {
            prompt = .refused([String(localized: "That request expired. Open the link again.")])
            return
        }
        prompt = .fetching(offer.host)
        let data: Data
        do {
            data = try await fetch(offer.url)
        } catch {
            prompt = .refused([String(localized: "Couldn't get the add-on from \(offer.host).")])
            return
        }
        receive(data, origin: .installed(via: .link))
    }

    /// A file opened from Files, AirDrop or Mail.
    func openFile(_ url: URL) {
        guard let data = AddOnIngest.readFile(url) else {
            prompt = .refused([String(localized: "That file couldn't be read, or it's too large to be an add-on.")])
            return
        }
        receive(data, origin: .installed(via: .file))
    }

    /// Bytes from any source — a link, a file, the gallery, or the assistant (with `.selfBuilt`
    /// provenance and what its test did). Admission runs; the sheet shows what it found.
    func receive(_ data: Data, origin: AddOnOrigin, tested: AddOnTestedSummary? = nil) {
        // A snapshot of what is installed, so the pure review reads values rather than the store.
        var installed: [String: AddOnAdmission.Installed] = [:]
        for row in store.installed { installed[row.id] = store.admissionInstalled(id: row.id) }
        let outcome = AddOnAdmission.review(data, installed: { installed[$0] }, context: context())
        switch outcome {
        case .install(let candidate):
            prompt = .review(Review(id: UUID(), candidate: candidate, kind: .install, origin: origin, tested: tested))
        case .update(let candidate, let diff):
            prompt = .review(Review(id: UUID(), candidate: candidate, kind: .update(diff), origin: origin, tested: tested))
        case .refused(let reasons):
            prompt = .refused(reasons)
        }
    }

    /// A source edit that grew: the sheet again before it is saved.
    func reviewEdit(_ candidate: AddOnCandidate, diff: AddOnUpdateDiff) {
        let origin = store.provenance(id: candidate.manifest.id) ?? .installed(via: .file)
        prompt = .review(Review(id: UUID(), candidate: candidate, kind: .edit(diff), origin: origin))
    }

    // MARK: - Answers

    /// The sheet's button. Only the review still showing can be accepted.
    func accept(_ review: Review) {
        guard case .review(let showing) = prompt, showing.id == review.id else { return }
        let result: Result<AddOnStore.InstalledAddOn, AddOnStore.StoreError>
        switch review.kind {
        case .install, .update:
            result = store.install(review.candidate, origin: review.origin)
        case .edit:
            result = store.saveEdit(review.candidate)
        }
        switch result {
        case .success(let row):
            onChange()
            if case .selfBuilt(let provenance) = review.origin, review.tested != nil {
                onSelfBuiltResolved?(provenance.sessionID, true)
            }
            switch review.kind {
            case .install: prompt = .done(String(localized: "\(row.name) is installed."))
            case .update: prompt = .done(String(localized: "\(row.name) is updated to \(row.version)."))
            case .edit: prompt = .done(String(localized: "Your changes to \(row.name) are saved."))
            }
        case .failure(let error):
            prompt = .refused([Self.message(for: error)])
        }
    }

    func dismiss() {
        pendingOffer = nil
        if case .review(let review) = prompt, case .selfBuilt(let provenance) = review.origin, review.tested != nil {
            onSelfBuiltResolved?(provenance.sessionID, false)
        }
        prompt = nil
    }

    static func message(for error: AddOnStore.StoreError) -> String {
        switch error {
        case .unreadable: return String(localized: "Add-ons can't be changed until the phone is unlocked.")
        case .invalidID: return String(localized: "This add-on's id isn't valid.")
        case .notNewer(let installed): return String(localized: "Version \(installed) or newer is already installed.")
        case .notInstalled: return String(localized: "That add-on isn't installed any more.")
        case .writeFailed: return String(localized: "The add-on couldn't be saved.")
        }
    }

    /// One small JSON document over the hardened client: HTTPS only, public addresses only, at most
    /// three redirects, the envelope's size cap.
    nonisolated static func liveFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await BoundedHTTPClient().fetchData(url, profile: .recipeAddOn)
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
