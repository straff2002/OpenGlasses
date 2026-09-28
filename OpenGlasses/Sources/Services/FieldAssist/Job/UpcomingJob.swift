import Foundation

/// Where a job is, as the office or the technician gave it (Plan FO §7, P3c).
///
/// Every field is optional and is kept **exactly as given** — never geocoded, reformatted or filled
/// in from anything else. A brief that has no address says so; it does not look one up.
struct JobSite: Codable, Equatable {
    var customer: String?
    var address: String?
    var contact: String?

    init(customer: String? = nil, address: String? = nil, contact: String? = nil) {
        self.customer = JobSite.cleaned(customer)
        self.address = JobSite.cleaned(address)
        self.contact = JobSite.cleaned(contact)
    }

    var isEmpty: Bool { customer == nil && address == nil && contact == nil }

    /// "Smith & Co, 14 Smith Street" — what a row and the car read out. Never the contact: a phone
    /// number is not something to read aloud at a set of traffic lights unless asked.
    var headline: String? {
        let parts = [customer, address].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Trim, and treat whitespace as absent. The only cleaning a site field gets.
    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// What somebody said was wrong, verbatim, and who said it.
///
/// The words are the office's or the customer's, never a model's paraphrase: the brief matches
/// candidates *against* them, and a report that had been tidied up would be matched against
/// somebody else's reading of the fault.
struct FaultReport: Codable, Equatable {
    enum Source: String, Codable, Equatable {
        /// The technician said it ("next job: 1007, no heat …").
        case spoken
        /// Typed on the Job tab.
        case typed
        /// Carried in by an `.ogjob` file.
        case jobFile = "job_file"

        /// How the brief attributes the words.
        var attribution: String {
            switch self {
            case .spoken: return "as you said it"
            case .typed: return "as typed on this phone"
            case .jobFile: return "from the job file"
            }
        }
    }

    let text: String
    let source: Source
    let receivedAt: Date

    init(text: String, source: Source, receivedAt: Date = Date()) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        // Whole seconds, for the reason `JobDebrief.Turn` gives: this travels in documents encoded
        // with different date strategies.
        self.receivedAt = Date(timeIntervalSince1970: receivedAt.timeIntervalSince1970.rounded(.down))
    }

    enum CodingKeys: String, CodingKey {
        case text, source
        case receivedAt = "received_at"
    }
}

/// A machine the office says is on site. Either half may be missing.
struct KnownEquipment: Codable, Equatable {
    var model: String?
    var serial: String?

    init(model: String? = nil, serial: String? = nil) {
        self.model = JobSite.cleaned(model)
        self.serial = JobSite.cleaned(serial)
    }

    var isEmpty: Bool { model == nil && serial == nil }

    var summary: String {
        switch (model, serial) {
        case let (model?, serial?): return "\(model), serial \(serial)"
        case let (model?, nil): return model
        case let (nil, serial?): return "serial \(serial)"
        case (nil, nil): return "unknown machine"
        }
    }
}

/// Where a job file came from, kept on the upcoming job and then on the visit's record
/// (Plan FO §8).
struct JobFileProvenance: Codable, Equatable {
    enum Signature: String, Codable, Equatable {
        /// Verified against the organisation's key.
        case signed
        /// No signature at all.
        case unsigned
        /// Signed, but this phone holds no organisation key to check it against — treated exactly
        /// as unsigned, because a signature nobody can check proves nothing.
        case unverifiable
    }

    /// The file's name as it arrived — never its path, which is a location inside this phone.
    let fileName: String
    let signature: Signature
    /// The organisation whose key verified it. Nil unless `signature == .signed`: a name an
    /// unsigned file *claims* is never recorded as a signer.
    let signer: String?
    let receivedAt: Date
    /// SHA-256 of the bytes that were opened, so two copies of "the same" file can be told apart.
    let digest: String

    init(fileName: String, signature: Signature, signer: String?, receivedAt: Date = Date(),
         digest: String) {
        self.fileName = fileName
        self.signature = signature
        self.signer = signature == .signed ? signer : nil
        self.receivedAt = Date(timeIntervalSince1970: receivedAt.timeIntervalSince1970.rounded(.down))
        self.digest = digest
    }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case signature, signer
        case receivedAt = "received_at"
        case digest
    }

    /// The line the work order and the audit log carry.
    ///
    /// "Opened from another app" rather than "from email": the operating system hands the app a
    /// copy of the file and never says which app it came from, so the record cannot claim Mail.
    var recordLine: String {
        let date = receivedAt.formatted(date: .abbreviated, time: .shortened)
        switch signature {
        case .signed:
            return "Job file \(fileName), opened \(date), signed by \(signer ?? "the organisation")."
        case .unsigned:
            return "Job file \(fileName), opened \(date), not signed."
        case .unverifiable:
            return "Job file \(fileName), opened \(date), signed with a key this phone could not check."
        }
    }
}

/// A job that exists before it starts (Plan FO §7, P3c).
///
/// **Not a `FieldSession`.** The plan asked for a `scheduled` state on the session; that would
/// have made every scheduled job an unfinished session, and the launch restore reopens the first
/// unfinished session it finds — so the day's third job would have come back as the open one,
/// counting time. A job ahead is its own value in its own store, and *starting* it is the ordinary
/// `startJob`, which copies its number, site, fault report and brief onto the new session.
///
/// Nothing here is guessed: a field nobody gave stays nil, and the brief says so.
struct UpcomingJob: Codable, Equatable, Identifiable {

    enum Origin: String, Codable, Equatable {
        case spoken
        case typed
        case jobFile = "job_file"
    }

    let id: String
    var jobReference: String?
    var site: JobSite
    var faultReport: FaultReport?
    var equipment: [KnownEquipment]
    var scheduledFor: Date?
    var notes: String?
    /// Attachments a job file named, by reference only. Never fetched by the app — shown so the
    /// technician knows the office meant to send something.
    var attachments: [String]
    let origin: Origin
    var provenance: JobFileProvenance?
    /// The last brief assembled for it, kept so the job tab can show it without re-reading the
    /// vault and so a started job's context begins from what the technician actually heard.
    var brief: JobBrief?
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         jobReference: String? = nil,
         site: JobSite = JobSite(),
         faultReport: FaultReport? = nil,
         equipment: [KnownEquipment] = [],
         scheduledFor: Date? = nil,
         notes: String? = nil,
         attachments: [String] = [],
         origin: Origin,
         provenance: JobFileProvenance? = nil,
         brief: JobBrief? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.jobReference = JobIntakeState.cleaned(jobReference)
        self.site = site
        self.faultReport = faultReport.flatMap { $0.text.isEmpty ? nil : $0 }
        self.equipment = equipment.filter { !$0.isEmpty }
        self.scheduledFor = scheduledFor
        self.notes = JobSite.cleaned(notes)
        self.attachments = attachments
        self.origin = origin
        self.provenance = provenance
        self.brief = brief
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case jobReference = "job_reference"
        case site
        case faultReport = "fault_report"
        case equipment
        case scheduledFor = "scheduled_for"
        case notes, attachments, origin, provenance, brief
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Hand-written for the reason `FieldSession`'s is: a job saved by this build must still load
    /// in the next one when a field is added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        jobReference = try c.decodeIfPresent(String.self, forKey: .jobReference)
        site = try c.decodeIfPresent(JobSite.self, forKey: .site) ?? JobSite()
        faultReport = try c.decodeIfPresent(FaultReport.self, forKey: .faultReport)
        equipment = try c.decodeIfPresent([KnownEquipment].self, forKey: .equipment) ?? []
        scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .typed
        provenance = try c.decodeIfPresent(JobFileProvenance.self, forKey: .provenance)
        brief = try c.decodeIfPresent(JobBrief.self, forKey: .brief)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// "Job 1007", or the site when the office gave no number, or "Upcoming job" — never blank.
    var title: String {
        if let jobReference { return "Job \(jobReference)" }
        if let headline = site.headline { return headline }
        return "Upcoming job"
    }

    /// What a row, the car and a switch announcement say about it, in one line.
    var spoken: String {
        var parts = [title]
        if jobReference != nil, let headline = site.headline { parts.append(headline) }
        if let scheduledFor {
            parts.append(scheduledFor.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: ", ")
    }

    /// The address directions go to, when there is one.
    var destination: String? { site.address }
}
