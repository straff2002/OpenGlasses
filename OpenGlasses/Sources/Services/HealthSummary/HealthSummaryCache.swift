import Foundation

/// The last summary numbers the tool computed, for answering while the phone is locked.
///
/// Apple Health's store is unreadable while the phone is locked — which is exactly when a glasses
/// wearer asks "how did I sleep?". So each time the tool reads Health (and whenever the app comes
/// to the foreground or the phone is unlocked) it keeps the **derived numbers**, never the samples:
/// a heart-rate summary, a night's totals, a step comparison, each stamped with when it was read.
///
/// That is still health data on disk, so it is held the way the rest of the app holds sensitive
/// stores: `completeUntilFirstUserAuthentication` (readable while locked after the first unlock
/// since boot, which is the point), excluded from backup, dropped after 24 hours, and clearable
/// from Settings → Privacy → Health. Registered as `SensitiveStore.healthSummaryCache`.
struct HealthSummarySnapshot: Codable, Equatable {
    var heartRate: HeartRateSummary?
    var sleep: SleepNight?
    var steps: StepComparison?

    var isEmpty: Bool { heartRate == nil && sleep == nil && steps == nil }

    /// The newest `asOf` of any part, for the settings screen.
    var newest: Date? {
        [heartRate?.asOf, sleep?.asOf, steps?.asOf].compactMap { $0 }.max()
    }

    /// Fill in what `newer` has, keep what it doesn't.
    func merging(_ newer: HealthSummarySnapshot) -> HealthSummarySnapshot {
        HealthSummarySnapshot(heartRate: newer.heartRate ?? heartRate,
                              sleep: newer.sleep ?? sleep,
                              steps: newer.steps ?? steps)
    }

    /// The same snapshot with every part older than `ttl` removed.
    func dropping(olderThan ttl: TimeInterval, now: Date) -> HealthSummarySnapshot {
        func fresh(_ date: Date?) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age <= ttl
        }
        return HealthSummarySnapshot(heartRate: fresh(heartRate?.asOf) ? heartRate : nil,
                                     sleep: fresh(sleep?.asOf) ? sleep : nil,
                                     steps: fresh(steps?.asOf) ? steps : nil)
    }
}

final class HealthSummaryCache {

    static let ttl: TimeInterval = 24 * 3600

    let fileURL: URL

    /// `directory` is injected by tests; the app uses Application Support/HealthSummary.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthSummary", isDirectory: true)
        fileURL = base.appendingPathComponent("summary.json")
    }

    /// The cached parts still inside the TTL, or nil when nothing usable is held. An expired or
    /// unreadable file is removed rather than left behind.
    func load(now: Date = Date()) -> HealthSummarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let stored = try? decoder.decode(HealthSummarySnapshot.self, from: data) else {
            clear()
            return nil
        }
        let live = stored.dropping(olderThan: Self.ttl, now: now)
        if live.isEmpty { clear(); return nil }
        return live
    }

    /// Merge `snapshot` over what is held and write it back.
    func store(_ snapshot: HealthSummarySnapshot, now: Date = Date()) throws {
        guard !snapshot.isEmpty else { return }
        let merged = (load(now: now) ?? HealthSummarySnapshot()).merging(snapshot)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)

        let data = try encoder.encode(merged)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // An atomic write replaces the file, so the flag is set on the new one every time.
        var url = fileURL
        try url.setResourceValues(values)
    }

    /// Remove everything held. The settings screen's "Clear" and the feature switch call this.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var hasEntry: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
