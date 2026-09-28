import Foundation

/// Plan CT PR 2 — `openglasses://enrol?url=https://…`: an organisation profile arriving by link.
///
/// The first ingress path to ship. Its shape follows the vault link (Plan FS §3), and for
/// the same reasons:
///
/// 1. **Policy.** The route carries one parameter, an `https` address with no credentials or
///    fragment. The host is the only part of it the app ever shows.
/// 2. **Offer.** Nothing is fetched until the person has seen the host and agreed.
/// 3. **Fetch** under a small byte cap — a profile is a few kilobytes of signed text.
/// 4. **Review.** The document is verified (signature, key, both clocks) and the person is shown
///    who it is from, what it locks, what it sets and what this version of the app could not use.
///    A document that fails verification stops here with the reason and no apply button.
/// 5. **Confirm**, and `OrgProfileManager` applies it: licence, settings, ceiling.
///
/// Not `DeepLinkTrust`-gated — a scanned code cannot carry the app-group token — with the same
/// compensating control as the other scanned routes: the link itself never acts.
///
/// **A link that arrives before onboarding has finished is held**, and offered once it has.
/// Applying settings mid-onboarding is the flag-desync hazard Plan CD P1 recorded; holding the link
/// means the first-run path is untouched until PR 3 builds a proper branch for it.
@MainActor
final class OrgEnrolmentService: ObservableObject {

    enum Stage: Equatable {
        case idle
        case offer(host: String)
        case fetching(host: String)
        case reviewing(OrgProfileReview)
        /// Applied, and the profile names an AI model that needs its key or sign-in (Plan CT 3a).
        case modelKey(OrgAIModel, organization: String)
        case applied(String)
        case failed(String)

        var isBusy: Bool {
            if case .fetching = self { return true }
            return false
        }
    }

    enum LinkRefusal: Error, Equatable {
        case notAnEnrolmentLink
        case missingURL
        case insecureSource

        var message: String {
            switch self {
            case .notAnEnrolmentLink, .missingURL: return "That isn't an organisation enrolment link."
            case .insecureSource: return "Organisation profiles are only fetched over a secure (https) connection."
            }
        }
    }

    @Published private(set) var stage: Stage = .idle

    /// How the profile being offered arrived — recorded with it once applied.
    private(set) var source: ProfileSource = .link

    private let manager: OrgProfileManager
    private let fetch: (URL) async throws -> Data
    private let isPastOnboarding: () -> Bool
    private var pendingURL: URL?
    private var heldURL: URL?
    private var activeFetch: Task<Data, Error>?
    /// The licence key that started this enrolment, when one did (Plan CT 3a).
    private var enteredLicence: String?
    private let licenceKey: String
    private let activationResolver: ActivationKeyResolver
    /// Tells the app the active model changed, so what it shows follows.
    private let modelDidChange: @MainActor () -> Void

    /// The organisation a licence key named, while its profile is being fetched — the sheet says
    /// "Setting up this phone for …" rather than naming a host.
    @Published private(set) var settingUpFor: String?

    init(manager: OrgProfileManager,
         fetch: @escaping (URL) async throws -> Data = OrgEnrolmentService.boundedFetch,
         isPastOnboarding: @escaping () -> Bool = { Config.isPastOnboarding },
         licenceKey: String = LicenseService.productionPublicKeyBase64,
         activationResolver: ActivationKeyResolver = ActivationKeyResolver(),
         modelDidChange: @escaping @MainActor () -> Void = {}) {
        self.manager = manager
        self.licenceKey = licenceKey
        self.activationResolver = activationResolver
        self.modelDidChange = modelDidChange
        self.fetch = fetch
        self.isPastOnboarding = isPastOnboarding
    }

    // MARK: - Parsing

    /// Parse `openglasses://enrol?url=…`. HTTPS only; no credentials, no fragment.
    static func parse(_ url: URL) -> Result<URL, LinkRefusal> {
        guard url.scheme == "openglasses", url.host == "enrol" else { return .failure(.notAnEnrolmentLink) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value,
              let target = URL(string: raw) else {
            return .failure(.missingURL)
        }
        guard target.scheme?.lowercased() == "https", target.host != nil,
              target.user == nil, target.password == nil, target.fragment == nil else {
            return .failure(.insecureSource)
        }
        return .success(target)
    }

    static func displayHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? "unknown"
        guard let port = url.port, port != 443 else { return host }
        return "\(host):\(port)"
    }

    // MARK: - A link arrives

    func open(_ url: URL) {
        reset()
        source = .link
        switch Self.parse(url) {
        case .failure(let refusal):
            stage = .failed(refusal.message)
        case .success(let target):
            guard isPastOnboarding() else {
                heldURL = target
                stage = .idle
                return
            }
            offer(target)
        }
    }

    /// A code read by the in-app scanner (Plan CT PR 3). It carries either the enrolment link or
    /// the profile's own `https` address, and either way it goes through the link's policy. Unlike a
    /// link arriving from outside, a scan is never held for onboarding: the person asked for it —
    /// the welcome page is one of the two places the scanner opens from — and applying a profile
    /// writes no API key and no onboarding flag, which is what made mid-onboarding writes hazardous
    /// (Plan CD P1).
    func openScanned(_ text: String) {
        reset()
        source = .scan
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            stage = .failed(LinkRefusal.notAnEnrolmentLink.message)
            return
        }
        let link: URL
        if url.scheme?.lowercased() == "https" {
            var components = URLComponents()
            components.scheme = "openglasses"
            components.host = "enrol"
            components.queryItems = [URLQueryItem(name: "url", value: trimmed)]
            guard let wrapped = components.url else {
                stage = .failed(LinkRefusal.notAnEnrolmentLink.message)
                return
            }
            link = wrapped
        } else {
            link = url
        }
        switch Self.parse(link) {
        case .failure(let refusal): stage = .failed(refusal.message)
        case .success(let target): offer(target)
        }
    }

    /// What entering a licence key should do (Plan CT 3a).
    enum LicenceRoute: Equatable {
        /// No `profile` claim, or not a readable licence: activate it the way a licence always has
        /// (and let `LicenseService` explain a bad one).
        case plain
        /// The licence names its organisation's profile, which is now being fetched for review.
        case enrolling(licensee: String)
        /// The licence names a profile address the link policy refuses.
        case refused(String)
    }

    /// A licence key entered by hand. When its signed `profile` claim names an address, the phone
    /// enrols from it: there is no host offer, because the vendor signed that address — the
    /// licensee's name is what is shown — and the rest is the link's path (the bounded fetch,
    /// verification, the review, one confirmation). Never held for onboarding: the person typed it.
    func openLicence(_ code: String) -> LicenceRoute {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = try? LicenseService.decode(code: trimmed, publicKeyBase64: licenceKey),
              let address = payload.profile else {
            return .plain
        }
        reset()
        source = .licence
        var components = URLComponents()
        components.scheme = "openglasses"
        components.host = "enrol"
        components.queryItems = [URLQueryItem(name: "url", value: address)]
        guard let link = components.url, case .success(let target) = Self.parse(link) else {
            let message = LinkRefusal.insecureSource.message
            stage = .failed(message)
            return .refused(message)
        }
        enteredLicence = trimmed
        settingUpFor = payload.licensee
        Task { await fetchAndReview(target, host: Self.displayHost(target)) }
        return .enrolling(licensee: payload.licensee)
    }

    /// What typed text comes to before the licence path sees it (Plan CT 3a).
    enum KeyEntry: Equatable {
        /// A licence code — typed as one, or the one an activation key resolved to. It goes on to
        /// `openLicence` and activation exactly as if it had been typed.
        case licence(String)
        /// An activation key that is mistyped, unknown, or could not be looked up.
        case refused(String)
    }

    /// A short activation key is checked locally — a typo never reaches the network — then looked
    /// up once on the static host and opened. Anything that is not an attempt at a key is passed
    /// through untouched.
    func resolveEntry(_ text: String) async -> KeyEntry {
        switch ActivationKey.read(text) {
        case .notAKey:
            return .licence(text)
        case .invalid(let problem):
            return .refused(problem.errorDescription ?? "")
        case .key(let key):
            do {
                return .licence(try await activationResolver.resolve(key))
            } catch {
                return .refused((error as? LocalizedError)?.errorDescription ?? "")
            }
        }
    }

    /// Onboarding has just finished: offer the link that arrived during it.
    func releaseHeldLink() {
        guard let held = heldURL, isPastOnboarding() else { return }
        heldURL = nil
        source = .link
        offer(held)
    }

    var hasHeldLink: Bool { heldURL != nil }

    private func offer(_ target: URL) {
        pendingURL = target
        stage = .offer(host: Self.displayHost(target))
    }

    // MARK: - Fetch and review

    func approveFetch() async {
        guard case .offer(let host) = stage, let target = pendingURL else { return }
        pendingURL = nil
        await fetchAndReview(target, host: host)
    }

    private func fetchAndReview(_ target: URL, host: String) async {
        stage = .fetching(host: host)
        let request = Task { [fetch] in try await fetch(target) }
        activeFetch = request
        let data: Data
        do {
            data = try await request.value
        } catch {
            guard case .fetching = stage else { return }
            activeFetch = nil
            if let licensee = settingUpFor {
                stage = .failed("Setting this phone up for \(licensee) needs the internet once. Connect, then enter the licence key again.")
            } else {
                stage = .failed("Couldn't fetch the profile from \(host). Check the connection and open the link again.")
            }
            return
        }
        activeFetch = nil
        guard case .fetching = stage else { return }
        guard let document = String(data: data, encoding: .utf8) else {
            stage = .failed(ProfileVerification.Failure.malformed.errorDescription ?? "")
            return
        }
        switch manager.review(document: document, source: source, sourceURL: target,
                              enteredLicence: enteredLicence) {
        case .success(let review): stage = .reviewing(review)
        case .failure(let refusal): stage = .failed(refusal.errorDescription ?? "")
        }
    }

    func confirm() {
        guard case .reviewing(let review) = stage else { return }
        switch manager.apply(review) {
        case .success:
            if manager.needsModelSetup, let model = manager.organizationModel {
                stage = .modelKey(model, organization: review.organizationName)
            } else {
                stage = .applied(review.organizationName)
                modelDidChange()
            }
            // Step 3 of the enrolment sequence: the pack, if the profile names one. It does not hold
            // up the sheet — the profile's bounds are already in force.
            Task { [manager] in await manager.completePendingPack() }
        case .failure(let refusal): stage = .failed(refusal.errorDescription ?? "")
        }
    }

    /// The key page's Save: the key is checked, saved as the organisation's model, and made the
    /// active model. Returns what is wrong with it, or nil once it is saved. A sign-in provider
    /// passes no key, once its sign-in has connected.
    func submitModelKey(_ key: String) -> String? {
        guard case .modelKey(let model, let organization) = stage else { return nil }
        if model.access == .key, let problem = model.keyProblem(key) { return problem }
        guard manager.completeModelSetup(apiKey: key) else {
            return "Couldn't save the key. Try again."
        }
        modelDidChange()
        stage = .applied(organization)
        return nil
    }

    /// "My administrator will add this": the phone stays in the administrator-needs-to-finish state.
    func deferModelKey() {
        guard case .modelKey(_, let organization) = stage else { return }
        stage = .applied(organization)
    }

    func dismiss() {
        reset()
        stage = .idle
    }

    /// An approval the person cannot see is not an approval — the rule the other link routes follow.
    func handleBackground() {
        if case .fetching = stage { activeFetch?.cancel() }
        if stage != .idle { dismiss() }
    }

    private func reset() {
        activeFetch?.cancel()
        activeFetch = nil
        pendingURL = nil
        enteredLicence = nil
        settingUpFor = nil
    }

    // MARK: - Production seam

    /// Bounded GET through the client every attacker-selected URL goes through: one resolved
    /// address per hop, TLS verified against the original hostname, and the profile's byte cap
    /// enforced as bytes arrive.
    nonisolated static func boundedFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await BoundedHTTPClient().fetchData(url, profile: .orgProfile)
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
