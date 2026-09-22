import Foundation

/// One piece of evidence a job carries: a photo today, a clip later.
///
/// `FieldSession.Evidence.photos` already records *that* a photo was taken, as a bare file name
/// under the session's `photos/` directory. That was enough while the only reader was a text bullet
/// in the work order. It is not enough to review evidence at close: a technician choosing what the
/// customer sees needs to know when each picture was taken, which task it belongs to, what it was
/// captioned, and — because the answer changes what the recipient will actually see — whether the
/// face blur was on when the bytes were written.
///
/// So this is the catalogue that sits beside the file names. The names stay the identity: they are
/// unique by construction (`SessionLogger.attachPhoto` stamps a timestamp and a uuid fragment), they
/// are what `Evidence.photos` already holds, and they are what the share sheet hands out. Nothing
/// here duplicates the bytes or the evidence list — it describes them.
struct JobMediaItem: Codable, Equatable, Identifiable {

    /// What the file is. `clip` is declared and not yet produced: the selection model, the review
    /// grid and the export all have to be able to hold a second kind before clips arrive, or adding
    /// them means reshaping every one of them.
    enum Kind: String, Codable, CaseIterable {
        case photo
        case clip

        /// The word the review grid and the read-out use.
        var noun: String { self == .photo ? "photo" : "clip" }
    }

    /// The route the evidence arrived by. It decides the default: a picture taken *in order to*
    /// document something is part of the record unless the technician says otherwise, and a picture
    /// taken for some other reason is offered rather than assumed.
    enum Origin: String, Codable, CaseIterable {
        /// `photo_log` — captured expressly to document the job.
        case photoLog = "photo_log"
        /// `capture_photo` — the wearer asked the assistant to look at something.
        case capture
        /// Taken with the phone's own camera while the job was open.
        case phoneCamera = "phone_camera"
        /// Chosen from the phone's photo library.
        case photoLibrary = "photo_library"

        /// Whether evidence from this route is part of the report unless the technician removes it.
        var isIncludedByDefault: Bool { self == .photoLog }

        /// Where it came from, in the words the review grid uses.
        var shortLabel: String {
            switch self {
            case .photoLog: return "Logged on the job"
            case .capture: return "Taken by the assistant"
            case .phoneCamera: return "Phone camera"
            case .photoLibrary: return "From the photo library"
            }
        }
    }

    /// The file name inside the session's `photos/` directory — the same string
    /// `FieldSession.Evidence.photos` holds.
    let id: String
    let kind: Kind
    let capturedAt: Date
    let origin: Origin
    /// The task it was recorded against, or nil when it belongs to the job itself.
    let taskId: String?
    /// What it documents. Editable at review; the capture-time caption is the starting point.
    var caption: String?
    /// Whether the app-wide face blur was on when these bytes were stored.
    ///
    /// Recorded rather than inferred. The setting is app-wide and can be changed between one photo
    /// and the next, the stored copy is the filtered one and cannot be un-blurred, and a technician
    /// deciding what a customer sees is entitled to know which of these pictures had the blur
    /// applied to them. Reading `Config.privacyFilterEnabled` at review time would answer a
    /// different question.
    let filterWasOn: Bool

    init(id: String, kind: Kind = .photo, capturedAt: Date, origin: Origin,
         taskId: String? = nil, caption: String? = nil, filterWasOn: Bool) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.origin = origin
        self.taskId = taskId
        self.caption = caption
        self.filterWasOn = filterWasOn
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, origin, caption
        case capturedAt = "captured_at"
        case taskId = "task_id"
        case filterWasOn = "filter_was_on"
    }

    /// Hand-written for the same reason `FieldSession`'s is: a session written before this existed
    /// has none of it, and a kind or an origin this build does not know is a file it can still show.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) .flatMap { $0 } ?? .photo
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date(timeIntervalSince1970: 0)
        origin = (try? c.decodeIfPresent(Origin.self, forKey: .origin)).flatMap { $0 } ?? .photoLog
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        filterWasOn = try c.decodeIfPresent(Bool.self, forKey: .filterWasOn) ?? false
    }

    /// The time under the thumbnail and under the image in the PDF.
    var timeLabel: String {
        capturedAt.formatted(date: .omitted, time: .shortened)
    }

    /// One sentence for VoiceOver: what it shows, which task, when, and how it will travel.
    func spoken(taskTitle: String?, included: Bool, role: EvidenceSelection.Role?) -> String {
        var parts: [String] = [caption?.isEmpty == false ? caption! : "No caption"]
        parts.append(taskTitle ?? "Against the job itself")
        parts.append(timeLabel)
        if let role { parts.append(role.label) }
        parts.append(included ? "Included in the report" : "Not included")
        if filterWasOn { parts.append("Captured with face blur on") }
        return parts.joined(separator: ", ") + "."
    }
}
