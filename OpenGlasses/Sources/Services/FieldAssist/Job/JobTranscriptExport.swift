import Foundation

/// What was said on a job, or on every job in a day, as one plain-text file the technician can
/// send (support ask, 2026-09-26).
///
/// When a customer reports that something went wrong on site, the question support asks first is
/// "what did the technician say, and what did the assistant say back?". The answer is on the phone
/// already — a job owns a conversation thread (Plan FO P1), and the job log keeps the technician's
/// words — but the only way to read it was one bubble at a time on `JobTranscriptView`. This turns
/// the same messages into a file, so one tap and the share sheet replace screenshots.
///
/// **Pure.** The input is the sessions, the threads and the job-log events; the output is the
/// document. No store, no clock and no locale is read in here, so what the file says about a job
/// whose conversation has gone is a fixture test rather than a hope.
///
/// **Nothing is sent from here.** The file is handed to the share sheet, and the technician
/// chooses where it goes, which is the same rule the report composer follows.
enum JobTranscriptExport {

    /// One job, or every job started on one calendar day.
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
        let source: Source
        let lines: [Line]
    }

    struct Document: Equatable {
        /// The first line of the file, and the subject the share sheet offers.
        let title: String
        /// The name offered to the share UI. Never becomes the on-disk name.
        let displayName: String
        let body: String
        let jobCount: Int
        let lineCount: Int
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

    // MARK: - One job's lines

    /// A job's lines: its conversation when that is still on the phone, and otherwise the
    /// technician's words from its job log.
    ///
    /// `thread` is the thread the job owns (`FieldSession.conversationThreadId`), or nil when the
    /// job never had one or it has been deleted. System messages are left out: they are
    /// instructions the app gave the model, not something anyone said.
    static func job(session: FieldSession, vaultName: String, thread: ConversationThread?,
                    events: [SessionLogger.Event]) -> Job {
        let spoken: [Line] = (thread?.messages ?? []).compactMap { message in
            let speaker: Speaker
            switch message.role {
            case "user": speaker = .technician
            case "assistant": speaker = .assistant
            default: return nil
            }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Line(timestamp: message.timestamp, speaker: speaker, text: text,
                        imageAttached: message.imageAttached)
        }

        let source: Source
        let lines: [Line]
        if !spoken.isEmpty {
            source = .conversation
            lines = spoken
        } else {
            let logged: [Line] = events.compactMap { event in
                guard event.kind == .userMessage,
                      let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return Line(timestamp: event.timestamp, speaker: .technician, text: text,
                            imageAttached: false)
            }
            source = logged.isEmpty ? .nothing : .jobLogOnly
            lines = logged
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
            source: source,
            lines: lines.sorted { $0.timestamp < $1.timestamp })
    }

    // MARK: - The file

    /// The sentence at the top of every file. It travels in the file because the file outlives
    /// the screen it was made on, and whoever opens it should know what it can contain.
    static let preamble = """
        What the technician said, as the phone transcribed it, and what the assistant replied. \
        Times are the phone's clock. This file can contain customer names, addresses and anything \
        else said on site: share it only with people who should see these jobs.
        """

    static let jobLogOnlyNote = """
        The assistant's replies for this job are no longer on the phone. Below are the \
        technician's words from the job log only.
        """

    static let nothingNote = "Nothing said on this job is on the phone."

    /// Render the file. `jobs` must already be in the order they should appear.
    static func document(scope: Scope, jobs: [Job], exportedAt: Date,
                         timeZone: TimeZone) -> Document {
        let format = Format(timeZone: timeZone)

        let title: String
        let displayName: String
        switch scope {
        case .job:
            let job = jobs.first
            let name = job?.jobNumber ?? JobTabModel.noJobNumber
            let date = job.map { format.date($0.startedAt) } ?? format.date(exportedAt)
            title = "\(name) transcript — \(date)"
            displayName = "\(name) transcript \(date).txt"
        case .day(let day):
            let date = format.date(day)
            let count = jobs.count == 1 ? "1 job" : "\(jobs.count) jobs"
            title = "Job transcripts — \(date) (\(count))"
            displayName = "Job transcripts \(date).txt"
        }

        var out: [String] = [
            "OpenGlasses — \(title)",
            "Exported \(format.dateTime(exportedAt)) (\(format.offset(exportedAt)))",
            "",
            preamble,
        ]

        if jobs.isEmpty {
            out += ["", "No jobs."]
        }

        for job in jobs {
            out += ["", String(repeating: "=", count: 60)]
            var heading = [job.jobNumber]
            if let equipment = job.equipment { heading.append(equipment) }
            heading.append(job.outcome)
            out.append(heading.joined(separator: " · "))
            out.append("Vault: \(job.vaultName)")
            var times = "Started \(format.dateTime(job.startedAt))"
            if let ended = job.endedAt {
                times += " · Ended \(format.sameDayTime(ended, as: job.startedAt))"
            } else {
                times += " · Still open"
            }
            out.append(times)
            out.append(String(repeating: "-", count: 60))

            switch job.source {
            case .conversation: break
            case .jobLogOnly: out += [jobLogOnlyNote, ""]
            case .nothing: out.append(nothingNote)
            }

            for line in job.lines {
                let stamp = format.sameDayTime(line.timestamp, as: job.startedAt)
                let photo = line.imageAttached ? "[with photo] " : ""
                let prefix = "\(stamp)  \(line.speaker.rawValue): "
                let indent = String(repeating: " ", count: stamp.count + 2)
                let textLines = line.text.components(separatedBy: .newlines)
                out.append(prefix + photo + (textLines.first ?? ""))
                for continuation in textLines.dropFirst() {
                    out.append(continuation.isEmpty ? "" : indent + continuation)
                }
            }
        }

        let body = out.joined(separator: "\n") + "\n"
        return Document(title: title, displayName: displayName, body: body,
                        jobCount: jobs.count,
                        lineCount: jobs.reduce(0) { $0 + $1.lines.count })
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

/// Assembles a transcript from the live stores and writes it where the share sheet can take it.
///
/// The one place the pure builder meets `FieldSessionService`, `ConversationStore` and the disk.
@MainActor
enum JobTranscriptExporter {

    enum Failure: Error, Equatable {
        /// Conversations are encrypted and locked. Exporting now would print "no longer on the
        /// phone" for every job, which is untrue, so the caller unlocks first or says why not.
        case conversationsLocked
        case noJobs
        case writeFailed

        var message: String {
            switch self {
            case .conversationsLocked:
                return "Conversations are locked. Unlock them with Face ID to export what was said."
            case .noJobs:
                return "There are no jobs to export for that."
            case .writeFailed:
                return "The transcript could not be written on this phone. Try again."
            }
        }
    }

    static func document(_ scope: JobTranscriptExport.Scope,
                         sessions: FieldSessionService,
                         store: ConversationStore,
                         now: Date = Date(),
                         calendar: Calendar = .current) -> Result<JobTranscriptExport.Document, Failure> {
        guard !store.isLocked else { return .failure(.conversationsLocked) }
        let chosen = JobTranscriptExport.sessions(for: scope, in: sessions.history, calendar: calendar)
        guard !chosen.isEmpty else { return .failure(.noJobs) }
        let jobs = chosen.map { session in
            JobTranscriptExport.job(
                session: session,
                vaultName: VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId,
                thread: session.conversationThreadId.flatMap { id in
                    store.threads.first { $0.id == id }
                },
                events: SessionLogger.readEvents(at: sessions.sessionDirectory(sessionId: session.id)))
        }
        return .success(JobTranscriptExport.document(scope: scope, jobs: jobs, exportedAt: now,
                                                     timeZone: calendar.timeZone))
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
