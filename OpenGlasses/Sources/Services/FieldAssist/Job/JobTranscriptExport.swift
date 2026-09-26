import Foundation

/// What was said on a job, or on a whole day, as one plain-text file the technician can send
/// (support ask, 2026-09-26).
///
/// When a customer reports that something went wrong on site, the question support asks first is
/// "what did the technician say, and what did the assistant say back?". The answer is on the phone
/// already — a job owns a conversation thread (Plan FO P1), and the job log keeps the technician's
/// words — but the only way to read it was one bubble at a time on `JobTranscriptView`. This turns
/// the same messages into a file, so one tap and the share sheet replace screenshots.
///
/// Two layers, chosen by the person exporting:
/// - **the transcript** — who said what, and when, for a job or every job on a day;
/// - **troubleshooting details** on top — for each AI turn, which model answered, what went with
///   the words (prompt parts by size, manual pages, photos, tools), how long it took and how it
///   ended (`TurnTrace`); the job's own log; the phone and glasses; and the app's event log.
///   Keys and tokens are masked across the whole file when this layer is on, because this is the
///   file that goes to support.
///
/// A day can also carry the conversations held **outside** any job, because a problem does not
/// wait for a job to be open.
///
/// **Pure.** The inputs are values; the output is the document. No store, no clock and no locale is
/// read in here, so every rule is a fixture test rather than a hope.
///
/// **Nothing is sent from here.** The file is handed to Mail or the share sheet, and the person
/// chooses where it goes.
enum JobTranscriptExport {

    /// One job, or everything started on one calendar day.
    enum Scope: Equatable {
        case job(sessionId: String)
        case day(Date)
    }

    enum Speaker: String, Equatable {
        case technician = "Technician"
        case assistant = "Assistant"
    }

    struct Line: Equatable {
        let timestamp: Date
        let speaker: Speaker
        let text: String
        /// A camera frame or photo went with this message. The picture is not in the file, but
        /// "the assistant answered about a photo" is part of what happened.
        let imageAttached: Bool
    }

    /// Where a job's lines came from. Said in the file, because a transcript with no assistant
    /// replies reads as an assistant that never answered unless the file says why.
    enum Source: Equatable {
        /// The job's own conversation thread: both sides.
        case conversation
        /// The thread is no longer on the phone (deleted, or never saved); the technician's words
        /// from the job log are all there is.
        case jobLogOnly
        /// Nothing said on the job is on the phone.
        case nothing
    }

    struct Job: Equatable {
        let sessionId: String
        /// "Job 1005", or `JobTabModel.noJobNumber` — never blank.
        let jobNumber: String
        let vaultName: String
        let equipment: String?
        let outcome: String
        let startedAt: Date
        let endedAt: Date?
        /// The thread the job owns, so its AI turns can be matched to it.
        let threadId: String?
        let source: Source
        let lines: [Line]
    }

    /// A conversation held outside any job on the chosen day.
    struct Conversation: Equatable {
        let threadId: String
        let title: String
        let lines: [Line]
    }

    /// The troubleshooting layer's inputs, gathered by the caller.
    struct Details {
        /// Every AI turn in the scope's window.
        var traces: [TurnTrace] = []
        /// Each job's log events, by session id. Conversation lines are left out when rendering —
        /// they are already in the transcript.
        var jobEvents: [String: [SessionLogger.Event]] = [:]
        /// The phone, app and glasses, one fact per line.
        var phone: [String] = []
        /// The app's event log (`DiagnosticRing`) within the scope's window.
        var appEvents: [AppEvent] = []
        /// The newest lines of the in-app debug log.
        var debugLog: [String] = []
    }

    struct AppEvent: Equatable {
        let at: Date
        let line: String
    }

    struct Document: Equatable {
        /// The first line of the file, and the subject Mail and the share sheet offer.
        let title: String
        /// The name offered to the share UI and used for a Mail attachment.
        let displayName: String
        let body: String
        let jobCount: Int
        let lineCount: Int
        /// AI turns in the file, and how many of them failed.
        var turnCount: Int = 0
        var failedTurnCount: Int = 0
        /// What the masking pass found, by kind, for the person to see before sending.
        var redactionHits: [String] = []
    }

    // MARK: - Choosing the jobs

    /// The sessions a scope covers, oldest first — the order the day happened in.
    ///
    /// A day is the day a job **started**, so a job that ran past midnight belongs to the day it
    /// began, the same day the Job tab's list files it under. Cancelled jobs are included: a job
    /// abandoned because something went wrong is the one support most wants to read.
    static func sessions(for scope: Scope, in sessions: [FieldSession],
                         calendar: Calendar) -> [FieldSession] {
        let chosen: [FieldSession]
        switch scope {
        case .job(let id):
            chosen = sessions.filter { $0.id == id }
        case .day(let day):
            chosen = sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
        }
        return chosen.sorted { $0.startedAt < $1.startedAt }
    }

    /// A calendar day that has jobs on it.
    struct Day: Identifiable, Equatable {
        /// The start of the day, in the calendar it was grouped with.
        let day: Date
        let jobCount: Int
        var id: Date { day }
    }

    /// One entry per day that has at least one job, newest first, with how many jobs it has.
    static func days(in sessions: [FieldSession], calendar: Calendar) -> [Day] {
        Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
            .map { Day(day: $0.key, jobCount: $0.value.count) }
            .sorted { $0.day > $1.day }
    }

    /// The half-open window a day scope covers.
    static func window(of day: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    // MARK: - Lines

    /// A thread's messages as transcript lines: user and assistant only, trimmed, in time order,
    /// optionally limited to a window. System messages are left out — they are instructions the app
    /// gave the model, not something anyone said.
    static func lines(of messages: [ConversationMessage], within window: (start: Date, end: Date)? = nil) -> [Line] {
        messages.compactMap { message in
            let speaker: Speaker
            switch message.role {
            case "user": speaker = .technician
            case "assistant": speaker = .assistant
            default: return nil
            }
            if let window, message.timestamp < window.start || message.timestamp >= window.end { return nil }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Line(timestamp: message.timestamp, speaker: speaker, text: text,
                        imageAttached: message.imageAttached)
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    /// A job's lines: its conversation when that is still on the phone, and otherwise the
    /// technician's words from its job log.
    ///
    /// `thread` is the thread the job owns (`FieldSession.conversationThreadId`), or nil when the
    /// job never had one or it has been deleted.
    static func job(session: FieldSession, vaultName: String, thread: ConversationThread?,
                    events: [SessionLogger.Event]) -> Job {
        let spoken = lines(of: thread?.messages ?? [])

        let source: Source
        let chosen: [Line]
        if !spoken.isEmpty {
            source = .conversation
            chosen = spoken
        } else {
            let logged: [Line] = events.compactMap { event in
                guard event.kind == .userMessage,
                      let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return Line(timestamp: event.timestamp, speaker: .technician, text: text,
                            imageAttached: false)
            }
            source = logged.isEmpty ? .nothing : .jobLogOnly
            chosen = logged.sorted { $0.timestamp < $1.timestamp }
        }

        let reference = session.jobReference.flatMap { $0.isEmpty ? nil : $0 }
        return Job(
            sessionId: session.id,
            jobNumber: reference.map { "Job \($0)" } ?? JobTabModel.noJobNumber,
            vaultName: vaultName,
            equipment: session.equipment?.modelToken,
            outcome: session.outcome.displayName,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            threadId: session.conversationThreadId,
            source: source,
            lines: chosen)
    }

    // MARK: - The file

    /// The sentence at the top of every file. It travels in the file because the file outlives
    /// the screen it was made on, and whoever opens it should know what it can contain.
    static let preamble = """
        What the technician said, as the phone transcribed it, and what the assistant replied. \
        Times are the phone's clock. This file can contain customer names, addresses and anything \
        else said on site: share it only with people who should see these jobs.
        """

    static let troubleshootingPreamble = """
        Troubleshooting details are included: for each AI turn, which model answered, what went \
        with the words (the parts of the instructions by size, manual pages, photos, tools), how \
        long it took and how it ended; each job's own log; this phone and the glasses; and the \
        app's event log. The words sent to the AI are the transcript lines themselves. Keys and \
        tokens are masked.
        """

    static let jobLogOnlyNote = """
        The assistant's replies for this job are no longer on the phone. Below are the \
        technician's words from the job log only.
        """

    static let nothingNote = "Nothing said on this job is on the phone."

    static let untracedNote = """
        No AI turn records: turns in the live voice modes are not recorded yet, and turn recording \
        can be switched off in the Developer panel.
        """

    /// Render the file. `jobs` and `conversations` must already be in the order they should appear.
    /// With `details`, the troubleshooting layer is added and the whole body is masked with
    /// `secrets` plus the shared patterns.
    static func document(scope: Scope, jobs: [Job], exportedAt: Date, timeZone: TimeZone,
                         conversations: [Conversation] = [], details: Details? = nil,
                         secrets: [String] = []) -> Document {
        let format = Format(timeZone: timeZone)
        let troubleshooting = details != nil
        let kind = troubleshooting ? "support report" : "transcript"

        let title: String
        let displayName: String
        switch scope {
        case .job:
            let job = jobs.first
            let name = job?.jobNumber ?? JobTabModel.noJobNumber
            let date = job.map { format.date($0.startedAt) } ?? format.date(exportedAt)
            title = "\(name) \(kind) — \(date)"
            displayName = "\(name) \(kind) \(date).txt"
        case .day(let day):
            let date = format.date(day)
            let count = jobs.count == 1 ? "1 job" : "\(jobs.count) jobs"
            if troubleshooting {
                title = "Support report — \(date) (\(count))"
                displayName = "Support report \(date).txt"
            } else {
                title = "Job transcripts — \(date) (\(count))"
                displayName = "Job transcripts \(date).txt"
            }
        }

        var out: [String] = [
            "OpenGlasses — \(title)",
            "Exported \(format.dateTime(exportedAt)) (\(format.offset(exportedAt)))",
            "",
            preamble,
        ]
        if troubleshooting { out += ["", troubleshootingPreamble] }

        // Which traces belong where. A trace is claimed by the first thing it matches, so no turn
        // is printed twice.
        var unclaimed = details?.traces ?? []
        func claim(_ matches: (TurnTrace) -> Bool) -> [TurnTrace] {
            let mine = unclaimed.filter(matches)
            unclaimed.removeAll(where: matches)
            return mine
        }

        if jobs.isEmpty && conversations.isEmpty {
            out += ["", "No jobs."]
        }

        var printedTurns = 0
        var failedTurns = 0

        for job in jobs {
            out += ["", rule("="), jobHeading(job, format: format), "Vault: \(job.vaultName)",
                    jobTimes(job, format: format), rule("-")]
            switch job.source {
            case .conversation: break
            case .jobLogOnly: out += [jobLogOnlyNote, ""]
            case .nothing: out.append(nothingNote)
            }

            let traces = claim { trace in
                trace.fieldSessionId == job.sessionId
                    || (trace.threadId != nil && trace.threadId == job.threadId)
            }
            printedTurns += traces.count
            failedTurns += traces.filter { $0.outcome == .failed }.count
            let events = (details?.jobEvents[job.sessionId] ?? []).filter {
                $0.kind != .userMessage && $0.kind != .assistantMessage
            }
            out += timeline(lines: job.lines, traces: traces, events: events,
                            reference: job.startedAt, format: format)
            if troubleshooting && traces.isEmpty && !job.lines.isEmpty {
                out += ["", untracedNote]
            }
        }

        for conversation in conversations {
            out += ["", rule("="), "Outside a job: \(conversation.title)", rule("-")]
            let traces = claim { $0.threadId == conversation.threadId }
            printedTurns += traces.count
            failedTurns += traces.filter { $0.outcome == .failed }.count
            let reference = conversation.lines.first?.timestamp ?? traces.first?.at ?? exportedAt
            out += timeline(lines: conversation.lines, traces: traces, events: [],
                            reference: reference, format: format)
        }

        if let details {
            // Turns nothing above claimed: a conversation that was not saved, or one outside a job
            // when only jobs were asked for. Only on a day that asked for everything, so a job's
            // report never carries turns from outside it.
            if case .day = scope, !conversations.isEmpty || jobs.isEmpty, !unclaimed.isEmpty {
                out += ["", rule("="), "Other AI turns (no saved conversation)", rule("-")]
                printedTurns += unclaimed.count
                failedTurns += unclaimed.filter { $0.outcome == .failed }.count
                let reference = unclaimed.first?.at ?? exportedAt
                out += timeline(lines: [], traces: unclaimed, events: [], reference: reference,
                                format: format)
            }

            out += ["", rule("="), "This phone", rule("-")]
            out += details.phone.isEmpty ? ["(not available)"] : details.phone

            out += ["", rule("="), "App events (\(details.appEvents.count))", rule("-")]
            if details.appEvents.isEmpty {
                out.append("None in this period — the app keeps this run's events and the previous run's.")
            }
            for event in details.appEvents {
                out.append("\(format.time(event.at, seconds: true))  \(event.line)")
            }

            if !details.debugLog.isEmpty {
                out += ["", rule("="), "Debug log (newest \(details.debugLog.count))", rule("-")]
                out += details.debugLog
            }
        }

        var body = out.joined(separator: "\n") + "\n"
        var hits: [String] = []
        if troubleshooting {
            let masked = DiagnosticsRedactor.redact(body, extraSecrets: secrets)
            body = masked.redacted
            hits = masked.hits
        }
        let lineCount = jobs.reduce(0) { $0 + $1.lines.count }
            + conversations.reduce(0) { $0 + $1.lines.count }
        return Document(title: title, displayName: displayName, body: body,
                        jobCount: jobs.count, lineCount: lineCount,
                        turnCount: printedTurns, failedTurnCount: failedTurns,
                        redactionHits: hits)
    }

    // MARK: - Rendering

    private static func rule(_ character: Character) -> String {
        String(repeating: character, count: 60)
    }

    private static func jobHeading(_ job: Job, format: Format) -> String {
        var heading = [job.jobNumber]
        if let equipment = job.equipment { heading.append(equipment) }
        heading.append(job.outcome)
        return heading.joined(separator: " · ")
    }

    private static func jobTimes(_ job: Job, format: Format) -> String {
        var times = "Started \(format.dateTime(job.startedAt))"
        if let ended = job.endedAt {
            times += " · Ended \(format.sameDayTime(ended, as: job.startedAt))"
        } else {
            times += " · Still open"
        }
        return times
    }

    /// Transcript lines, AI turns and job-log events in one time order. At equal times a line
    /// comes before the turn that answered it, and the turn before any event it caused.
    private static func timeline(lines: [Line], traces: [TurnTrace], events: [SessionLogger.Event],
                                 reference: Date, format: Format) -> [String] {
        typealias Entry = (at: Date, rank: Int, render: (String) -> [String])
        var entries: [Entry] = []
        for line in lines {
            entries.append((line.timestamp, 0, { stamp in render(line, stamp: stamp) }))
        }
        for trace in traces {
            entries.append((trace.at, 1, { stamp in render(trace, stamp: stamp) }))
        }
        for event in events {
            entries.append((event.timestamp, 2, { stamp in render(event, stamp: stamp) }))
        }
        entries.sort { $0.at == $1.at ? $0.rank < $1.rank : $0.at < $1.at }
        return entries.flatMap { $0.render(format.sameDayTime($0.at, as: reference)) }
    }

    private static func render(_ line: Line, stamp: String) -> [String] {
        let photo = line.imageAttached ? "[with photo] " : ""
        let indent = String(repeating: " ", count: stamp.count + 2)
        let textLines = line.text.components(separatedBy: .newlines)
        var out = ["\(stamp)  \(line.speaker.rawValue): " + photo + (textLines.first ?? "")]
        for continuation in textLines.dropFirst() {
            out.append(continuation.isEmpty ? "" : indent + continuation)
        }
        return out
    }

    /// One AI turn, as a short block under the line it answered.
    static func render(_ trace: TurnTrace, stamp: String) -> [String] {
        let indent = String(repeating: " ", count: stamp.count + 4)
        // A turn with no model and no prompt never reached the AI: a voice command the app
        // handled itself. Said so, rather than reading as an AI answer with its details missing.
        let reachedAI = trace.backend != nil || !trace.promptBlocks.isEmpty
        let word: String
        switch trace.outcome {
        case .answered: word = reachedAI ? "answered" : "handled by the app (no AI request)"
        case .interrupted: word = "interrupted by the wearer"
        case .cancelled: word = "cancelled before it answered"
        case .failed: word = "FAILED"
        }
        var out = ["\(stamp)  · \(reachedAI ? "AI turn" : "Turn") \(word)"
                   + (trace.failure.map { " — \($0)" } ?? "")]

        var who = [[trace.backend, trace.model].compactMap { $0 }.joined(separator: " / ")]
        if let transcriber = trace.transcriber { who.append("transcribed by \(transcriber)") }
        if let mic = trace.micRoute { who.append("mic: \(mic)") }
        if let voice = trace.speechEngine { who.append("voice: \(voice)") }
        let whoLine = who.filter { !$0.isEmpty }.joined(separator: " · ")
        if !whoLine.isEmpty { out.append(indent + "model: " + whoLine) }

        if !trace.promptBlocks.isEmpty || trace.imageSent {
            var sent = "sent: the words above"
            if !trace.promptBlocks.isEmpty {
                let parts = trace.promptBlocks.map { "\($0.name) \($0.characters)" }.joined(separator: ", ")
                sent += " + instructions of \(trace.promptCharacters) characters (\(parts))"
            }
            if trace.imageSent { sent += " + a photo" }
            out.append(indent + sent)
        }
        if !trace.manualPassages.isEmpty {
            out.append(indent + "manual pages: " + trace.manualPassages.joined(separator: "; "))
        } else if trace.manualRefused {
            out.append(indent + "manual pages: none — the manual search found nothing it would stand behind")
        }
        if !trace.toolCalls.isEmpty {
            out.append(indent + "tools: " + trace.toolCalls.map { "\($0.name) (\($0.outcome))" }
                .joined(separator: ", "))
        }
        var timing: [String] = []
        if let first = trace.timeToFirstToken { timing.append("first output after \(seconds(first))") }
        if let backend = trace.backendSeconds { timing.append("reply complete after \(seconds(backend))") }
        if let tools = trace.toolSeconds { timing.append("tools took \(seconds(tools))") }
        if let heard = trace.perceivedLatency { timing.append("heard \(seconds(heard)) after speech ended") }
        if !timing.isEmpty { out.append(indent + "timing: " + timing.joined(separator: ", ")) }
        return out
    }

    private static func render(_ event: SessionLogger.Event, stamp: String) -> [String] {
        let name = event.kind.rawValue.replacingOccurrences(of: "_", with: " ")
        var line = "\(stamp)  [job] \(name)"
        if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let first = text.components(separatedBy: .newlines).first ?? text
            line += " — " + (first.count > 200 ? String(first.prefix(200)) + "…" : first)
        }
        return [line]
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    /// Fixed, unambiguous formats: a file read by someone in another country should not have to
    /// guess whether 03/04 is March or April.
    private struct Format {
        let timeZone: TimeZone
        private var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar
        }

        private func formatter(_ pattern: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter
        }

        func date(_ value: Date) -> String { formatter("yyyy-MM-dd").string(from: value) }
        func dateTime(_ value: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: value) }
        func time(_ value: Date, seconds: Bool) -> String {
            formatter(seconds ? "HH:mm:ss" : "HH:mm").string(from: value)
        }
        func offset(_ value: Date) -> String { formatter("'UTC'xxx").string(from: value) }

        /// Time only when `value` falls on the same day as `reference`; date and time otherwise, so
        /// a line after midnight, or a debrief the next morning, is not read as the same day.
        func sameDayTime(_ value: Date, as reference: Date) -> String {
            calendar.isDate(value, inSameDayAs: reference)
                ? formatter("HH:mm").string(from: value)
                : dateTime(value)
        }
    }
}

/// Assembles a transcript or a support report from the live stores, and writes it where the share
/// sheet can take it.
///
/// The one place the pure builder meets `FieldSessionService`, `ConversationStore`,
/// `TurnTraceStore` and the disk.
@MainActor
enum JobTranscriptExporter {

    struct Options: Equatable {
        /// Add the troubleshooting layer, and mask keys and tokens.
        var troubleshooting = false
        /// On a day, also include conversations held outside any job.
        var otherConversations = false
    }

    /// What only the app can supply: the phone and glasses, the app's event log, the debug log and
    /// the configured secrets to mask.
    struct Environment {
        var phone: [String] = []
        var appEvents: [JobTranscriptExport.AppEvent] = []
        var debugLog: [String] = []
        var secrets: [String] = []
    }

    enum Failure: Error, Equatable {
        /// Conversations are encrypted and locked. Exporting now would print "no longer on the
        /// phone" for every job, which is untrue, so the caller unlocks first or says why not.
        case conversationsLocked
        case nothingToExport
        case writeFailed

        var message: String {
            switch self {
            case .conversationsLocked:
                return "Conversations are locked. Unlock them with Face ID to export what was said."
            case .nothingToExport:
                return "There's nothing on this phone for that."
            case .writeFailed:
                return "The file could not be written on this phone. Try again."
            }
        }
    }

    static func document(_ scope: JobTranscriptExport.Scope,
                         options: Options = Options(),
                         sessions: FieldSessionService,
                         store: ConversationStore,
                         traces: TurnTraceStore = .shared,
                         environment: Environment = Environment(),
                         now: Date = Date(),
                         calendar: Calendar = .current) -> Result<JobTranscriptExport.Document, Failure> {
        guard !store.isLocked else { return .failure(.conversationsLocked) }
        let chosen = JobTranscriptExport.sessions(for: scope, in: sessions.history, calendar: calendar)
        let jobs = chosen.map { session in
            JobTranscriptExport.job(
                session: session,
                vaultName: VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId,
                thread: session.conversationThreadId.flatMap { id in
                    store.threads.first { $0.id == id }
                },
                events: SessionLogger.readEvents(at: sessions.sessionDirectory(sessionId: session.id)))
        }

        // The period the scope covers: the day, or the job from start to finish with a margin for
        // the events either side of it.
        let window: (start: Date, end: Date)
        switch scope {
        case .day(let day):
            window = JobTranscriptExport.window(of: day, calendar: calendar)
        case .job:
            let start = (chosen.first?.startedAt ?? now).addingTimeInterval(-5 * 60)
            let end = (chosen.first?.endedAt ?? now).addingTimeInterval(5 * 60)
            window = (start, max(end, start))
        }

        var conversations: [JobTranscriptExport.Conversation] = []
        if case .day = scope, options.otherConversations {
            let jobThreads = Set(sessions.history.compactMap(\.conversationThreadId))
            conversations = store.threads
                .filter { !jobThreads.contains($0.id) }
                .compactMap { thread in
                    let lines = JobTranscriptExport.lines(of: thread.messages, within: window)
                    guard !lines.isEmpty else { return nil }
                    return .init(threadId: thread.id, title: thread.title, lines: lines)
                }
                .sorted { ($0.lines.first?.timestamp ?? now) < ($1.lines.first?.timestamp ?? now) }
        }

        var details: JobTranscriptExport.Details?
        if options.troubleshooting {
            let jobIds = Set(chosen.map(\.id))
            let jobThreadIds = Set(chosen.compactMap(\.conversationThreadId))
            let scoped: [TurnTrace]
            switch scope {
            case .day:
                scoped = traces.traces(from: window.start, to: window.end)
            case .job:
                // A job's turns by what they belong to, whenever they happened — a debrief the
                // next morning is still this job's.
                scoped = traces.all.filter { trace in
                    trace.fieldSessionId.map { jobIds.contains($0) } == true
                        || trace.threadId.map { jobThreadIds.contains($0) } == true
                }
            }
            var events: [String: [SessionLogger.Event]] = [:]
            for session in chosen {
                events[session.id] = SessionLogger.readEvents(
                    at: sessions.sessionDirectory(sessionId: session.id))
            }
            details = .init(
                traces: scoped,
                jobEvents: events,
                phone: environment.phone,
                appEvents: environment.appEvents.filter { $0.at >= window.start && $0.at < window.end },
                debugLog: environment.debugLog)
        }

        if jobs.isEmpty && conversations.isEmpty && (details?.traces.isEmpty ?? true) {
            if case .day = scope, options.troubleshooting {
                // A report on a day with nothing said can still carry the phone and the app's
                // events — which is exactly the report for "it wouldn't even start".
            } else {
                return .failure(.nothingToExport)
            }
        }

        return .success(JobTranscriptExport.document(
            scope: scope, jobs: jobs, exportedAt: now, timeZone: calendar.timeZone,
            conversations: conversations, details: details, secrets: environment.secrets))
    }

    /// Write the document to a protected, short-lived file. The lease is released when the share
    /// finishes, however it finishes, by the caller's share completion.
    static func lease(for document: JobTranscriptExport.Document,
                      coordinator: StagedExportCoordinator = .fieldSession) throws -> StagedExportLease {
        let lease = try coordinator.makeLease(data: Data(document.body.utf8), fileExtension: "txt",
                                              displayName: document.displayName,
                                              fallbackName: "job-transcript.txt")
        PrivacyLog.transfer(.fieldSessionExport, .exported, count: document.lineCount,
                            total: document.jobCount)
        return lease
    }
}
