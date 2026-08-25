import Foundation

/// Everything a bug report is allowed to know about this device, captured once at
/// the moment the wearer asks for one. Plain values only: the builder is pure, so a
/// report is fully reproducible from this struct and nothing else reaches into a
/// service to fetch more. What is *absent* is deliberate — no contacts, no location,
/// no transcripts, no memory contents, ever.
struct DiagnosticsSnapshot: Equatable {
    var appVersion: String
    var buildNumber: String
    /// "iOS" / "iPadOS" — whatever the system calls itself.
    var systemName: String
    var systemVersion: String
    /// Hardware identifier ("iPhone17,1"), not the wearer's name for the device.
    var deviceModel: String
    var localeIdentifier: String
    var glassesConnected: Bool
    var glassesName: String?
    var glassesBatteryPercent: Int?
    var hasDisplayCapability: Bool
    var activeModelName: String?
    /// Debug-log tail, oldest first. Trimmed to `maxLogLines` by the builder.
    var logTail: [String]
    /// One line per completed self-test probe, if the wearer ran them. Empty is fine.
    var selfTestSummary: [String]

    init(
        appVersion: String,
        buildNumber: String,
        systemName: String,
        systemVersion: String,
        deviceModel: String,
        localeIdentifier: String,
        glassesConnected: Bool,
        glassesName: String? = nil,
        glassesBatteryPercent: Int? = nil,
        hasDisplayCapability: Bool = false,
        activeModelName: String? = nil,
        logTail: [String] = [],
        selfTestSummary: [String] = []
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.localeIdentifier = localeIdentifier
        self.glassesConnected = glassesConnected
        self.glassesName = glassesName
        self.glassesBatteryPercent = glassesBatteryPercent
        self.hasDisplayCapability = hasDisplayCapability
        self.activeModelName = activeModelName
        self.logTail = logTail
        self.selfTestSummary = selfTestSummary
    }
}

/// A composed, already-redacted bug report. `body` is the whole thing (copy/share);
/// `issueURL` carries as much of it as a URL can actually hold.
struct DiagnosticsReport: Equatable {
    let title: String
    /// Full markdown body — redacted, untruncated. What Copy and Share hand over.
    let body: String
    /// Prefilled new-issue URL. Its body is the same report with the log tail
    /// trimmed from the oldest end until the URL fits `urlLimit`.
    let issueURL: URL
    /// How many log lines survived into `issueURL`.
    let includedLogLines: Int
    /// How many were dropped to make it fit (0 when the whole tail travelled).
    let omittedLogLines: Int
    /// Names of the redaction patterns that fired, in pattern order — surfaced so
    /// the wearer can see that masking happened rather than having to trust it.
    let redactionHits: [String]
}

/// Composes a bug report out of injected device facts and a debug-log tail.
///
/// Pure and deterministic: no `Bundle`, no `UIDevice`, no clock. The live edge
/// (gathering the snapshot, opening the URL, driving the share sheet) lives in the
/// view, which keeps every rule that matters here unit-testable — most of all the
/// redaction, which is not optional and not best-effort.
enum DiagnosticsReportBuilder {

    /// The project's own issue tracker. Hard-coded rather than derived from a git
    /// remote: the shipped app has no repository to ask.
    static let issueBaseURL = "https://github.com/straff2002/OpenGlasses/issues/new"

    /// Log lines carried at most. The in-memory ring holds ~80; the newest 60 are
    /// what a report has ever needed.
    static let maxLogLines = 60

    /// Practical ceiling on a URL that has to survive an app hand-off and a browser.
    /// Well under the ~8 KB that servers commonly accept, with room for the scheme.
    static let maxURLLength = 7_500

    static func build(
        _ snapshot: DiagnosticsSnapshot,
        redacting extraSecrets: [String] = [],
        urlLimit: Int = maxURLLength
    ) -> DiagnosticsReport {
        var hits: [String] = []

        func clean(_ text: String) -> String {
            let result = DiagnosticsRedactor.redact(text, extraSecrets: extraSecrets)
            for hit in result.hits where !hits.contains(hit) { hits.append(hit) }
            return result.redacted
        }

        let logLines = snapshot.logTail.suffix(maxLogLines).map(clean)
        let selfTest = snapshot.selfTestSummary.map(clean)
        let context = contextTable(snapshot, clean: clean)

        let title = "Bug report — OpenGlasses \(snapshot.appVersion) (\(snapshot.buildNumber))"
        let fullBody = markdown(context: context, selfTest: selfTest, logLines: logLines, omitted: 0)

        let (urlBody, included, omitted) = fitted(
            title: title, context: context, selfTest: selfTest,
            logLines: logLines, limit: urlLimit
        )

        return DiagnosticsReport(
            title: title,
            body: fullBody,
            issueURL: issueURL(title: title, body: urlBody),
            includedLogLines: included,
            omittedLogLines: omitted,
            redactionHits: hits
        )
    }

    // MARK: - Markdown

    private static func contextTable(
        _ snapshot: DiagnosticsSnapshot,
        clean: (String) -> String
    ) -> [String] {
        let glasses: String
        if snapshot.glassesConnected {
            let name = snapshot.glassesName.map(clean) ?? "unnamed"
            let battery = snapshot.glassesBatteryPercent.map { " · \($0)%" } ?? ""
            glasses = "Connected — \(name)\(battery)"
        } else {
            glasses = "Not connected"
        }
        return [
            row("App", "\(snapshot.appVersion) (\(snapshot.buildNumber))"),
            row("System", "\(snapshot.systemName) \(snapshot.systemVersion)"),
            row("Device", snapshot.deviceModel),
            row("Locale", snapshot.localeIdentifier),
            row("Glasses", glasses),
            row("Display", snapshot.hasDisplayCapability ? "Available" : "None"),
            row("Model", snapshot.activeModelName.map(clean) ?? "None configured"),
        ]
    }

    private static func row(_ label: String, _ value: String) -> String {
        "| \(label) | \(value) |"
    }

    private static func markdown(
        context: [String],
        selfTest: [String],
        logLines: [String],
        omitted: Int
    ) -> String {
        var parts: [String] = []

        parts.append("""
        ## What happened?

        <!-- What did you expect, and what happened instead? -->

        ## Steps to reproduce

        1.
        2.

        ## Device & app

        | | |
        |---|---|
        \(context.joined(separator: "\n"))
        """)

        if !selfTest.isEmpty {
            parts.append("""
            ## Self-test

            \(selfTest.map { "- \($0)" }.joined(separator: "\n"))
            """)
        }

        var log = "## Recent log\n\n"
        if logLines.isEmpty {
            log += "_No debug events recorded._"
        } else {
            if omitted > 0 {
                log += "_\(omitted) earlier line\(omitted == 1 ? "" : "s") omitted so this fits in a link — use Copy Report for the full log._\n\n"
            }
            log += "```\n\(logLines.joined(separator: "\n"))\n```"
        }
        parts.append(log)

        parts.append(
            "_Collected on this device at the wearer's request. API keys, tokens, and personal "
            + "identifiers are masked automatically. Conversations, contacts, location, and saved "
            + "memories are never included._"
        )

        return parts.joined(separator: "\n\n")
    }

    // MARK: - URL

    /// Trim the log tail from the oldest end until the prefilled URL fits. If even a
    /// log-free report is too long, the body itself is cut — a truncated report still
    /// beats no report, and the full text is a tap away in Copy/Share.
    private static func fitted(
        title: String,
        context: [String],
        selfTest: [String],
        logLines: [String],
        limit: Int
    ) -> (body: String, included: Int, omitted: Int) {
        var included = logLines
        var omitted = 0

        while true {
            let candidate = markdown(context: context, selfTest: selfTest, logLines: included, omitted: omitted)
            if urlLength(title: title, body: candidate) <= limit { return (candidate, included.count, omitted) }
            guard !included.isEmpty else {
                return (truncate(candidate, title: title, limit: limit), 0, omitted)
            }
            included.removeFirst()
            omitted += 1
        }
    }

    private static func truncate(_ body: String, title: String, limit: Int) -> String {
        var text = body
        while !text.isEmpty && urlLength(title: title, body: text) > limit {
            text = String(text.dropLast(max(64, text.count / 8)))
        }
        return text
    }

    private static func urlLength(title: String, body: String) -> Int {
        query(title: title, body: body).count + issueBaseURL.count + 1
    }

    private static func query(title: String, body: String) -> String {
        "title=\(percentEncoded(title))&body=\(percentEncoded(body))"
    }

    private static func issueURL(title: String, body: String) -> URL {
        // Every component is percent-encoded from a fixed base, so this cannot fail;
        // the fallback keeps the type non-optional for call sites rather than
        // pushing a "can't happen" branch into the UI.
        URL(string: "\(issueBaseURL)?\(query(title: title, body: body))")
            ?? URL(string: issueBaseURL)!
    }

    /// RFC 3986 unreserved set only. `URLComponents` leaves `+` and `&` alone in
    /// query values, which a form decoder then reads as a space or a separator —
    /// a report full of `+` and `#` needs the strict set.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// Scrubs credentials out of report text.
///
/// Three layers, most specific first: literal values the caller knows are secret
/// (the configured API keys and stream key — those have no recognisable shape once
/// they're someone else's), then the shared `SecretPatterns` set already used by the
/// outbound egress screen, then labelled `key: value` pairs as the catch-all.
/// Overlapping by design: a log line has to get past all three to keep a secret.
///
/// Order matters. The labelled sweep is the blunt one — it masks the first token
/// after a credential label — so it runs *last*, after the shaped patterns have had
/// their go at the whole credential. Ahead of them it would eat `Bearer` out of
/// `Authorization: Bearer …` and leave the token itself in the clear.
enum DiagnosticsRedactor {

    static let placeholder = SecretPatterns.redactionPlaceholder

    /// A credential introduced by its own label — `api_key=…`, `token: …`,
    /// `Stream key = …`. Group 1 keeps the label and separator so the reader can
    /// still see *what* was masked.
    private static let labelled: NSRegularExpression = {
        // The trailing lookahead skips a value an earlier layer already masked, so the
        // pass is genuinely idempotent and doesn't claim a hit it didn't make.
        let raw = #"(?i)\b((?:api[ _-]?key|apikey|key|token|secret|password|passwd|pwd|authorization|access[ _-]?token|refresh[ _-]?token|client[ _-]?secret|stream[ _-]?key|credential)\b\s*[:=]\s*["']?)(?!‹)[^\s"',;]{6,}"#
        guard let regex = try? NSRegularExpression(pattern: raw) else {
            fatalError("DiagnosticsRedactor: invalid labelled-secret regex")
        }
        return regex
    }()

    /// Shortest literal worth masking. Below this a "secret" is more likely an empty
    /// or placeholder setting, and blanket-replacing a 3-character string would chew
    /// through ordinary log text.
    private static let minimumLiteralLength = 6

    static func redact(_ text: String, extraSecrets: [String] = []) -> (redacted: String, hits: [String]) {
        guard !text.isEmpty else { return (text, []) }
        var result = text
        var hits: [String] = []

        for secret in extraSecrets where secret.count >= minimumLiteralLength {
            guard result.contains(secret) else { continue }
            result = result.replacingOccurrences(of: secret, with: placeholder)
            if !hits.contains("configured_secret") { hits.append("configured_secret") }
        }

        let patterned = SecretPatterns.redact(result, placeholder: placeholder)
        result = patterned.redacted
        hits.append(contentsOf: patterned.hits)

        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        if labelled.firstMatch(in: result, options: [], range: range) != nil {
            result = labelled.stringByReplacingMatches(
                in: result, options: [],
                range: range,
                withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: placeholder)
            )
            if !hits.contains("labelled_secret") { hits.append("labelled_secret") }
        }

        return (result, hits)
    }
}
