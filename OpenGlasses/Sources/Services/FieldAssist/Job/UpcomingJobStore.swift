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
    static let entryCap = 100

    @Published private(set) var jobs: [UpcomingJob]

    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("upcoming-jobs.json")
        jobs = Self.ordered(Self.read(fileURL) ?? [])
        protectFile()
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
        jobs = []
        save()
    }

    // MARK: - Order

    /// Scheduled jobs first, soonest first; then unscheduled ones in the order they arrived.
    static func ordered(_ jobs: [UpcomingJob]) -> [UpcomingJob] {
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
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        protectFile()
    }

    /// Complete protection and no backup: customers' names and addresses, which belong on this
    /// phone and nowhere a backup would carry them.
    private func protectFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
