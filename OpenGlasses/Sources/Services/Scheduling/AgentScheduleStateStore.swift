import Foundation

/// Plan LM P3 / Plan DZ PR6 — `AgentScheduler`'s store for the scheduled tasks' execution state, kept apart from their
/// definitions (which stay in the `agentScheduledTasks` preference, so every create, edit and
/// delete flow and an older build read them exactly as before).
///
/// One JSON file in Application Support, replaced atomically on every write, at the platform's
/// default file protection so a background wake after the first unlock can read it. Nothing in it
/// is the wearer's words: task ids, dates, counts and fixed reason tokens. A file that cannot be
/// read (locked, damaged) is never written over: `JSONStore` backs a damaged one up first, and an
/// unreadable one leaves the store read-only until the next launch.
@MainActor
final class AgentScheduleStateStore {
    static let shared = AgentScheduleStateStore()

    private(set) var states: [String: ScheduledTaskState]
    private let url: URL
    private var writable = true

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let base = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSchedule", isDirectory: true)
        url = base.appendingPathComponent("state.json")
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        switch JSONStore.loadArray(ScheduledTaskState.self, at: url, name: "agent_schedule_state") {
        case .loaded(let values), .recovered(let values, _):
            states = Dictionary(values.map { ($0.taskID, $0) }, uniquingKeysWith: { _, last in last })
        case .corrupt:
            // Backed up by `JSONStore`; start fresh, and the next run's state replaces it.
            states = [:]
        case .unreadable:
            // The file may be fine (protected while locked): never write over it this launch.
            states = [:]
            writable = false
        case .absent:
            states = [:]
        }
    }

    func state(for taskID: String) -> ScheduledTaskState? { states[taskID] }

    func update(_ state: ScheduledTaskState) {
        states[state.taskID] = state
        save()
    }

    /// Drop the state of tasks that no longer exist, so a deleted task leaves nothing behind.
    func prune(keeping taskIDs: Set<String>) {
        let kept = states.filter { taskIDs.contains($0.key) }
        guard kept.count != states.count else { return }
        states = kept
        save()
    }

    private func save() {
        guard writable else { return }
        let ordered = states.values.sorted { $0.taskID < $1.taskID }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
