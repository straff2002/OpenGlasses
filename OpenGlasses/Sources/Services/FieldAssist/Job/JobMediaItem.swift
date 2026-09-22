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

    /// What the file is. A photo is a still in `photos/`; a clip is a length-capped MP4 beside
    /// it, recorded off the same blurred frame relay every other outbound consumer reads (Plan FO
    /// P2b).
    enum Kind: String, Codable, CaseIterable {
        case photo
        case clip

        /// The word the review grid and the read-out use.
        var noun: String { self == .photo ? "photo" : "clip" }

        /// The plural, for a count.
        var plural: String { self == .photo ? "photos" : "clips" }
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
        /// `record_clip`, or the Job tab's record button — a length-capped clip of the job
        /// (Plan FO P2b).
        case clipRecord = "record_clip"

        /// Whether evidence from this route is part of the report unless the technician removes it.
        var isIncludedByDefault: Bool { self == .photoLog }

        /// Where it came from, in the words the review grid uses.
        var shortLabel: String {
            switch self {
            case .photoLog: return "Logged on the job"
            case .capture: return "Taken by the assistant"
            case .phoneCamera: return "Phone camera"
            case .photoLibrary: return "From the photo library"
            case .clipRecord: return "Recorded on the job"
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
    /// How long a clip runs, in seconds. Nil for a photo — and nil is the only honest value for a
    /// clip whose writer died before it could be measured, which is why it is not defaulted to
    /// zero.
    let durationSeconds: TimeInterval?
    /// The file's size on disk, measured once when it was written. A clip's size is what decides
    /// whether a channel can carry it (`AttachmentBudget`), and measuring it at delivery time
    /// would make the same job produce different reports on different days.
    let byteCount: Int?
    /// The still the grid and the report show for a clip: **a frame off the same blurred relay**,
    /// written at capture. Decoding one out of the file at review time would be a second pass over
    /// pixels whose blur is already baked in, and would fail exactly when the file is the thing
    /// that went wrong.
    let posterId: String?
    /// True when the recording ended before the technician asked it to — the cap ran out, the
    /// stream stopped, or the job was closed underneath it. What was captured is kept; the label
    /// is what stops it being mistaken for the whole thing.
    let cutShort: Bool

    init(id: String, kind: Kind = .photo, capturedAt: Date, origin: Origin,
         taskId: String? = nil, caption: String? = nil, filterWasOn: Bool,
         durationSeconds: TimeInterval? = nil, byteCount: Int? = nil,
         posterId: String? = nil, cutShort: Bool = false) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.origin = origin
        self.taskId = taskId
        self.caption = caption
        self.filterWasOn = filterWasOn
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.posterId = posterId
        self.cutShort = cutShort
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, origin, caption
        case capturedAt = "captured_at"
        case taskId = "task_id"
        case filterWasOn = "filter_was_on"
        case durationSeconds = "duration_seconds"
        case byteCount = "bytes"
        case posterId = "poster"
        case cutShort = "cut_short"
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
        durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount)
        posterId = try c.decodeIfPresent(String.self, forKey: .posterId)
        cutShort = try c.decodeIfPresent(Bool.self, forKey: .cutShort) ?? false
    }

    /// The time under the thumbnail and under the image in the PDF.
    var timeLabel: String {
        capturedAt.formatted(date: .omitted, time: .shortened)
    }

    /// Whether the report has to carry this one as a file of its own rather than drawing it.
    var travelsAsItsOwnFile: Bool { kind == .clip }

    /// "12 seconds" — how long a clip runs, in the words the grid, the read-out and the work order
    /// all use. Nil for a photo, and for a clip whose length was never measured.
    var durationLabel: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let whole = Int(durationSeconds.rounded())
        guard whole >= 60 else { return "\(whole) second\(whole == 1 ? "" : "s")" }
        let minutes = whole / 60, seconds = whole % 60
        let minutePart = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        guard seconds > 0 else { return minutePart }
        return minutePart + " \(seconds) second\(seconds == 1 ? "" : "s")"
    }

    /// The badge drawn over a clip's poster frame: "0:12". Nil for a photo.
    var durationBadge: String? {
        guard kind == .clip, let durationSeconds, durationSeconds > 0 else { return nil }
        let whole = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The label a size is stated in. Nil when nothing measured it.
    var sizeLabel: String? {
        guard let byteCount, byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// The file whose pixels stand in for this item on screen: the picture itself, or a clip's
    /// poster frame. Nil for a clip with no poster, which draws a placeholder rather than
    /// attempting to decode a video on a scrolling list.
    var previewFileName: String? {
        switch kind {
        case .photo: return id
        case .clip: return posterId
        }
    }

    /// Evidence of this shape is part of the report unless the technician removes it.
    ///
    /// **A clip never is**, whatever route it arrived by. Every other piece of evidence either
    /// travels inside the PDF or does not travel at all; a clip is the one that has to be carried
    /// as a file of its own and may not fit down the channel at all — so it is always something
    /// the technician chose, never something the app assumed.
    var isIncludedByDefault: Bool { kind == .photo && origin.isIncludedByDefault }

    /// One sentence for VoiceOver: what it is, what it shows, which task, when, and how it will
    /// travel.
    func spoken(taskTitle: String?, included: Bool, role: EvidenceSelection.Role?) -> String {
        var parts: [String] = [kind.noun.capitalized]
        if let durationLabel { parts.append(durationLabel) }
        parts.append(caption?.isEmpty == false ? caption! : "No caption")
        parts.append(taskTitle ?? "Against the job itself")
        parts.append(timeLabel)
        if let role { parts.append(role.label) }
        parts.append(included ? "Included in the report" : "Not included")
        if cutShort { parts.append("Cut short") }
        if filterWasOn { parts.append("Captured with face blur on") }
        return parts.joined(separator: ", ") + "."
    }
}
