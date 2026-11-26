import Foundation

/// Which earlier run of the app a crash note belongs to. Pure.
///
/// A run is a candidate when its events span the crash — its first event at or before the time
/// the system dated the crash to, its last event no more than `trailingSlack` before it (the ring
/// writes on a short delay, so the last events of a crashed run can be missing) — and when it ran
/// the build the crash happened on. Exactly one candidate is a match. None, or two, and the note
/// is printed on its own rather than guessed: a wrong run is worse than an unnamed one.
enum CrashRunMatcher {

    /// One earlier run, as the ring and the last-screens record know it.
    struct Run: Equatable {
        let id: String
        let first: Date
        let last: Date
        /// The build it ran, from its last-screens record. Nil for a run recorded before that
        /// record existed, which is never matched: the build check could not be made.
        let build: String?
    }

    enum Match: Equatable {
        case run(Run)
        case unidentified
    }

    static let trailingSlack: TimeInterval = 5

    static func match(_ note: CrashNote, runs: [Run]) -> Match {
        let candidates = runs.filter { run in
            run.build == note.build
                && run.first <= note.at
                && note.at <= run.last.addingTimeInterval(trailingSlack)
        }
        guard candidates.count == 1, let only = candidates.first else { return .unidentified }
        return .run(only)
    }

    /// Earlier runs from the ring's history and the last-screens records, the current run left
    /// out (it is still running, so it did not crash). A run's span is the widest the two
    /// sources give together; its build comes from its last-screens record.
    static func runs(history: [DiagnosticRing.Entry], lastScreens: [LastScreens],
                     excluding current: String?) -> [Run] {
        var spans: [String: (first: Date, last: Date)] = [:]
        var order: [String] = []
        func widen(_ id: String, _ first: Date, _ last: Date) {
            if let span = spans[id] {
                spans[id] = (min(span.first, first), max(span.last, last))
            } else {
                spans[id] = (first, last)
                order.append(id)
            }
        }
        for entry in history {
            guard let run = entry.run else { continue }
            widen(run, entry.timestamp, entry.timestamp)
        }
        var builds: [String: String] = [:]
        for record in lastScreens {
            widen(record.run, record.startedAt, record.lastSeen)
            builds[record.run] = record.build
        }
        return order.compactMap { id in
            guard id != current, let span = spans[id] else { return nil }
            return Run(id: id, first: span.first, last: span.last, build: builds[id])
        }
        .sorted { $0.first < $1.first }
    }
}

/// How a crash note reads in a report or an export. Pure; the caller passes the formatters.
enum CrashReportSection {

    /// The heading a matched run gets in place of "exit reason unknown".
    static func endedInCrash(_ note: CrashNote, run: CrashRunMatcher.Run,
                             time: (Date) -> String) -> String {
        "Ended in a crash after its last event at \(time(run.last)) — \(note.summary)"
    }

    /// The heading of a note no run could be found for.
    static let unidentifiedHeading = "A crash the phone recorded (run not identified)"

    /// The note's detail lines: build and system, the crashed thread's frames, and the screens the
    /// run last opened, newest last. The frame lines are what
    /// `Scripts/symbolicate-crash-report.sh` reads: index, binary, UUID, offset.
    static func detail(_ note: CrashNote, screens: LastScreens?, time: (Date) -> String) -> [String] {
        var lines = ["  App \(note.appVersion) (\(note.build)) · \(note.osVersion)"]
        if note.frames.isEmpty {
            lines.append("  No frames were recorded for the crashed thread.")
        } else {
            lines.append("  Crashed thread, newest frame first (symbolicate on the Mac against the archive):")
            for (index, frame) in note.frames.enumerated() {
                lines.append("    \(String(index).leftPadded(to: 2))  \(frame.binary)  \(frame.uuid)  +0x\(String(frame.offset, radix: 16))")
            }
        }
        if let screens, !screens.screens.isEmpty {
            lines.append("  Last screens, newest last:")
            for screen in screens.screens {
                lines.append("    \(time(screen.at))  \(screen.token) \(screen.appeared ? "opened" : "closed")")
            }
        }
        return lines
    }

    /// Every note as the support report's "Crashes" section prints it, newest last.
    static func lines(notes: [CrashNote], runs: [CrashRunMatcher.Run], lastScreens: [LastScreens],
                      time: (Date) -> String) -> [String] {
        var lines: [String] = []
        for note in notes.sorted(by: { $0.at < $1.at }) {
            if !lines.isEmpty { lines.append("") }
            switch CrashRunMatcher.match(note, runs: runs) {
            case .run(let run):
                lines.append(endedInCrash(note, run: run, time: time))
                lines += detail(note, screens: lastScreens.last { $0.run == run.id }, time: time)
            case .unidentified:
                lines.append("\(unidentifiedHeading), dated \(time(note.at)) — \(note.summary)")
                lines += detail(note, screens: nil, time: time)
            }
        }
        return lines
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
