import Foundation

/// Writes a meeting's notes with a model (Plan MX P4). The model is a seam — two strings in, the
/// reply out — so the whole flow is tested with a fake; the app gives it the same stateless,
/// tool-free completion the meeting assistant's rounds use.
///
/// The whole transcript goes in one call when it fits the budget. A longer one is cut into parts
/// (at line, then sentence ends), each condensed to at most twelve short lines, and the notes pass
/// reads the parts' notes; when those still do not fit they are condensed again, up to three
/// rounds in all, and whatever is left is cut to the budget at a line end. A round that does not
/// shrink the text stops condensing. The notes are then checked against the original transcript
/// (`MeetingNotesVerifier`).
///
/// **Steps, and stopping between them.** Each model call is one step, and `mayStep` is asked
/// before every one (each part and the notes pass). When it says no, the write stops there and
/// throws `Stopped` with what it has done, which a later write resumes from. A step already
/// running is never abandoned: the write returns or throws only once its call has ended.
struct MeetingNotesWriter: Sendable {

    typealias Complete = @Sendable (_ system: String, _ user: String) async throws -> String
    typealias MayStep = @Sendable () async -> Bool

    enum Failure: Error, Equatable {
        case emptyTranscript
        case emptyReply
    }

    /// The write stopped before a step because `mayStep` said no; `progress` resumes it.
    struct Stopped: Error, Equatable {
        let progress: Progress
    }

    /// How far a write got: the text being condensed and the round in progress.
    struct Progress: Equatable, Sendable {
        /// The text the next round condenses (or the notes pass reads), as lines.
        var textLines: [String]
        /// Whether `textLines` are condensed notes rather than the transcript.
        var condensed = false
        var rounds = 0
        var calls = 0
        /// Condensing is over: the notes pass is next.
        var condensingDone = false
        /// The round in progress: its parts, and the condensed lines of the parts done so far.
        var roundParts: [String]? = nil
        var roundLines: [String] = []
        var partsDone = 0
    }

    struct Written: Equatable, Sendable {
        let notes: MeetingNotes
        /// Model calls made, the notes pass included (across resumed writes).
        let calls: Int
        /// Condensing rounds (0 when the transcript fitted whole).
        let rounds: Int
    }

    static let maximumRounds = 3

    let complete: Complete

    init(complete: @escaping Complete) {
        self.complete = complete
    }

    /// `lines` are the transcript's lines, oldest first, a speaker's name before a diarized one;
    /// `budget` is characters of transcript a call may carry (`MeetingNotesBudget`). `resuming` is
    /// a stopped write's progress over the same lines.
    func write(lines: [String], budget: Int, resuming saved: Progress? = nil,
               mayStep: MayStep = { true }) async throws -> Written {
        let kept = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !kept.isEmpty else { throw Failure.emptyTranscript }
        let transcript = kept.joined(separator: "\n")
        let limit = max(MeetingNotesBudget.minimumCharacters / 2, budget)

        var progress = saved ?? Progress(textLines: kept)
        while !progress.condensingDone {
            if progress.roundParts == nil {
                guard progress.textLines.joined(separator: "\n").count > limit,
                      progress.rounds < Self.maximumRounds else {
                    progress.condensingDone = true
                    break
                }
                progress.roundParts = MeetingNotesBudget.parts(of: progress.textLines, budget: limit)
                progress.roundLines = []
                progress.partsDone = 0
            }
            let parts = progress.roundParts ?? []
            while progress.partsDone < parts.count {
                guard await mayStep() else { throw Stopped(progress: progress) }
                try Task.checkCancellation()
                let index = progress.partsDone
                let reply = try await complete(MeetingNotesPrompt.condenseSystem,
                                               MeetingNotesPrompt.condenseUser(parts[index], part: index, of: parts.count,
                                                                               condensed: progress.condensed))
                progress.calls += 1
                progress.roundLines.append(contentsOf: MeetingNotesParser.condensedLines(reply))
                progress.partsDone += 1
            }
            progress.rounds += 1
            guard !progress.roundLines.isEmpty else { throw Failure.emptyReply }
            let before = progress.textLines.joined(separator: "\n").count
            progress.textLines = progress.roundLines
            progress.condensed = true
            progress.roundParts = nil
            progress.roundLines = []
            progress.partsDone = 0
            if progress.textLines.joined(separator: "\n").count >= before { progress.condensingDone = true }
        }
        let text = Self.cut(progress.textLines, to: limit)

        guard await mayStep() else { throw Stopped(progress: progress) }
        try Task.checkCancellation()
        let reply = try await complete(MeetingNotesPrompt.notesSystem,
                                       MeetingNotesPrompt.notesUser(text, condensed: progress.condensed))
        progress.calls += 1
        guard let parsed = MeetingNotesParser.parse(reply) else { throw Failure.emptyReply }
        let verified = MeetingNotesVerifier.verify(parsed, against: transcript)
        guard !verified.isEmpty else { throw Failure.emptyReply }
        return Written(notes: verified, calls: progress.calls, rounds: progress.rounds)
    }

    /// The lines, oldest first, that fit `limit`, cut at a line end (a single overlong line is
    /// cut at the limit).
    static func cut(_ lines: [String], to limit: Int) -> String {
        var out: [String] = []
        var used = 0
        for line in lines {
            let cost = out.isEmpty ? line.count : line.count + 1
            if used + cost > limit {
                if out.isEmpty { out.append(String(line.prefix(limit))) }
                break
            }
            out.append(line)
            used += cost
        }
        return out.joined(separator: "\n")
    }
}
