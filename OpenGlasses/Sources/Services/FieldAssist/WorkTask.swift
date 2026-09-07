import Foundation

// A recommendation, a decision, and the evidence that the decision was carried out.
//
// Before this, a session could answer from the manuals, show the page and know the machine, and
// none of it was tied to anything anyone did. The types here are that tie: a recommendation the
// model makes is a `Task` in state `recommended` and nothing more until the technician says so;
// a part number is only written down once something has been looked up; and what base is asked
// for is its own object with its own status, because a stock check leaves before the job is done.

extension FieldSession {

    /// Something to be done on this visit — proposed by the assistant, or added by the technician.
    ///
    /// Declines and deferrals are kept. "Recommended, not done" is information a reviewer wants,
    /// and dropping it would make the record flatter than the visit was.
    struct Task: Codable, Equatable, Identifiable {

        /// Who put it on the job. An operator task never had a recommendation behind it, which is
        /// allowed: a technician does work nobody suggested.
        enum Origin: String, Codable {
            case recommended
            /// `operator` is a Swift keyword, so the case is spelled out; the wire value is not.
            case operatorAdded = "operator"
        }

        enum Status: String, Codable {
            case recommended
            case accepted
            case declined
            case deferred
            case inProgress = "in_progress"
            case done
            case abandoned

            /// Whether work can still be recorded against it.
            var isOpen: Bool {
                switch self {
                case .recommended, .accepted, .inProgress: return true
                case .declined, .deferred, .done, .abandoned: return false
                }
            }
        }

        let id: String
        var title: String
        /// Why the assistant recommended it, or why the technician noted it.
        var why: String?
        let origin: Origin
        var status: Status
        /// The vault procedure this task runs, when it names one. Validated against the vault's
        /// library before the task is created — a task cannot point at a procedure that isn't there.
        var procedureId: String?
        /// The procedure's terminal outcome, once it has one. This is what closes the task.
        var procedureOutcome: String?
        /// The source the recommendation cited. Required for a recommended task; a recommendation
        /// the model cannot cite is refused before a task exists.
        var citation: String?
        var safetyNote: String?
        var parts: [TaskPart]
        /// Readings, photos, opened citations and verified pages recorded while this task was the
        /// active one.
        var evidence: Evidence
        /// What the technician said they did.
        var completionNote: String?
        let createdAt: Date
        var acceptedAt: Date?
        var completedAt: Date?

        init(id: String = UUID().uuidString,
             title: String,
             why: String? = nil,
             origin: Origin,
             status: Status,
             procedureId: String? = nil,
             procedureOutcome: String? = nil,
             citation: String? = nil,
             safetyNote: String? = nil,
             parts: [TaskPart] = [],
             evidence: Evidence = Evidence(),
             completionNote: String? = nil,
             createdAt: Date = Date(),
             acceptedAt: Date? = nil,
             completedAt: Date? = nil) {
            self.id = id
            self.title = title
            self.why = why
            self.origin = origin
            self.status = status
            self.procedureId = procedureId
            self.procedureOutcome = procedureOutcome
            self.citation = citation
            self.safetyNote = safetyNote
            self.parts = parts
            self.evidence = evidence
            self.completionNote = completionNote
            self.createdAt = createdAt
            self.acceptedAt = acceptedAt
            self.completedAt = completedAt
        }

        /// How long the task was open for, from the moment it was taken on to the moment it closed.
        /// Nil while it is still running, and for a task that was never accepted.
        var elapsed: TimeInterval? {
            guard let acceptedAt, let completedAt else { return nil }
            return completedAt.timeIntervalSince(acceptedAt)
        }
    }

    /// What was recorded while a task was active — or against the job, when none was.
    ///
    /// One type for both because they are the same evidence seen from two places: a reading taken
    /// with no task running belongs to the visit, not to nothing.
    struct Evidence: Codable, Equatable {
        /// Capture-record identifiers (`CaptureRecord.id`).
        var readings: [String] = []
        /// Photo file names inside the session's `photos/` directory.
        var photos: [String] = []
        /// Citation labels a technician opened.
        var citationsOpened: [String] = []
        /// "<document>, page N" for every page actually put on screen.
        var pagesVerified: [String] = []

        var isEmpty: Bool {
            readings.isEmpty && photos.isEmpty && citationsOpened.isEmpty && pagesVerified.isEmpty
        }
    }
}

/// A part a task names, with what the vault could say about it.
///
/// `verified` is the whole point: base validates a number that came from the book, not one that
/// fell out of a misheard sentence, and an unverified number is carried through the record and
/// spoken as unverified rather than quietly dropped or quietly trusted.
struct TaskPart: Codable, Equatable {
    /// The number as it was said or written, uppercased for comparison.
    let number: String
    /// What the vault calls it, when the vault knows it.
    var partDescription: String?
    var verified: Bool
    /// Where it was found — a core file and heading, or a manual and page.
    var page: String?

    init(number: String, partDescription: String? = nil, verified: Bool = false, page: String? = nil) {
        self.number = number
        self.partDescription = partDescription
        self.verified = verified
        self.page = page
    }

    enum CodingKeys: String, CodingKey {
        case number
        case partDescription = "description"
        case verified, page
    }

    /// "14T65 (High-altitude pressure switch) — verified, SLP99UHVK Service Manual, page 3".
    var summary: String {
        var line = number
        if let partDescription, !partDescription.isEmpty { line += " (\(partDescription))" }
        if verified {
            line += page.map { " — verified, \($0)" } ?? " — verified"
        } else {
            line += " — unverified, not found in the manuals"
        }
        return line
    }
}

/// Something base is being asked for. It may stand on its own: a technician raises a stock check
/// before knowing whether the repair is going ahead, and tying it to a task would lose that.
struct PartsRequest: Codable, Equatable, Identifiable {

    enum Urgency: String, Codable {
        case routine
        case today
        case emergency
    }

    enum Status: String, Codable {
        case requested
        case sent
        case answered
    }

    let id: String
    let part: TaskPart
    var quantity: Int
    /// The task it came out of, when it came out of one.
    var taskId: String?
    /// The machine it is for, when the session knows it.
    var modelToken: String?
    var urgency: Urgency
    /// Whether the technician already has one on the van.
    var onVan: Bool
    var status: Status
    /// What base said. **Reported, never acted on** — it is spoken to the technician and attached
    /// here, and it changes no task and no recommendation by itself.
    var baseAnswer: String?
    let createdAt: Date
    var answeredAt: Date?

    init(id: String = UUID().uuidString,
         part: TaskPart,
         quantity: Int = 1,
         taskId: String? = nil,
         modelToken: String? = nil,
         urgency: Urgency = .routine,
         onVan: Bool = false,
         status: Status = .requested,
         baseAnswer: String? = nil,
         createdAt: Date = Date(),
         answeredAt: Date? = nil) {
        self.id = id
        self.part = part
        self.quantity = quantity
        self.taskId = taskId
        self.modelToken = modelToken
        self.urgency = urgency
        self.onVan = onVan
        self.status = status
        self.baseAnswer = baseAnswer
        self.createdAt = createdAt
        self.answeredAt = answeredAt
    }

    /// "2 × 14T65 (High-altitude pressure switch) — verified, … — routine, not on the van".
    var summary: String {
        var line = "\(quantity) × \(part.summary)"
        line += " — \(urgency.rawValue)"
        line += onVan ? ", one on the van" : ", not on the van"
        if let baseAnswer, !baseAnswer.isEmpty { line += ". Base: \(baseAnswer)" }
        return line
    }
}

/// One field read off the machine itself — model, serial, board part number, firmware, refrigerant.
///
/// The source matters more than the value. Digits are where recognition fails quietly, so a record
/// that cannot say whether a serial was read by a camera or spoken by a technician is a record a
/// warranty department cannot use.
struct DeviceIdentityField: Codable, Equatable {

    enum Source: String, Codable {
        /// Read off the nameplate by on-device text recognition.
        case nameplate
        /// The technician read it aloud.
        case spoken
        /// Shown on the equipment's own display or control board.
        case display
    }

    let name: String
    let value: String
    let source: Source
    let recordedAt: Date

    init(name: String, value: String, source: Source, recordedAt: Date = Date()) {
        self.name = name
        self.value = value
        self.source = source
        self.recordedAt = recordedAt
    }

    /// "Serial: 5820A12345 (from the nameplate)".
    var summary: String {
        "\(name): \(value) (\(source.provenancePhrase))"
    }
}

extension DeviceIdentityField.Source {
    var provenancePhrase: String {
        switch self {
        case .nameplate: return "from the nameplate"
        case .spoken: return "from the technician"
        case .display: return "from the unit's display"
        }
    }
}
