import Foundation

/// Gathers the evidence for one readiness step, and gives back whatever it took to do so.
///
/// Two methods rather than one, so the **release is the runner's obligation, not the probe's
/// good manners**. A step that starts the camera, or takes the microphone, and then fails has
/// exactly the shape that leaks a resource; putting the release on the runner means it happens on
/// every path, including the failing one, and a fake can count both halves.
@MainActor
protocol ReadinessStepProbing: AnyObject {
    /// Observe what this step needs. Acquire whatever is required; do not release it here.
    func evidence(for step: ReadinessWalkthrough.Step) async -> ReadinessWalkthrough.Evidence

    /// Give back whatever `evidence(for:)` acquired for this step. Always called, pass or fail.
    ///
    /// Plan EW's rule applies: a step that claimed the camera releases the claim, and the stream
    /// stops only if this claim is what started it. Nothing is left listening that was not already
    /// listening when the check began.
    func release(after step: ReadinessWalkthrough.Step) async
}

/// Plan FF P1/PR8 — runs the readiness steps in order, speaks one status each, and stops at the
/// first failure with the fix stated.
///
/// The interesting decisions all live in `ReadinessWalkthrough`; this owns three things the table
/// cannot: the **order**, the **release after every step**, and the **one spoken line per step**.
///
/// It speaks through the app's own voice rather than posting a VoiceOver announcement, for the
/// same reason the launch policy's skip reasons do: a wearer running a readiness check may not
/// have VoiceOver on, and a status that only exists as a screen-reader announcement is a status
/// they never hear.
@MainActor
final class ReadinessWalkthroughRunner: ObservableObject {

    /// Completed steps, in order.
    @Published private(set) var results: [ReadinessWalkthrough.Result] = []
    /// The step currently being checked, for a progress row. `nil` when idle.
    @Published private(set) var runningStep: ReadinessWalkthrough.Step?
    /// Where VoiceOver focus should move next. The view clears it once it has moved, so a second
    /// result can move focus again rather than the state staying stuck on the first.
    @Published var focusTarget: ReadinessWalkthrough.Step?

    private let probe: any ReadinessStepProbing
    private let speak: (String) async -> Void

    /// - Parameters:
    ///   - probe: gathers evidence and gives resources back.
    ///   - speak: says one status line. Injected so the decisions can be observed without an
    ///     audio route, and so the production wiring can choose the speech path.
    init(probe: any ReadinessStepProbing, speak: @escaping (String) async -> Void) {
        self.probe = probe
        self.speak = speak
    }

    var isRunning: Bool { runningStep != nil }

    /// Whether every step that ran finished without a failure.
    var completedCleanly: Bool {
        !results.isEmpty && !results.contains { $0.verdict.isFailed }
    }

    /// The line spoken when the whole sequence ends, and shown as the screen's summary.
    var summary: String {
        guard !results.isEmpty else {
            return "The readiness check hasn't run yet."
        }
        if let failure = results.first(where: { $0.verdict.isFailed }) {
            return "Check stopped at \(failure.step.title). \(failure.spokenStatus)"
        }
        let notes = results.filter { if case .passed(let note) = $0.verdict { return note != nil }; return false }
        if notes.isEmpty && !results.contains(where: { $0.verdict.isSkipped }) {
            return "All five checks passed. The assistant is ready."
        }
        return "The checks passed, with notes. This is an audio-only setup."
    }

    // MARK: - Running

    /// Run every step from the top.
    func run() async {
        results = []
        await run(from: ReadinessWalkthrough.Step.allCases[0])
    }

    /// Re-run one step and carry on from there.
    ///
    /// A retry that made the wearer start from the top would charge them four passing steps for
    /// one permission they just granted — and, on the camera step, four more seconds of stream.
    func retry(_ step: ReadinessWalkthrough.Step) async {
        results.removeAll { resultIsAtOrAfter($0.step, step) }
        await run(from: step)
    }

    private func run(from first: ReadinessWalkthrough.Step) async {
        guard runningStep == nil else { return }
        for step in ReadinessWalkthrough.steps(from: first) {
            runningStep = step
            let result = await check(step)
            runningStep = nil

            results.append(result)
            // Focus before speaking: the row exists by the time the sentence starts, so a wearer
            // reaching for it while it is being read finds it under their finger.
            focusTarget = step
            await speak(result.spokenStatus)
            if let instruction = result.nextInstruction, result.verdict.isFailed {
                await speak(instruction)
            }

            guard ReadinessWalkthrough.shouldContinue(after: result) else { break }
        }
        await speak(summary)
    }

    /// One step: gather, **always** release, then judge.
    private func check(_ step: ReadinessWalkthrough.Step) async -> ReadinessWalkthrough.Result {
        let evidence = await probe.evidence(for: step)
        await probe.release(after: step)
        return ReadinessWalkthrough.result(for: step, evidence: evidence)
    }

    private func resultIsAtOrAfter(_ step: ReadinessWalkthrough.Step,
                                   _ boundary: ReadinessWalkthrough.Step) -> Bool {
        guard let lhs = ReadinessWalkthrough.Step.allCases.firstIndex(of: step),
              let rhs = ReadinessWalkthrough.Step.allCases.firstIndex(of: boundary) else {
            return false
        }
        return lhs >= rhs
    }
}
