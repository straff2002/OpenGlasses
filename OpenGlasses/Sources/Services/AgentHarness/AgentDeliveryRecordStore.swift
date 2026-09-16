import Foundation

/// The crash window (Plan FE P4): what survives a relaunch about results already read out.
///
/// The gap this covers is narrow and real. The summary plays, the process goes away — a crash, a
/// jetsam kill, the wearer force-quitting — and the acknowledgement either never went out or went
/// out and was never confirmed. On the next launch the app knows nothing, so it either says
/// nothing (and the wearer never learns a result was waiting) or re-reads it (and claims a
/// delivery it cannot vouch for). Neither is honest, so the record persists instead.
///
/// **Minimal by design.** Run id, revision, state, ack state, timestamp. No summary, no prompt, no
/// file list, no endpoint words — the retained *result* for replay lives in memory and is gone
/// after a relaunch, which is why the reloaded record can only ever say "I may have already read
/// you that result", never read it again. Persisting the words to close that gap would mean
/// writing the agent's report of the wearer's work to disk for the sake of a rare edge, and that
/// trade is not worth making.
///
/// Small enough for preferences: a handful of fixed-shape records, bounded to `limit`.
@MainActor
final class AgentDeliveryRecordStore {
    static let shared = AgentDeliveryRecordStore()

    /// How many runs' records are kept. A wearer does not dispatch a hundred agent runs between
    /// relaunches, and an unbounded list in preferences is a slow leak.
    static let limit = 8

    private let key: String
    private let store: UserDefaults
    private(set) var records: [AgentResultDelivery] = []

    init(key: String = "agentResultDeliveries", store: UserDefaults = .standard) {
        self.key = key
        self.store = store
        records = Self.decode(store.data(forKey: key))
    }

    /// Everything known about a run, newest revision last.
    func records(forRun runID: String) -> [AgentResultDelivery] {
        records.filter { $0.runID == runID }.sorted { $0.resultRevision < $1.resultRevision }
    }

    /// The latest record for a run, if any.
    func latest(forRun runID: String) -> AgentResultDelivery? { records(forRun: runID).last }

    /// The most recently touched record overall — what a launch asks for when the wearer says
    /// "status" and there is no active run.
    var mostRecent: AgentResultDelivery? { records.max { $0.at < $1.at } }

    /// Write one record, replacing any earlier record for the same `(run, revision)`.
    func save(_ delivery: AgentResultDelivery) {
        records.removeAll { $0.identity == delivery.identity }
        records.append(delivery)
        // Trim by run, not by record: dropping revision 1 of a run while keeping revision 0 would
        // leave the store claiming an older result was the last thing said.
        let runsNewestFirst = Dictionary(grouping: records, by: \.runID)
            .map { (runID: $0.key, at: $0.value.map(\.at).max() ?? .distantPast) }
            .sorted { $0.at > $1.at }
        let keep = Set(runsNewestFirst.prefix(Self.limit).map(\.runID))
        records.removeAll { !keep.contains($0.runID) }
        persist()
    }

    /// Forget everything. Used by the privacy erasure path and by tests.
    func clear() {
        records = []
        store.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(records) else {
            PrivacyLog.agent(.session, .deliveryRecordWriteFailed, count: records.count)
            return
        }
        store.set(data, forKey: key)
    }

    private static func decode(_ data: Data?) -> [AgentResultDelivery] {
        guard let data else { return [] }
        guard var decoded = try? decoder.decode([AgentResultDelivery].self, from: data) else {
            // An unreadable store is treated as empty rather than fatal: the only thing lost is
            // the ability to hedge about one result, and refusing to launch over it would be a
            // far worse trade than the hedge is worth.
            PrivacyLog.agent(.session, .deliveryRecordReadFailed)
            return []
        }
        // Everything read back here happened in a previous process. Mark it, so nothing downstream
        // can confuse a record we watched complete with one we found lying on disk.
        for index in decoded.indices { decoded[index].reloaded = true }
        return decoded
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
