import Foundation

/// One recording of what a technician already knows, one case per recording (Plan IM P1).
///
/// The partner's five-part structure is a prompt, not a form: the technician only talks, and the
/// phone keeps what they said — transcribed on the phone, redacted, and with its audio for 30 days
/// (decision 2) — until a reviewer drafts candidates from it (P2). Nothing here is reviewed, so
/// nothing here is ever retrieved or put into a prompt; it lives in its own store
/// (`ExperienceRecordingStore`) for the same reason team-learning candidates do.
///
/// A recording made while a job is open is not one of these: it files a `spoken` candidate on that
/// job, exactly as "note this for the team" does (see `ExperienceRecorder`).
struct ExperienceRecording: Codable, Equatable, Identifiable, Sendable {

    /// Where a recording is on its way to the team's experience. Only ever moves forward.
    enum Status: String, Codable, CaseIterable, Sendable {
        /// Kept on this phone; nothing has left it.
        case recorded
        /// Handed to the reviewer (Plan IM P3).
        case sent
        /// Drafted into candidates (Plan IM P2).
        case drafted
        /// Every drafted candidate has been decided.
        case reviewed

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// Whether a recording at this status may move to `next`. Forward only, and never to
        /// itself: a recording that was sent cannot become unsent, and a repeat is not a move.
        func canAdvance(to next: Status) -> Bool { next.rank > rank }

        /// What the recorder's list says about a recording at this status.
        var label: String {
            switch self {
            case .recorded: return String(localized: "On this phone")
            case .sent: return String(localized: "Sent for review")
            case .drafted: return String(localized: "Drafted")
            case .reviewed: return String(localized: "Reviewed")
            }
        }
    }

    /// What a recording is of (Plan IM P4). Each kind drafts to something different, and never to
    /// the other's: a case drafts learning candidates (P2); a site drafts a Plan HV site document
    /// (`SiteRecordingDrafter`) and never a learning candidate.
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// One case of what a technician knows, the partner's five parts (P1). The kind of every
        /// recording made before P4, which carries no kind at all.
        case experience
        /// "Tell me about this site": the units at one site, how they connect and what is local to it.
        case site
    }

    let id: String
    /// What it is of. Absent in a recording kept before P4, which reads as `.experience`; encoded
    /// only for a site, so an experience recording's bytes are what they were.
    let kind: Kind
    /// When the recording began. Whole seconds, as every team-learning date is.
    let createdAt: Date
    /// How long it ran, in whole seconds, never more than the cap.
    let duration: Int
    /// What was said, transcribed on the phone and redacted at capture.
    let transcript: String
    /// The names of the redaction patterns that fired on the transcript, in `SecretPatterns` order.
    let redactions: [String]
    /// The vault in force when it was recorded: the one a new job would start on.
    let vaultId: String
    /// The model as the technician named it, when the recording says which (filled by P2's
    /// drafting; P1 records none).
    var spokenModel: String?
    /// A site the recording names, which P2 moves to a site note rather than a learning
    /// (decision 6). P1 records none.
    var site: String?
    var status: Status
    /// When the audio was deleted, or nil while it is still on the phone. Nil with no audio file
    /// means none was kept (an audio file that could not be written).
    var audioDeletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case createdAt = "created_at"
        case duration
        case transcript
        case redactions
        case vaultId = "vault_id"
        case spokenModel = "spoken_model"
        case site
        case status
        case audioDeletedAt = "audio_deleted_at"
    }

    init(id: String = ExperienceRecording.newID(), kind: Kind = .experience, createdAt: Date, duration: Int,
         transcript: String, redactions: [String], vaultId: String, spokenModel: String? = nil,
         site: String? = nil, status: Status = .recorded, audioDeletedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.duration = max(0, min(duration, Int(ExperienceRecorderRules.recordingCap)))
        self.transcript = transcript
        self.redactions = redactions
        self.vaultId = vaultId
        self.spokenModel = spokenModel
        self.site = site
        self.status = status
        self.audioDeletedAt = audioDeletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .experience
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decode(Int.self, forKey: .duration)
        transcript = try c.decode(String.self, forKey: .transcript)
        redactions = try c.decode([String].self, forKey: .redactions)
        vaultId = try c.decode(String.self, forKey: .vaultId)
        spokenModel = try c.decodeIfPresent(String.self, forKey: .spokenModel)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        status = try c.decode(Status.self, forKey: .status)
        audioDeletedAt = try c.decodeIfPresent(Date.self, forKey: .audioDeletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if kind != .experience { try c.encode(kind, forKey: .kind) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(duration, forKey: .duration)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(redactions, forKey: .redactions)
        try c.encode(vaultId, forKey: .vaultId)
        try c.encodeIfPresent(spokenModel, forKey: .spokenModel)
        try c.encodeIfPresent(site, forKey: .site)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(audioDeletedAt, forKey: .audioDeletedAt)
    }

    /// A lowercase id with no dashes, the shape team-learning ids take, so a spoken handle works
    /// the same way here.
    static func newID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// "2:14": what the list shows for the duration.
    var formattedDuration: String { ExperienceRecorderRules.clock(TimeInterval(duration)) }
}

/// The recorder's fixed rules, in one place so the store, the recorder and the tests agree.
enum ExperienceRecorderRules {

    /// The hard cap on one recording (Plan IM P1): ten minutes.
    static let recordingCap: TimeInterval = 10 * 60

    /// How long a recording's audio stays on the phone that made it (decision 2).
    static let audioRetention: TimeInterval = 30 * 24 * 60 * 60

    /// How many recordings a phone keeps. Recordings already reviewed go first.
    static let entryCap = 200

    /// The longest transcript kept. Ten minutes of speech is well under this; anything longer is
    /// a recogniser running away, cut at the limit rather than kept whole.
    static let transcriptLimit = 20_000

    /// "m:ss".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The transcript rules: normalise, redact, bound. Pure.
enum ExperienceTranscript {

    struct Cleaned: Equatable {
        let text: String
        let redactions: [String]
    }

    /// Collapse whitespace, drop control characters, redact secrets and contact details with
    /// `SecretPatterns.redact`, and cut at the limit.
    static func clean(_ raw: String) -> Cleaned {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let (redacted, hits) = SecretPatterns.redact(collapsed)
        let order = SecretPatterns.all.map(\.name)
        let redactions = Array(Set(hits)).sorted {
            (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max)
        }
        let bounded = redacted.count > ExperienceRecorderRules.transcriptLimit
            ? String(redacted.prefix(ExperienceRecorderRules.transcriptLimit))
            : redacted
        return Cleaned(text: bounded, redactions: redactions)
    }

    /// A transcript as team-learning findings, for the open-job path: one finding if it fits the
    /// finding limit, else consecutive parts cut at a sentence end (or a word, failing that), each
    /// marked "Part n of m". Nothing is dropped. Measured in Unicode scalars, as the candidate's
    /// own limit is (`LearningCandidateText`), so a part this accepts is never refused there.
    static func findingParts(_ text: String, limit: Int = LearningCandidateText.findingLimit) -> [String] {
        let whole = text.trimmingCharacters(in: .whitespaces)
        guard !whole.isEmpty else { return [] }
        guard whole.unicodeScalars.count > limit else { return [whole] }
        // Room for the "Part 10 of 12: " label, in any of the app's languages.
        let room = max(1, limit - 40)
        var parts: [String] = []
        var rest = Array(whole)
        while !rest.isEmpty {
            // The longest prefix that fits the room.
            var fit = 0
            var scalars = 0
            while fit < rest.count {
                let next = rest[fit].unicodeScalars.count
                if scalars + next > room { break }
                scalars += next
                fit += 1
            }
            var cut = fit
            if fit < rest.count {
                let window = rest[..<fit]
                if let end = window.lastIndex(where: { ".!?".contains($0) }) {
                    cut = end + 1
                } else if let space = window.lastIndex(of: " "), space > 0 {
                    cut = space
                }
            }
            cut = max(1, cut)
            let piece = String(rest[..<cut]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { parts.append(piece) }
            rest = Array(rest[cut...].drop(while: { $0 == " " }))
        }
        guard parts.count > 1 else { return parts }
        return parts.enumerated().map { index, part in
            String(localized: "Part \(index + 1) of \(parts.count): \(part)")
        }
    }
}
