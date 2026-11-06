import Foundation

/// The job as it stands, for an expert (Plan KM §3, P1).
///
/// One value, written three ways — the `.ogcase` package (`ExpertHandoverFile`), a PDF and a plain
/// text file (`ExpertHandoverRendering`) — so the expert with the app and the expert without it
/// read the same thing. Built by `ExpertHandoverBuilder`, which is pure: everything in here comes
/// from the job's own record, the job's conversation, the photos the technician chose, and what
/// the technician said for this send.
///
/// **Minimal by construction (§8):**
/// - **No customer identity.** The site is the town only; the address goes only to the
///   organisation's own staff experts, and only when its profile says so (decision 2). The
///   customer's name and contact have no field.
/// - **No page images.** A manual is named by title, page and section (`ManualReference`), and
///   this type has nowhere to put a picture of a page. The only pictures are the job's own photos,
///   each through the blur (`ExpertHandoverPhotos`).
/// - **No rate, no troubleshooting.** The expert's rate, model names, prompt sizes and usage have
///   no field, and the builder is never handed them.
struct ExpertHandover: Codable, Equatable, Sendable {

    /// What the file says it is. A reader refuses anything else.
    static let typeIdentifier = "openglasses.handover"
    static let version = 1
    /// A handover, as distinct from the replies P2 and P3 add (`time`, `coaching`).
    static let kind = "handover"

    let type: String
    let version: Int
    let kind: String

    // MARK: Identity and rules

    /// The same for every generation sent to one expert for one job: what the expert's app
    /// replaces an earlier generation by.
    let handoverId: String
    /// 1 for the first send, and one more for each "send the latest".
    let generation: Int
    let createdAt: Date
    let organisation: Organisation
    /// How many days after Done the expert's app keeps it (§7).
    let retentionDays: Int
    /// Who it was sent to: the list entry's id and name, so a reply can be matched to it. Never a
    /// kind, a number or a rate.
    let expert: Expert

    // MARK: The job

    let job: Job
    let work: Work
    let conversation: Conversation
    let photos: [Photo]
    /// What the technician chose that did not go, and why — so the expert knows a picture exists.
    let photosLeftOut: PhotosLeftOut
    let manualReferences: [ManualReference]
    /// What the technician wants help with, as they said it.
    let question: String?

    struct Organisation: Codable, Equatable, Sendable {
        /// The organisation's name, or empty when the phone has none.
        let name: String
        /// "Confidential to <organisation>".
        let confidentiality: String
    }

    struct Expert: Codable, Equatable, Sendable {
        let id: String
        let name: String
    }

    struct Job: Codable, Equatable, Sendable {
        let reference: String?
        /// The trades the job's vault declares, in words ("Refrigeration & HVAC").
        let trades: [String]
        let faultReport: FaultReportText?
        let unit: Unit?
        let site: Site?
    }

    struct FaultReportText: Codable, Equatable, Sendable {
        /// The office's or the customer's words, verbatim.
        let text: String
        /// Who said it, as the record attributes it ("from the job file").
        let source: String
    }

    struct Unit: Codable, Equatable, Sendable {
        /// What the technician said the model was.
        let model: String?
        /// The vault section it matched, when that is not simply what was said.
        let matchedSection: String?
        /// Everything read off the machine — serial, board part number, firmware, refrigerant —
        /// each with where it came from.
        let identity: [IdentityField]
    }

    struct IdentityField: Codable, Equatable, Sendable {
        let name: String
        let value: String
        let source: String
    }

    struct Site: Codable, Equatable, Sendable {
        let town: String?
        /// Only for the organisation's own staff experts, with its profile's say-so.
        let address: String?
    }

    struct Work: Codable, Equatable, Sendable {
        let tasks: [TaskLine]
        let procedures: [ProcedureLine]
        let readings: [Reading]
        /// Steps done differently or skipped. No deviation record exists on the phone yet (Plan
        /// JL P1), so this is empty until one does; it is here so the expert's view has a place.
        let deviations: [String]
        /// What the technician said they have ruled out, in their words — never inferred.
        let ruledOut: [String]
    }

    struct TaskLine: Codable, Equatable, Sendable {
        let title: String
        /// `recommended`, `accepted`, `declined`, `deferred`, `in_progress`, `done`, `abandoned`.
        let status: String
        /// What the technician said they did.
        let note: String?
    }

    struct ProcedureLine: Codable, Equatable, Sendable {
        let procedure: String
        let stepsDone: Int
        /// The procedure's outcome, or nil while it is still in progress.
        let outcome: String?
    }

    struct Reading: Codable, Equatable, Sendable {
        let quantity: String
        let value: String
        let unit: String?
        /// How it was taken: said by the technician, read off a photo of the instrument, or
        /// worked from the vault's tables.
        let source: String
        let at: Date
    }

    struct Conversation: Codable, Equatable, Sendable {
        let included: Bool
        let lines: [Line]
    }

    struct Line: Codable, Equatable, Sendable {
        let at: Date
        /// "Technician" or "Assistant".
        let speaker: String
        let text: String
    }

    struct Photo: Codable, Equatable, Sendable {
        /// The entry inside the package: `photos/01.jpg`.
        let file: String
        let capturedAt: Date
        let caption: String?
    }

    struct PhotosLeftOut: Codable, Equatable, Sendable {
        /// Chosen, but the blur could not process them, so they stayed on the phone.
        let couldNotBeBlurred: Int
        /// Chosen, but over the channel's size limit; the oldest go first.
        let overSizeLimit: Int

        static let none = PhotosLeftOut(couldNotBeBlurred: 0, overSizeLimit: 0)
        var total: Int { couldNotBeBlurred + overSizeLimit }
    }

    /// A manual page named, never shown: a manufacturer's manual, a code book or a My Manuals
    /// upload is not the technician's to send on.
    struct ManualReference: Codable, Equatable, Sendable {
        let title: String
        let page: Int?
        let section: String?
    }
}

// MARK: - Retention

/// How long the expert's app keeps a handover after Done (§7): 30 days unless the organisation
/// shortens it.
enum ExpertHandoverRetention {
    static let defaultDays = 30
    static let range: ClosedRange<Int> = 1...30

    /// The days a profile's string names, or nil when it is not a whole number in range.
    static func days(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
              let days = Int(trimmed), range.contains(days) else { return nil }
        return days
    }
}

// MARK: - The town

/// The town of a site, from the address as it was given (decision 2): the expert needs where the
/// unit is, not who owns it.
///
/// There is no town field — `JobSite` keeps the address exactly as the office gave it — so this
/// reads one out, conservatively. It **never returns the first comma-separated part**, which is
/// where a street and number live, and never anything with a digit in it; postcodes and two- or
/// three-letter region codes are stepped over from the end. An address it cannot read gives no
/// town at all rather than a guess.
enum SiteTown {
    static func town(fromAddress address: String?) -> String? {
        guard let address else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        for part in parts.dropFirst().reversed() {
            let words = part.split(separator: " ").map(String.init).filter { word in
                // A postcode, or a region code ("IL", "NSW"), is not the town.
                !word.contains(where: \.isNumber) && !(word.count <= 3 && word == word.uppercased() && word.allSatisfy(\.isLetter))
            }
            let candidate = words.joined(separator: " ")
            guard !candidate.isEmpty, candidate.count <= 60,
                  !candidate.contains(where: \.isNumber) else { continue }
            return candidate
        }
        return nil
    }
}

// MARK: - When the handover is offered

/// Whether the handover is offered at all (§8). Pure.
///
/// **Medical Compliance never offers it**: a clinical room's details do not go to someone outside
/// it by a messaging app. With Field Assist locked, or nobody listed, there is nobody to send to.
enum ExpertHandoverAvailability: Equatable {
    case offered
    case refused(String)

    static let medicalReason = "Sending a job to an expert is off in Medical Compliance mode."
    static let notEntitledReason = "Field Assist isn't unlocked on this device."
    static let noExpertsReason = "No experts are listed in Settings → Field Assist → Experts."
    static let noJobReason = "There's no open job to send."

    static func decide(mode: MedicalEgressGuard.Mode, entitled: Bool, hasExperts: Bool,
                       hasOpenJob: Bool) -> ExpertHandoverAvailability {
        if mode.hipaaMode { return .refused(medicalReason) }
        if !entitled { return .refused(notEntitledReason) }
        if !hasOpenJob { return .refused(noJobReason) }
        if !hasExperts { return .refused(noExpertsReason) }
        return .offered
    }

    var isOffered: Bool { self == .offered }
}

// MARK: - What was sent, per generation

/// One handover this phone sent, kept on the job (Plan KM P1): which generation, to whom, by what
/// and what it carried — counts and photo ids, never a photo's pixels. The next "send the latest"
/// reads it for the generation number and the technician's own words.
struct ExpertHandoverSent: Codable, Equatable, Sendable {
    let handoverId: String
    let generation: Int
    let expert: ExpertSnapshot
    /// `DeliveryChannel`'s raw value.
    let channel: String
    let sentAt: Date
    /// The job photos (`JobMediaItem.id`) that went, in the order they went.
    let photoIds: [String]
    let photosLeftOut: ExpertHandover.PhotosLeftOut
    let transcriptIncluded: Bool
    let addressIncluded: Bool
    let tasks: Int
    let readings: Int
    let manualReferences: Int
    let question: String?
    let ruledOut: [String]
}

/// The handover id and generation the next send carries. Pure.
///
/// One id per job and expert, for as long as the job has it; the generation is one more than the
/// last one sent to that expert. A send that was never confirmed leaves no record, so the next
/// attempt reuses its number.
enum ExpertHandoverLedger {
    static func next(expertId: String, sent: [ExpertHandoverSent],
                     newId: () -> String = { UUID().uuidString }) -> (handoverId: String, generation: Int) {
        let mine = sent.filter { $0.expert.id == expertId }
        guard let last = mine.max(by: { $0.generation < $1.generation }) else { return (newId(), 1) }
        return (last.handoverId, last.generation + 1)
    }

    /// The latest generation sent to each expert: what the expert's app now shows, since a later
    /// generation replaces an earlier one.
    static func current(_ sent: [ExpertHandoverSent]) -> [ExpertHandoverSent] {
        var latest: [String: ExpertHandoverSent] = [:]
        for record in sent where (latest[record.handoverId]?.generation ?? 0) < record.generation {
            latest[record.handoverId] = record
        }
        return latest.values.sorted { $0.sentAt < $1.sentAt }
    }
}

// MARK: - The builder

/// Builds the handover from the job's own record (§3). **Pure:** every input is a value, so every
/// rule — the town, the address, the conversation, the references, the generation — is a test.
enum ExpertHandoverBuilder {

    /// What the organisation has set for handovers.
    struct Organisation: Equatable, Sendable {
        var name: String
        var transcriptRule: ReportTranscriptPolicy.ExpertRule?
        /// `expertHandoverIncludesAddress`: the address for the organisation's own staff experts.
        var includesAddressForStaff: Bool
        var retentionDays: Int

        init(name: String = "", transcriptRule: ReportTranscriptPolicy.ExpertRule? = nil,
             includesAddressForStaff: Bool = false,
             retentionDays: Int = ExpertHandoverRetention.defaultDays) {
            self.name = name
            self.transcriptRule = transcriptRule
            self.includesAddressForStaff = includesAddressForStaff
            self.retentionDays = retentionDays
        }
    }

    /// What the technician said or set for this send.
    struct Choice: Equatable, Sendable {
        /// "Include the conversation", when the technician touched it; nil when not.
        var transcript: Bool?
        var question: String?
        /// What they have ruled out, one item each, in their words.
        var ruledOut: [String]

        init(transcript: Bool? = nil, question: String? = nil, ruledOut: [String] = []) {
            self.transcript = transcript
            self.question = question
            self.ruledOut = ruledOut
        }
    }

    /// A photo that has already been through the blur and the budget (`ExpertHandoverPhotos`).
    /// The builder sees where it will sit in the package, never its pixels.
    struct PreparedPhoto: Equatable, Sendable {
        let itemId: String
        let capturedAt: Date
        let caption: String?
    }

    struct Input: Equatable {
        let session: FieldSession
        /// The trades the job's vault declares, as the vault writes them.
        var vaultTrades: [String] = []
        /// The expert this goes to, and which list they are on.
        let expert: ExpertListEntry
        var organisation: Organisation = Organisation()
        var choice: Choice = Choice()
        /// The job's conversation, as `JobTranscriptExport` selects it — the thread when it is on
        /// the phone, the technician's words from the log otherwise.
        var conversation: [JobTranscriptExport.Line] = []
        /// Every source the job's answers cited, as `SessionExporter` collects them.
        var citations: [String] = []
        var procedures: [SessionExport.ProcedureRun] = []
        /// Procedure deviations, once a record of them exists (Plan JL P1). Empty today.
        var deviations: [String] = []
        var photos: [PreparedPhoto] = []
        var photosLeftOut: ExpertHandover.PhotosLeftOut = .none
        let handoverId: String
        let generation: Int
        let now: Date
    }

    enum Refusal: Error, Equatable {
        case medicalMode
    }

    /// Whether this expert may be sent the site's address: the organisation's own staff, from its
    /// own list, with its profile's say-so (decision 2). A contracted expert and a personal
    /// addition never are.
    static func addressAllowed(for expert: ExpertListEntry, includesAddressForStaff: Bool) -> Bool {
        includesAddressForStaff && expert.source == .organization && expert.contact.kind == .staff
    }

    /// The handover, or why not. Medical Compliance refuses here too, not only where the button
    /// is: the tool and the sheet both reach this.
    static func build(_ input: Input, mode: MedicalEgressGuard.Mode) -> Result<ExpertHandover, Refusal> {
        guard !mode.hipaaMode else { return .failure(.medicalMode) }
        let session = input.session
        let organisation = input.organisation
        let onList = input.expert.source == .organization

        // The job.
        let identity = session.identityFields.map {
            ExpertHandover.IdentityField(name: $0.name, value: $0.value, source: $0.source.provenancePhrase)
        }
        let unit: ExpertHandover.Unit? = (session.equipment == nil && identity.isEmpty) ? nil
            : ExpertHandover.Unit(model: session.equipment?.stated,
                                  matchedSection: session.equipment?.vaultSectionIfDifferent,
                                  identity: identity)
        let address = addressAllowed(for: input.expert, includesAddressForStaff: organisation.includesAddressForStaff)
            ? session.site?.address : nil
        let town = SiteTown.town(fromAddress: session.site?.address)
        let site: ExpertHandover.Site? = (town == nil && address == nil) ? nil
            : ExpertHandover.Site(town: town, address: address)
        let trades = FieldTrade.known(input.vaultTrades).map(\.title)
        let job = ExpertHandover.Job(
            reference: session.jobReference.flatMap { $0.isEmpty ? nil : $0 },
            trades: trades,
            faultReport: session.faultReport.map { .init(text: $0.text, source: $0.source.attribution) },
            unit: unit, site: site)

        // The work so far, as the record says it.
        let tasks = session.tasks.map {
            ExpertHandover.TaskLine(title: $0.title, status: $0.status.rawValue, note: $0.completionNote)
        }
        let superseded = Set(session.spokenReadings.compactMap(\.supersedes))
        let readings = session.spokenReadings.filter { !superseded.contains($0.id) }.map {
            ExpertHandover.Reading(quantity: $0.quantity, value: $0.value, unit: $0.unit,
                                   source: readingSource($0), at: $0.at)
        }
        let procedures = input.procedures.map {
            ExpertHandover.ProcedureLine(procedure: $0.procedureId, stepsDone: $0.stepsCompleted, outcome: $0.outcome)
        }
        let work = ExpertHandover.Work(tasks: tasks, procedures: procedures, readings: readings,
                                       deviations: input.deviations,
                                       ruledOut: cleanedLines(input.choice.ruledOut))

        // The conversation, under the expert audience.
        let decision = ReportTranscriptPolicy.forExpert(onOrganisationList: onList,
                                                        rule: organisation.transcriptRule,
                                                        technicianChoice: input.choice.transcript)
        let lines = decision.includesTranscript
            ? input.conversation.map { ExpertHandover.Line(at: $0.timestamp, speaker: $0.speaker.rawValue, text: $0.text) }
            : []

        // Photos: already blurred and fitted. Numbered in the order they go.
        let photos = input.photos.enumerated().map { index, photo in
            ExpertHandover.Photo(file: ExpertHandoverFile.photoEntryName(index: index),
                                 capturedAt: photo.capturedAt, caption: photo.caption)
        }

        let name = organisation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let handover = ExpertHandover(
            type: ExpertHandover.typeIdentifier, version: ExpertHandover.version, kind: ExpertHandover.kind,
            handoverId: input.handoverId, generation: input.generation, createdAt: input.now,
            organisation: .init(name: name, confidentiality: confidentiality(name)),
            retentionDays: ExpertHandoverRetention.range.contains(organisation.retentionDays)
                ? organisation.retentionDays : ExpertHandoverRetention.defaultDays,
            expert: .init(id: input.expert.contact.id, name: input.expert.contact.name),
            job: job, work: work,
            conversation: .init(included: decision.includesTranscript && !lines.isEmpty, lines: lines),
            photos: photos, photosLeftOut: input.photosLeftOut,
            manualReferences: references(input.citations, expert: input.expert),
            question: cleanedQuestion(input.choice.question))
        return .success(handover)
    }

    /// "Confidential to Acme Heating", or to the sender when the phone has no organisation name.
    static func confidentiality(_ name: String) -> String {
        name.isEmpty ? "Confidential to the sender" : "Confidential to \(name)"
    }

    /// How a reading was taken, in the words the expert reads.
    static func readingSource(_ reading: SpokenReading) -> String {
        if reading.isInstrumentReading { return "read off a photo of the instrument" }
        if reading.isRuleChain { return "worked from the manual's tables" }
        return "said by the technician"
    }

    /// The manuals the job's answers cited, by reference only, once each. A team learning is the
    /// organisation's own (contract §8) and goes only to its own staff experts.
    static func references(_ sources: [String], expert: ExpertListEntry) -> [ExpertHandover.ManualReference] {
        let ownStaff = expert.source == .organization && expert.contact.kind == .staff
        var seen = Set<String>()
        var out: [ExpertHandover.ManualReference] = []
        for source in sources {
            for citation in CitationLineParser.citations(inBody: source) {
                if citation.isTeamLearning && !ownStaff { continue }
                let reference = ExpertHandover.ManualReference(
                    title: citation.title, page: citation.page,
                    section: citation.figure ?? citation.section)
                guard seen.insert("\(reference.title)|\(reference.page ?? -1)|\(reference.section ?? "")").inserted else { continue }
                out.append(reference)
            }
        }
        return out
    }

    /// The question as said: trimmed, at most 1,000 characters, nil when empty.
    static func cleanedQuestion(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(1_000))
    }

    /// Trimmed, empty lines dropped, at most 20 of at most 500 characters.
    static func cleanedLines(_ lines: [String]) -> [String] {
        lines.flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(500)) }
            .prefix(20).map { $0 }
    }
}
