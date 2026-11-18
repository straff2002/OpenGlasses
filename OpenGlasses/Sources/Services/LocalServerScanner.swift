import Foundation
import Network

/// Live LAN auto-detect for self-hosted LLM servers (Plan AF #6) — **best-effort,
/// experimental**. Browses Bonjour for HTTP hosts, then probes each host's preset
/// candidate URLs (`LocalServerDiscovery.candidates`) via `ModelFetcher.testConnection`,
/// returning the reachable OpenAI-compatible servers.
///
/// Device-pending by nature: many local servers (Ollama, llama.cpp) don't advertise
/// Bonjour, and Local Network access requires the user's permission + the
/// `NSLocalNetworkUsageDescription` / `NSBonjourServices` Info.plist keys. The manual
/// preset (#5) remains the primary path; the pure candidate logic is in
/// `LocalServerDiscovery` and is unit-tested.
@MainActor
final class LocalServerScanner {

    struct DiscoveredServer: Identifiable, Equatable {
        var id: String { baseURL }
        let host: String
        let baseURL: String
        let preset: LocalServerPreset
        let modelCount: Int
        let latencyMs: Int
    }

    private var browser: NWBrowser?

    /// Whether the last browse was refused by the Local Network permission
    /// (`LocalNetworkAccessHint`), so an empty result can say why.
    private(set) var lastBrowseLocalNetworkDenied = false

    /// Browse Bonjour `_http._tcp` for up to `discoverySeconds`, then probe each
    /// discovered host's preset candidates. Returns reachable servers, fastest first.
    func scan(discoverySeconds: TimeInterval = 3) async -> [DiscoveredServer] {
        let browse = await browseHosts(for: discoverySeconds)
        lastBrowseLocalNetworkDenied = browse.denied
        let hosts = browse.hosts
        guard !hosts.isEmpty else { return [] }

        var found: [DiscoveredServer] = []
        await withTaskGroup(of: DiscoveredServer?.self) { group in
            for host in hosts {
                for candidate in LocalServerDiscovery.candidates(host: host) {
                    group.addTask {
                        let result = await ModelFetcher.testConnection(
                            provider: .custom, apiKey: "", baseURL: candidate.baseURL)
                        guard case let .ok(latencyMs, modelCount) = result else { return nil }
                        return DiscoveredServer(host: host, baseURL: candidate.baseURL,
                                                preset: candidate.preset,
                                                modelCount: modelCount, latencyMs: latencyMs)
                    }
                }
            }
            for await server in group where server != nil {
                found.append(server!)
            }
        }
        // De-dupe by base URL, fastest first.
        var seen = Set<String>()
        return found
            .sorted { $0.latencyMs < $1.latencyMs }
            .filter { seen.insert($0.baseURL).inserted }
    }

    /// Collect candidate hostnames from Bonjour `_http._tcp` service results. Maps each
    /// discovered service instance to its `<name>.local` host (best-effort — exact
    /// endpoint resolution is device-validated).
    private func browseHosts(for seconds: TimeInterval) async -> (hosts: [String], denied: Bool) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(hosts: [String], denied: Bool), Never>) in
            // The NWBrowser handlers are `@Sendable` and the timeout closure is passed to
            // `asyncAfter`, so the shared browse state must be data-race-free (a hard error under
            // the Swift 6 language mode). A lock-guarded collector confines `hosts` + the
            // resume-once flag; browser teardown hops back to the main actor.
            let collector = HostCollector()
            let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
            self.browser = browser

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        let host = name.hasSuffix(".local") ? name : "\(name).local"
                        collector.insert(host)
                    }
                }
            }

            let finish: @Sendable () -> Void = { [weak self] in
                guard collector.claimFinish() else { return }
                Task { @MainActor in
                    self?.browser?.cancel()
                    self?.browser = nil
                }
                continuation.resume(returning: (hosts: collector.snapshot(), denied: collector.denied))
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if LocalNetworkAccessHint.isLikelyDenied(error) { collector.markDenied() }
                default:
                    break
                }
                if case .failed = state { finish() }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: finish)
        }
    }
}

/// Data-race-free accumulator for a Bonjour browse: the browser's `@Sendable` handlers and the
/// timeout closure can run on different threads, so the discovered hosts and the resume-once flag
/// live behind a lock rather than as captured `var`s.
private final class HostCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts = Set<String>()
    private var finished = false

    func insert(_ host: String) {
        lock.lock(); defer { lock.unlock() }
        hosts.insert(host)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(hosts)
    }

    private var deniedFlag = false

    var denied: Bool {
        lock.lock(); defer { lock.unlock() }
        return deniedFlag
    }

    func markDenied() {
        lock.lock(); defer { lock.unlock() }
        deniedFlag = true
    }

    /// Returns `true` for the first caller only — the winner performs the single continuation resume.
    func claimFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
