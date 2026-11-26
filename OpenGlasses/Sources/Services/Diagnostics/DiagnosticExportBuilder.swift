import Foundation

/// The device facts an export names. All four are properties of the build and the hardware, not
/// of the wearer — the same four a crash report carries.
struct DiagnosticExportEnvironment: Equatable {
    let appVersion: String
    let buildNumber: String
    let systemName: String
    let systemVersion: String
    let deviceModel: String

    static let unknown = DiagnosticExportEnvironment(appVersion: "–", buildNumber: "–",
                                                     systemName: "iOS", systemVersion: "–",
                                                     deviceModel: "unknown")
}

/// A finished diagnostics export: the header the wearer reads first, the event lines, and the
/// single body string that is both previewed and written.
///
/// `body` is the *only* representation, and the only one the redaction pass has run over. The
/// preview screen renders it and the file receives it byte for byte, so "you see what you send" is
/// a property of the type rather than a claim in the copy — there is no second rendering that
/// could drift. `headerLines` and `eventLines` are the pre-assembly pieces, kept for tests and for
/// counting; nothing should display or write them.
struct DiagnosticExportDocument: Equatable {
    let headerLines: [String]
    let eventLines: [String]
    let body: String
    /// How many events the document describes.
    let eventCount: Int
    /// Whether the ring was full, so the wearer knows older events fell off rather than never
    /// happening.
    let ringWasFull: Bool
}

/// Turns the diagnostic ring into the exact text a diagnostics export contains.
///
/// Pure, so what gets exported is a unit test rather than a promise, and so the preview and the
/// file cannot disagree. The last thing it does is run `LogRedaction` over the assembled body:
/// nothing that reaches here should contain a token — the ring holds encoded `PrivacyLog` lines,
/// and no field of one can be a URL or a credential — but this is the one place in the app where
/// text the wearer has chosen to send leaves the device, which is the role that redactor was kept
/// for. Defence in depth, not the defence.
enum DiagnosticExportBuilder {

    /// The honest description, in the export itself as well as on screen. A file that outlives the
    /// screen it was approved on has to carry its own explanation.
    static let explanation = [
        "This file is a list of what the app did — one line per structured event, with its category, event name, counts, durations and outcome.",
        "It contains no conversation content, no transcripts, no tool arguments or results, no photos, no names, no locations, no medical values, no URLs, and no keys or tokens. Those have no way into a log line: the logging API has no parameter that accepts them.",
        "Identifiers that would name a device, a gateway or a thread appear only as short one-way fingerprints (#a1b2c3d4), which can be compared with each other but not read back.",
        "Recent structured events are saved locally in a bounded buffer, excluded from backup. This export can include earlier runs of the app (up to \(DiagnosticRing.retentionDays) days old), which may have ended normally or unexpectedly. The \(DiagnosticRing.defaultCapacity)-event capacity can be reached before that age. The last events before an abrupt exit may be missing. Nothing is sent automatically.",
        "A note on the system log: marking a log field private tells the operating system to hide it from other readers on the device. It does not make the value safe to send to us, so this app does not put values in log fields and then rely on that. What you are reading is all there is.",
    ]

    static func build(entries: [DiagnosticRing.Entry],
                      environment: DiagnosticExportEnvironment,
                      previousEntries: [DiagnosticRing.Entry] = [],
                      capacity: Int = DiagnosticRing.defaultCapacity,
                      crashNotes: [CrashNote] = [],
                      lastScreens: [LastScreens] = [],
                      currentRun: String? = nil,
                      now: Date = Date(),
                      timeZone: TimeZone = .current) -> DiagnosticExportDocument {
        let stamp = timestampFormatter(timeZone: timeZone)
        let generated = generatedFormatter(timeZone: timeZone)

        var headerLines = [
            "Avenkin diagnostics",
            "Generated \(generated.string(from: now))",
            "App \(environment.appVersion) (\(environment.buildNumber)) · \(environment.systemName) \(environment.systemVersion) · \(environment.deviceModel)",
            "\(entries.count) event\(entries.count == 1 ? "" : "s") from this session"
                + (entries.count >= capacity ? " (the oldest were dropped — the buffer holds \(capacity))" : ""),
        ]
        headerLines.append("")
        headerLines.append(contentsOf: explanation)

        let eventLines = entries.map { "\(stamp.string(from: $0.timestamp))  \($0.line)" }

        var body = headerLines.joined(separator: "\n")
        body += "\n\n"
        body += eventLines.isEmpty
            ? "(no events recorded yet)"
            : eventLines.joined(separator: "\n")
        // Plan MB: each earlier run under its own heading. A run a crash note matches says it
        // ended in a crash, with the crash and the screens it last opened; any other run keeps
        // "exit reason unknown" — no note is not proof of a clean exit.
        let runs = CrashRunMatcher.runs(history: previousEntries, lastScreens: lastScreens,
                                        excluding: currentRun)
        var crashByRun: [String: CrashNote] = [:]
        var unidentified: [CrashNote] = []
        for note in crashNotes.sorted(by: { $0.at < $1.at }) {
            if case .run(let run) = CrashRunMatcher.match(note, runs: runs), crashByRun[run.id] == nil {
                crashByRun[run.id] = note
            } else {
                unidentified.append(note)
            }
        }
        let time: (Date) -> String = { stamp.string(from: $0) }
        for group in Self.runGroups(previousEntries) {
            if let run = group.run, let note = crashByRun[run],
               let span = runs.first(where: { $0.id == run }) {
                body += "\n\nPrevious run (may be a different app build; "
                    + CrashReportSection.endedInCrash(note, run: span, time: time).lowercasedFirst + ")\n"
                body += CrashReportSection.detail(note, screens: lastScreens.last { $0.run == run },
                                                  time: time).joined(separator: "\n") + "\n"
            } else {
                body += "\n\nPrevious run (may be a different app build; exit reason unknown)\n"
            }
            body += group.entries.map { "\(generated.string(from: $0.timestamp))  \($0.line)" }
                .joined(separator: "\n")
        }
        // A matched run whose events the ring no longer holds still gets its crash printed.
        let printedRuns = Set(Self.runGroups(previousEntries).compactMap { $0.run })
        for (run, note) in crashByRun where !printedRuns.contains(run) {
            if let span = runs.first(where: { $0.id == run }) {
                body += "\n\nPrevious run (its events are no longer kept; "
                    + CrashReportSection.endedInCrash(note, run: span, time: time).lowercasedFirst + ")\n"
                body += CrashReportSection.detail(note, screens: lastScreens.last { $0.run == run },
                                                  time: time).joined(separator: "\n")
            }
        }
        for note in unidentified {
            body += "\n\n\(CrashReportSection.unidentifiedHeading)\n"
            body += "Dated \(generated.string(from: note.at)) — \(note.summary)\n"
            body += CrashReportSection.detail(note, screens: nil, time: time).joined(separator: "\n")
        }
        body += "\n"

        return DiagnosticExportDocument(headerLines: headerLines,
                                        eventLines: eventLines,
                                        body: LogRedaction.redact(body),
                                        eventCount: entries.count + previousEntries.count,
                                        ringWasFull: entries.count >= capacity)
    }

    /// Earlier runs' entries in runs, in order. Entries written before runs were told apart
    /// (`run == nil`) read as one run.
    static func runGroups(_ entries: [DiagnosticRing.Entry]) -> [(run: String?, entries: [DiagnosticRing.Entry])] {
        var groups: [(run: String?, entries: [DiagnosticRing.Entry])] = []
        for entry in entries {
            if let last = groups.last, last.run == entry.run {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((entry.run, [entry]))
            }
        }
        return groups
    }

    /// The name offered to the share sheet. A date, and nothing about the session.
    static func displayName(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "avenkin-diagnostics-\(formatter.string(from: now)).txt"
    }

    // MARK: - Formatters

    private static func timestampFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    private static func generatedFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }
}

private extension String {
    /// "Ended in a crash…" → "ended in a crash…", for the middle of a heading.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
