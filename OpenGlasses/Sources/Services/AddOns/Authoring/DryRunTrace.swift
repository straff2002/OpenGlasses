import Foundation

/// What one test run of a drafted add-on did, step by step (`RecipeRunner.dryRun`): which steps
/// ran and how, how much came back, where it went, what was extracted, what it would have said,
/// and how long it took. Kept with the draft for the review sheet's Tested panel and deleted with
/// it. Nothing in a trace was written to memory or shown on a display: a test only previews them.
struct DryRunTrace: Codable, Equatable, Sendable {

    enum Outcome: Codable, Equatable, Sendable {
        case completed
        /// The run's 30-second budget ran out.
        case timedOut
        case unknownSkill
        /// The sample arguments don't fit the skill's parameters.
        case invalidArguments(String)
        /// A sample value looked like a credential or matched something the wearer has told the
        /// assistant. Nothing was sent.
        case blockedSample([String])
    }

    struct Step: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case http, extract, say, remember, display, branch }
        enum Status: String, Codable, Sendable {
            /// It ran and did what it is for.
            case ok
            /// An `http` step that got no usable answer.
            case failed
            /// An `extract` that found nothing and fell back.
            case missed
            /// A `remember` step: recorded here, never written.
            case simulated
            /// A `display` step: shown in the review only.
            case previewOnly
        }
        /// Where in the skill: `steps[1]`, `steps[2].then[0]`.
        let path: String
        let kind: Kind
        let status: Status
        var host: String?
        var httpStatus: Int?
        var bytes: Int?
        var redirectHops: Int?
        /// The sandbox's code for an `http` failure (`timeout`, `too_large`, …).
        var error: String?
        /// What an `extract` found (truncated), the branch an `if` took, a `remember` key, a
        /// `display` title.
        var value: String?
    }

    let skill: String
    let outcome: Outcome
    let steps: [Step]
    /// What the skill would have said.
    let spoken: String
    let requestsMade: Int
    /// Every host a request reached, in order, each once.
    let hostsContacted: [String]
    let elapsed: TimeInterval

    static let maxValueLength = 120

    /// The sandbox codes that mean a limit was hit, not that the service said no.
    static let limitCodes: Set<String> = [
        "request_limit", "too_large", "run_timeout", "too_many_redirects", "redirect_refused",
        "host_not_allowed", "unsupported_type",
    ]

    var limitHits: [String] {
        steps.compactMap { step in step.error.flatMap { Self.limitCodes.contains($0) ? $0 : nil } }
    }

    static func truncated(_ text: String) -> String {
        text.count <= maxValueLength ? text : String(text.prefix(maxValueLength - 1)) + "…"
    }
}

/// Whether a test run shows the add-on works. Pure.
///
/// A pass needs all of: the run completed; it reached the service; every `http` step on the path
/// it took got a usable answer; every `extract` on that path found something (a fallback is the
/// failure path); it said something, with no `{{…}}` left in it; and no sandbox limit was hit.
enum DryRunAssessor {

    enum Reason: Equatable, Sendable {
        case didNotComplete(DryRunTrace.Outcome)
        case noRequest
        case httpFailed(path: String, status: Int?, error: String?)
        case extractEmpty(path: String)
        case noAnswer
        case unresolvedPlaceholder
        case limitHit(String)
    }

    struct Assessment: Equatable, Sendable {
        let reasons: [Reason]
        var passed: Bool { reasons.isEmpty }
    }

    static func assess(_ trace: DryRunTrace) -> Assessment {
        var reasons: [Reason] = []
        if trace.outcome != .completed { reasons.append(.didNotComplete(trace.outcome)) }
        if trace.outcome == .completed && trace.requestsMade == 0 { reasons.append(.noRequest) }
        for step in trace.steps {
            switch (step.kind, step.status) {
            case (.http, .failed):
                reasons.append(.httpFailed(path: step.path, status: step.httpStatus, error: step.error))
            case (.extract, .missed):
                reasons.append(.extractEmpty(path: step.path))
            default:
                break
            }
        }
        let spoken = trace.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trace.outcome == .completed && spoken.isEmpty { reasons.append(.noAnswer) }
        if spoken.contains("{{") || spoken.contains("}}") { reasons.append(.unresolvedPlaceholder) }
        for code in trace.limitHits where !reasons.contains(.limitHit(code)) { reasons.append(.limitHit(code)) }
        return Assessment(reasons: reasons)
    }

    /// What the repair prompt is told about a failed test, one line per reason. Built from the
    /// trace's own fields, so a service's response text never reaches the model through here
    /// except as truncated extracted values, which the prompt frames as data.
    static func repairLines(_ assessment: Assessment) -> [String] {
        assessment.reasons.map { reason in
            switch reason {
            case .didNotComplete(let outcome):
                switch outcome {
                case .completed: return "the run did not complete"
                case .timedOut: return "the run took longer than 30 seconds"
                case .unknownSkill: return "the sample names a skill the add-on does not have"
                case .invalidArguments(let why): return "the sample arguments were refused: \(why)"
                case .blockedSample: return "a sample value looked private; use an ordinary public example"
                }
            case .noRequest: return "the run never called the service"
            case .httpFailed(let path, let status, let error):
                let what = [status.map { "status \($0)" }, error.flatMap { $0.isEmpty ? nil : $0 }]
                    .compactMap { $0 }.joined(separator: ", ")
                return "\(path): the request failed (\(what.isEmpty ? "no answer" : what))"
            case .extractEmpty(let path): return "\(path): the extract found nothing in the response"
            case .noAnswer: return "the skill said nothing"
            case .unresolvedPlaceholder: return "the answer still contains {{…}}"
            case .limitHit(let code): return "a limit was hit: \(code)"
            }
        }
    }
}
