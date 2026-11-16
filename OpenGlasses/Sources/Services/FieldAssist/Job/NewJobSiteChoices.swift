import Foundation

/// One row of New job's site picker (Plan MD §2): today's job, a documented site, or a recent one.
///
/// Built by `NewJobSiteChoices` and nothing else, so what the picker lists, in which order and
/// shown how many times, is a test rather than a reading of the view.
struct NewJobSiteChoice: Identifiable, Equatable {

    enum Source: String, Equatable {
        /// Today's job from Scheduled, Workiz's included. Choosing it starts that job ahead.
        case scheduledJob = "scheduled_job"
        /// A site document in the vault in use.
        case documentedSite = "documented_site"
        /// A customer and address from one of this phone's finished jobs.
        case recentSite = "recent_site"
    }

    let id: String
    let source: Source
    /// What the row is called: a documented site's `location_label` (else its name), else the
    /// customer and address, else the job's title.
    let title: String
    /// The job ahead this row starts, for `scheduledJob`.
    var upcomingJobId: String? = nil
    var jobReference: String? = nil
    /// "Job 1007", for a scheduled job.
    var jobTitle: String? = nil
    var scheduledFor: Date? = nil
    /// The documented site the row is, or that today's job is at.
    var siteDocumentId: String? = nil
    /// The site document's name, which search also reads.
    var siteName: String? = nil
    var unitCount: Int = 0
    /// The customer and address the job would be filed under.
    var site: JobSite? = nil
    /// The client a connected job is for, so a documented site chosen for it can be remembered
    /// (Plan MD §4).
    var client: SiteSystemDocument.ExternalRef? = nil
    /// True when a scheduled job's documented site came with the job — its own match, or a client
    /// this phone already remembers — rather than being chosen now.
    var documentFromJob: Bool = false

    /// "4 units", or nil for a row with no documented site.
    var unitsPhrase: String? {
        guard siteDocumentId != nil else { return nil }
        return unitCount == 1 ? String(localized: "1 unit") : String(localized: "\(unitCount) units")
    }

    /// The line under the title: the job's number when the title is not it, the customer's details
    /// beside a documented site, and the unit count.
    var detail: String? {
        var parts: [String] = []
        if let jobTitle, jobTitle != title { parts.append(jobTitle) }
        if siteDocumentId != nil, let headline = site?.headline, headline != title { parts.append(headline) }
        if let unitsPhrase { parts.append(unitsPhrase) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Everything the search box compares, folded.
    var searchText: String {
        [title, jobReference, jobTitle, siteName, site?.customer, site?.address]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// What New job's site picker offers (Plan MD §2), pure over what the phone already holds.
///
/// One list, in the plan's order: today's jobs from Scheduled, the vault's documented sites, then
/// recent sites from this phone's finished jobs. **Each place once:** a scheduled job or a recent
/// site that is a documented site is shown as the documented site, with the customer's details
/// beside it; recent sites are deduplicated by `JobHistoryIndex.siteKey`, and one already on
/// today's list is not repeated.
enum NewJobSiteChoices {

    /// A customer and address from a finished job on this phone.
    struct RecentSite: Equatable {
        let site: JobSite
        let lastVisit: Date
        /// The documented site that job was matched to in this vault, when it was.
        var siteDocumentId: String? = nil
    }

    struct Inputs {
        var upcoming: [UpcomingJob] = []
        var documents: [SiteSystemDocument] = []
        var vaultId: String
        var recent: [RecentSite] = []
        /// The phone's remembered client sites for this vault (Plan MD §4).
        var clientSites: [SiteSystemDocument.ExternalRef: String] = [:]
        var now: Date = Date()
        var calendar: Calendar = .current
        /// How many recent sites the list offers.
        var recentLimit: Int = 8
    }

    static func choices(_ inputs: Inputs) -> [NewJobSiteChoice] {
        var documents: [String: SiteSystemDocument] = [:]
        for document in inputs.documents where documents[document.id] == nil { documents[document.id] = document }
        var result: [NewJobSiteChoice] = []
        var documentsShown = Set<String>()
        var siteKeysShown = Set<String>()

        // 1. Today's jobs, in schedule order.
        let today = UpcomingJobStore.ordered(inputs.upcoming.filter { job in
            job.scheduledFor.map { inputs.calendar.isDate($0, inSameDayAs: inputs.now) } ?? false
        })
        for job in today {
            let client = Self.client(of: job)
            let ownDocument = Self.documentId(of: job, vaultId: inputs.vaultId, client: client,
                                              clientSites: inputs.clientSites)
            let document = ownDocument.flatMap { documents[$0] }
            if let document { documentsShown.insert(document.id) }
            if let key = JobHistoryIndex.siteKey(job.site) { siteKeysShown.insert(key) }
            result.append(NewJobSiteChoice(
                id: "job:" + job.id, source: .scheduledJob,
                title: document.map(Self.label) ?? job.site.headline ?? job.title,
                upcomingJobId: job.id, jobReference: job.jobReference, jobTitle: job.title,
                scheduledFor: job.scheduledFor, siteDocumentId: document?.id, siteName: document?.name,
                unitCount: document?.units.count ?? 0, site: job.site.isEmpty ? nil : job.site,
                client: client, documentFromJob: document != nil))
        }

        // Recent sites, newest first, one per site key; a key on today's list is not repeated.
        var recent: [RecentSite] = []
        var recentIndex: [String: Int] = [:]
        for visit in inputs.recent.sorted(by: { $0.lastVisit > $1.lastVisit }) {
            guard let key = JobHistoryIndex.siteKey(visit.site), !siteKeysShown.contains(key) else { continue }
            if let index = recentIndex[key] {
                // An older visit to the same place may be the one that was matched to a document.
                if recent[index].siteDocumentId == nil, let id = visit.siteDocumentId {
                    recent[index].siteDocumentId = id
                }
                continue
            }
            recentIndex[key] = recent.count
            recent.append(visit)
        }
        // A recent site that is a documented site is shown as the documented site.
        var recentAtDocument: [String: RecentSite] = [:]
        for visit in recent {
            guard let id = visit.siteDocumentId, documents[id] != nil, recentAtDocument[id] == nil else { continue }
            recentAtDocument[id] = visit
        }

        // 2. The vault's documented sites, in the vault's order.
        for document in inputs.documents where !documentsShown.contains(document.id) {
            documentsShown.insert(document.id)
            result.append(NewJobSiteChoice(
                id: "site:" + document.id, source: .documentedSite, title: Self.label(document),
                siteDocumentId: document.id, siteName: document.name, unitCount: document.units.count,
                site: recentAtDocument[document.id]?.site))
        }

        // 3. Recent sites that are no documented site in this vault.
        let plain = recent.filter { visit in visit.siteDocumentId.map { documents[$0] == nil } ?? true }
        for visit in plain.prefix(max(0, inputs.recentLimit)) {
            guard let key = JobHistoryIndex.siteKey(visit.site) else { continue }
            result.append(NewJobSiteChoice(
                id: "recent:" + key, source: .recentSite, title: visit.site.headline ?? key, site: visit.site))
        }
        return result
    }

    /// The documented sites alone, for choosing one for a scheduled job that has none.
    static func documentedSites(_ documents: [SiteSystemDocument]) -> [NewJobSiteChoice] {
        choices(Inputs(documents: documents, vaultId: ""))
    }

    /// The rows whose text holds every word of the query, ignoring case and accents. An empty
    /// query keeps them all.
    static func filter(_ choices: [NewJobSiteChoice], query: String) -> [NewJobSiteChoice] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return choices }
        return choices.filter { choice in
            let text = fold(choice.searchText)
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// This phone's finished jobs with a site, as the picker's recent sites.
    static func recentSites(from sessions: [FieldSession], vaultId: String) -> [RecentSite] {
        sessions.compactMap { session in
            guard session.endedAt != nil, session.outcome != .cancelled,
                  let site = session.site, !site.isEmpty else { return nil }
            let document = session.siteSystem.flatMap { $0.applies(toVault: vaultId) ? $0.siteId : nil }
            return RecentSite(site: site, lastVisit: session.startedAt, siteDocumentId: document)
        }
    }

    // MARK: -

    /// What the technician hears a site called.
    static func label(_ document: SiteSystemDocument) -> String {
        document.locationLabel ?? document.name
    }

    /// The client a connected job is for: its system and `customer_id`.
    static func client(of job: UpcomingJob) -> SiteSystemDocument.ExternalRef? {
        guard let external = job.provenance?.external, let id = external.customerID else { return nil }
        return .init(system: external.system, id: id)
    }

    /// The documented site a job ahead already is: its own match in this vault, else a client this
    /// phone remembers.
    private static func documentId(of job: UpcomingJob, vaultId: String, client: SiteSystemDocument.ExternalRef?,
                                   clientSites: [SiteSystemDocument.ExternalRef: String]) -> String? {
        if let match = job.siteSystem, match.applies(toVault: vaultId), let id = match.siteId { return id }
        return client.flatMap { clientSites[$0] }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// What the Site row on New job holds once something is chosen (Plan MD §2–§4), and what starting
/// the job then does with it. Pure.
struct NewJobSitePick: Equatable {

    enum Kind: String, Equatable {
        case scheduledJob = "scheduled_job"
        case documentedSite = "documented_site"
        case recentSite = "recent_site"
        case newSite = "new_site"
    }

    var kind: Kind
    var upcomingJobId: String?
    var jobReference: String?
    /// The row's name for the choice when it is no documented site.
    var title: String
    var site: JobSite?
    var siteDocumentId: String?
    var siteLabel: String?
    var unitCount: Int
    /// The documented site came with the scheduled job rather than being chosen now.
    var documentFromJob: Bool
    var client: SiteSystemDocument.ExternalRef?
    /// Remember the documented site for the job's Workiz client (Plan MD §4). On unless turned off.
    var remembersClient: Bool = true

    init(_ choice: NewJobSiteChoice) {
        switch choice.source {
        case .scheduledJob: kind = .scheduledJob
        case .documentedSite: kind = .documentedSite
        case .recentSite: kind = .recentSite
        }
        upcomingJobId = choice.upcomingJobId
        jobReference = choice.jobReference
        title = choice.title
        site = choice.site
        siteDocumentId = choice.siteDocumentId
        siteLabel = choice.siteDocumentId == nil ? nil : choice.title
        unitCount = choice.unitCount
        documentFromJob = choice.documentFromJob
        client = choice.client
    }

    /// A site typed in: customer, address and contact. Nil when every field is empty.
    static func newSite(_ site: JobSite) -> NewJobSitePick? {
        guard !site.isEmpty, let headline = site.headline ?? site.contact else { return nil }
        var pick = NewJobSitePick(NewJobSiteChoice(id: "new", source: .recentSite, title: headline, site: site))
        pick.kind = .newSite
        return pick
    }

    /// Choose a documented site for a scheduled job that came with none.
    mutating func attach(_ document: NewJobSiteChoice) {
        guard canAttachDocument, let id = document.siteDocumentId else { return }
        siteDocumentId = id
        siteLabel = document.title
        unitCount = document.unitCount
    }

    /// Take the attached documented site off a scheduled job again.
    mutating func detachDocument() {
        guard kind == .scheduledJob, !documentFromJob else { return }
        siteDocumentId = nil
        siteLabel = nil
        unitCount = 0
    }

    /// "Smith Street plant room · 4 units" — what the Site row reads.
    var rowLabel: String {
        var parts = [siteLabel ?? title]
        if siteDocumentId != nil {
            parts.append(unitCount == 1 ? String(localized: "1 unit") : String(localized: "\(unitCount) units"))
        }
        return parts.joined(separator: " · ")
    }

    /// A scheduled job with no documented site, in a vault that has some, can be given one.
    var canAttachDocument: Bool { kind == .scheduledJob && (siteDocumentId == nil || !documentFromJob) }

    /// Whether to offer "Remember this site for the client": a Workiz job, a documented site
    /// chosen for it now.
    var canRememberClient: Bool {
        kind == .scheduledJob && client?.system == "workiz" && siteDocumentId != nil && !documentFromJob
    }

    /// The client to remember the site for, when the technician left that on.
    var clientToRemember: SiteSystemDocument.ExternalRef? { canRememberClient && remembersClient ? client : nil }

    /// The customer and address to file the job under. A scheduled job brings its own.
    var siteToFill: JobSite? { kind == .scheduledJob ? nil : site }

    /// The documented site to match as chosen. One that came with the job is matched by the job's
    /// own evidence instead, so it keeps the basis it has.
    var documentToChoose: String? { documentFromJob ? nil : siteDocumentId }

    /// Whether anything is applied after the job starts.
    var appliesAfterStart: Bool { siteToFill != nil || documentToChoose != nil }
}
