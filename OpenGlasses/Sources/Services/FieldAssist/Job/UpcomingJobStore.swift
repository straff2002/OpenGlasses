import Foundation

/// Where the jobs ahead live (Plan FO §7, P3c).
///
/// One JSON file in Application Support beside the delivery queue, loaded at construction and
/// written on every change. Registered in `DataStoreRegistry` as `upcomingJobs`: it holds customer
/// names, site addresses and contacts, so it is protected and excluded from backup rather than
/// left to the container's default — the same posture the queue beside it takes, and for the same
/// reason a restored copy would be wrong: it would offer jobs this phone was never given.
///
/// **Receiving, never sending.** Nothing here leaves the device; a job file arrives, it is never
/// emailed out.
@MainActor
final class UpcomingJobStore: ObservableObject {

    /// How many jobs ahead a phone holds. A technician's week is a few dozen; a store that kept
    /// growing would be an office system that happens to live on a phone.
    nonisolated static let entryCap = 100

    /// The protection class this store's files are written with and re-stamped to. First-unlock,
    /// not `.complete`: the store is written from voice turns that run with the phone locked in a
    /// pocket (the app keeps the `audio` background mode), and a `.complete` file refuses those
    /// writes — and its read, so a store first opened while locked would start empty.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    @Published private(set) var jobs: [UpcomingJob]

    @Published private(set) var workizLastPull: Date?
    @Published private(set) var workizNotice: String?
    private var workizStampURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("workiz-pull.json") }
    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("upcoming-jobs.json")
        jobs = Self.ordered(Self.read(fileURL) ?? [])
        protectFile()
        if let data = try? Data(contentsOf: workizStampURL),
           let stamp = try? JSONDecoder().decode(WorkizPull.self, from: data) {
            workizLastPull = stamp.date; workizNotice = stamp.notice
        }
    }
    private struct WorkizPull: Codable { let date: Date; let notice: String? }
    func removeWorkizJobs() {
        jobs.removeAll { $0.provenance?.connector == "workiz" }; save()
        workizLastPull = nil; workizNotice = nil
        try? FileManager.default.removeItem(at: workizStampURL)
    }
    func reconcileWorkiz(_ incoming: [UpcomingJob], at date: Date, notice: String) {
        // Only the ahead store changes. A started session has already copied its snapshot.
        let others = jobs.filter { $0.provenance?.connector != "workiz" }
        // A Workiz job the technician updated from an office job file keeps its "workiz:" id but
        // takes the file's provenance, so it is one of `others` now, and the pull brings the same
        // id back. The updated copy stays and the pulled one is dropped: two jobs with one id are
        // two List rows with one identity, which UIKit asserts on (the build 664 crash).
        let kept = Set(others.map(\.id))
        var seen = Set<String>()
        let pulled = incoming.filter { !kept.contains($0.id) && seen.insert($0.id).inserted }
        let space = max(0, Self.entryCap - others.count)
        jobs = Self.ordered(others + pulled.prefix(space)); save()
        workizLastPull = date; workizNotice = notice.isEmpty ? nil : notice
        if let data = try? JSONEncoder().encode(WorkizPull(date: date, notice: workizNotice)) {
            try? data.write(to: workizStampURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = workizStampURL; try? url.setResourceValues(values)
        }
    }

    // MARK: - Reading

    func job(id: String) -> UpcomingJob? { jobs.first { $0.id == id } }

    /// The job "next job" means: the first in schedule order.
    var next: UpcomingJob? { jobs.first }

    /// Every job ahead filed under this number, compared exactly as the number was given — the
    /// same rule the intake follows, so "1007" and "1007A" are different jobs.
    func jobs(reference: String) -> [UpcomingJob] {
        guard let wanted = JobIntakeState.cleaned(reference) else { return [] }
        return jobs.filter { $0.jobReference == wanted }
    }

    // MARK: - Mutations

    /// Add a job ahead. The oldest unscheduled ones make room when the cap is reached — a job with
    /// a time on it is never the one pushed out.
    func add(_ job: UpcomingJob) {
        var all = jobs.filter { $0.id != job.id } + [job]
        while all.count > Self.entryCap {
            let victim = all.filter { $0.scheduledFor == nil }.min { $0.createdAt < $1.createdAt }
                ?? all.min { $0.createdAt < $1.createdAt }
            guard let victim else { break }
            all.removeAll { $0.id == victim.id }
        }
        jobs = Self.ordered(all)
        save()
    }

    /// Replace a job in place, keeping its identity and when it was first added.
    func update(_ job: UpcomingJob, at date: Date = Date()) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var updated = job
        updated.updatedAt = date
        var all = jobs
        all[index] = updated
        jobs = Self.ordered(all)
        save()
    }

    /// Keep the brief a job was last given.
    func saveBrief(_ brief: JobBrief, jobId: String) {
        guard var job = job(id: jobId) else { return }
        job.brief = brief
        update(job)
    }

    /// Keep the site system the brief matched the job to (Plan HV), or forget a stale one.
    func saveSiteSystem(_ match: SiteSystemMatch?, jobId: String) {
        guard var job = job(id: jobId), job.siteSystem != match else { return }
        job.siteSystem = match
        update(job)
    }

    /// Take a job off the list — started on site, or no longer wanted.
    @discardableResult
    func remove(id: String) -> UpcomingJob? {
        guard let job = job(id: id) else { return nil }
        jobs.removeAll { $0.id == id }
        save()
        return job
    }

    /// Everything, for a wipe — what the registry's "delete all" column names.
    func removeAll() {
        removeWorkizJobs()
        jobs = []
        save()
    }

    // MARK: - Order

    /// Scheduled jobs first, soonest first; then unscheduled ones in the order they arrived.
    nonisolated static func ordered(_ jobs: [UpcomingJob]) -> [UpcomingJob] {
        jobs.sorted { lhs, rhs in
            switch (lhs.scheduledFor, rhs.scheduledFor) {
            case let (l?, r?): return l == r ? lhs.createdAt < rhs.createdAt : l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.createdAt < rhs.createdAt
            }
        }
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> [UpcomingJob]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([UpcomingJob].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        protectFile()
    }

    /// First-unlock protection and no backup: customers' names and addresses, which belong on this
    /// phone and nowhere a backup would carry them.
    private func protectFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: Self.fileProtection], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
