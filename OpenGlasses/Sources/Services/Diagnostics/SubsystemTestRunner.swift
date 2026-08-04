import Foundation

/// What a probe came back with: a short success detail ("14 KB photo")
/// or a failure message. Probes never throw, so the runner's bookkeeping
/// stays uniform.
enum ProbeResult: Equatable {
    case pass(String)
    case fail(String)
}

/// One cold-start subsystem check for the Developer panel (Plan CL P2):
/// a name plus an injected async probe.
struct SubsystemTest: Identifiable {
    let id: String
    let name: String
    let icon: String
    let probe: () async -> ProbeResult
}

/// Runs the Developer-panel subsystem tests and keeps their outcomes.
/// Deterministic core: probes, log sink, and clock are all injected, so
/// the whole lifecycle is unit-testable without any live service.
@MainActor
final class SubsystemTestRunner: ObservableObject {
    struct Outcome: Equatable {
        let passed: Bool
        let detail: String
        let seconds: Double
    }

    @Published private(set) var running: Set<String> = []
    @Published private(set) var outcomes: [String: Outcome] = [:]
    /// The failure message from the most recently completed test —
    /// tracked explicitly because `outcomes` is a dictionary and its
    /// newest entry isn't recoverable from it.
    @Published private(set) var lastFailure: String?

    let tests: [SubsystemTest]
    private let log: (String) -> Void
    private let now: () -> Date

    init(
        tests: [SubsystemTest],
        log: @escaping (String) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.tests = tests
        self.log = log
        self.now = now
    }

    var isRunning: Bool { !running.isEmpty }

    func run(_ id: String) async {
        guard let test = tests.first(where: { $0.id == id }),
              !running.contains(id) else { return }
        running.insert(id)
        defer { running.remove(id) }

        let start = now()
        let result = await test.probe()
        let seconds = now().timeIntervalSince(start)

        switch result {
        case .pass(let detail):
            outcomes[id] = Outcome(passed: true, detail: detail, seconds: seconds)
            if lastFailureID == id { lastFailure = nil }
            log("✅ Test \(test.name): \(detail) (\(Self.format(seconds)))")
        case .fail(let message):
            outcomes[id] = Outcome(passed: false, detail: message, seconds: seconds)
            lastFailure = "\(test.name): \(message)"
            lastFailureID = id
            log("❌ Test \(test.name): \(message) (\(Self.format(seconds)))")
        }
    }

    /// Sequential by design: the audio, HUD, and camera probes contend for
    /// the same hardware, and interleaved results are unreadable anyway.
    func runAll() async {
        for test in tests {
            await run(test.id)
        }
    }

    private var lastFailureID: String?

    static func format(_ seconds: Double) -> String {
        seconds < 9.95 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
    }
}
