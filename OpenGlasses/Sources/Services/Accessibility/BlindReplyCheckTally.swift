import Foundation

/// What the reply check has done since the app started (Plan NA §6), for the support report.
///
/// Counts only, in memory: sentences checked, each flag by what was done about it, the exemptions
/// that held, and the replies the phrase tables did not run on because of their language. Never a
/// sentence, a reply, a question or a reading. Pure; `BlindReplyCheckRecorder` holds the app's one.
struct BlindReplyCheckTally: Equatable, Sendable {

    private(set) var sentencesChecked = 0
    /// Replies (or live turns) the phrase tables did not run on because they were not in English.
    private(set) var repliesNotEnglish = 0
    /// Per flag, per action token (`replaced`, `stopped`, `corrected`, `dropped`, `counted`).
    private(set) var flagOutcomes: [BlindReplyCheck.Flag: [String: Int]] = [:]
    /// Per exemption.
    private(set) var exemptions: [BlindReplyCheck.Exemption: Int] = [:]
    /// Per surface, sentences that tripped something that acts.
    private(set) var tripsBySurface: [BlindReplyGuard.Surface: Int] = [:]

    init() {}

    mutating func record(_ item: BlindReplyScreen.Screened, surface: BlindReplyGuard.Surface) {
        sentencesChecked += 1
        for finding in item.result.findings {
            if let exemption = finding.exemption {
                exemptions[exemption, default: 0] += 1
            } else {
                // A counted-only flag is "counted"; an acting one gets what the guard did with
                // the sentence.
                let outcome = finding.acts ? item.action.token : BlindReplyGuard.Action.count.token
                flagOutcomes[finding.flag, default: [:]][outcome, default: 0] += 1
            }
        }
        if item.result.acts { tripsBySurface[surface, default: 0] += 1 }
    }

    mutating func noteReplyNotEnglish() { repliesNotEnglish += 1 }

    /// The report line: "Reply check: 214 sentences checked · assertedSafety 3 (replaced 2,
    /// stopped 1) · … · not English 12 replies". Nothing before the first check.
    var reportLines: [String] {
        guard sentencesChecked > 0 || repliesNotEnglish > 0 else { return [] }
        var parts = ["\(sentencesChecked) sentences checked"]
        for flag in BlindReplyCheck.Flag.allCases {
            guard let outcomes = flagOutcomes[flag], !outcomes.isEmpty else { continue }
            let total = outcomes.values.reduce(0, +)
            let detail = outcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            parts.append("\(flag.rawValue) \(total) (\(detail))")
        }
        for exemption in BlindReplyCheck.Exemption.allCases where exemption != .notEnglish {
            if let count = exemptions[exemption], count > 0 { parts.append("\(exemption.rawValue) \(count)") }
        }
        let surfaces = BlindReplyGuard.Surface.allCases.compactMap { surface -> String? in
            guard let count = tripsBySurface[surface], count > 0 else { return nil }
            return "\(surface.rawValue) \(count)"
        }
        if !surfaces.isEmpty { parts.append("trips by surface: " + surfaces.joined(separator: ", ")) }
        parts.append("not English \(repliesNotEnglish) replies")
        return ["Reply check: " + parts.joined(separator: " · ")]
    }
}

/// The app's one tally, and the log line for each screened sentence that found something. Every
/// field is a case name or a count: the sentence's length, never its words.
@MainActor
enum BlindReplyCheckRecorder {
    static private(set) var tally = BlindReplyCheckTally()

    /// Record a reply's (or a live turn's) screened sentences.
    static func record(_ items: [BlindReplyScreen.Screened], surface: BlindReplyGuard.Surface,
                       provider: PrivacyToken? = nil) {
        guard !items.isEmpty else { return }
        for item in items {
            tally.record(item, surface: surface)
            for finding in item.result.findings {
                PrivacyLog.replyCheck(
                    finding.exemption == nil ? .flagged : .exempted,
                    surface: PrivacyToken(surface.rawValue),
                    flag: PrivacyToken(finding.flag.rawValue),
                    outcome: PrivacyToken(finding.acts ? item.action.token : "counted"),
                    exemption: finding.exemption.map { PrivacyToken($0.rawValue) },
                    provider: provider,
                    characters: item.sentence.count)
            }
        }
        if items.contains(where: { $0.result.language == .notEnglish }) {
            tally.noteReplyNotEnglish()
            PrivacyLog.replyCheck(.notChecked, surface: PrivacyToken(surface.rawValue),
                                  exemption: PrivacyToken(BlindReplyCheck.Exemption.notEnglish.rawValue),
                                  provider: provider, count: items.count)
        }
    }

    /// A live session stopped an answer: how much audio was still waiting to play when it did.
    static func recordLiveStop(provider: PrivacyToken, pendingMilliseconds: Int, line: BlindReplyLine) {
        PrivacyLog.replyCheck(.liveStopped, surface: PrivacyToken(BlindReplyGuard.Surface.live.rawValue),
                              outcome: PrivacyToken(line.rawValue), provider: provider,
                              pendingMilliseconds: pendingMilliseconds)
    }

    /// The live model was told at the turn's end.
    static func recordModelNoted(provider: PrivacyToken, line: BlindReplyLine) {
        PrivacyLog.replyCheck(.modelNoted, surface: PrivacyToken(BlindReplyGuard.Surface.live.rawValue),
                              outcome: PrivacyToken(line.rawValue), provider: provider)
    }

    static var reportLines: [String] { tally.reportLines }
}
