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

    /// How a profile applied through this service is recorded.
    let source: ProfileSource = .link

    private let manager: OrgProfileManager
    private let fetch: (URL) async throws -> Data
    private let isPastOnboarding: () -> Bool
    private var pendingURL: URL?
    private var heldURL: URL?
    private var activeFetch: Task<Data, Error>?

    init(manager: OrgProfileManager,
         fetch: @escaping (URL) async throws -> Data = OrgEnrolmentService.boundedFetch,
         isPastOnboarding: @escaping () -> Bool = { Config.isPastOnboarding }) {
        self.manager = manager
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

    /// Onboarding has just finished: offer the link that arrived during it.
    func releaseHeldLink() {
        guard let held = heldURL, isPastOnboarding() else { return }
        heldURL = nil
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
        stage = .fetching(host: host)
        let request = Task { [fetch] in try await fetch(target) }
        activeFetch = request
        let data: Data
        do {
            data = try await request.value
        } catch {
            guard case .fetching = stage else { return }
            activeFetch = nil
            stage = .failed("Couldn't fetch the profile from \(host). Check the connection and open the link again.")
            return
        }
        activeFetch = nil
        guard case .fetching = stage else { return }
        guard let document = String(data: data, encoding: .utf8) else {
            stage = .failed(ProfileVerification.Failure.malformed.errorDescription ?? "")
            return
        }
        switch manager.review(document: document, source: source) {
        case .success(let review): stage = .reviewing(review)
        case .failure(let refusal): stage = .failed(refusal.errorDescription ?? "")
        }
    }

    func confirm() {
        guard case .reviewing(let review) = stage else { return }
        switch manager.apply(review) {
        case .success: stage = .applied(review.organizationName)
        case .failure(let refusal): stage = .failed(refusal.errorDescription ?? "")
        }
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
