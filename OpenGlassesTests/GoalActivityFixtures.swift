import Foundation
@testable import OpenGlasses

/// Shared values for the goal and activity-trail tests (Plan IW). Invented ids and titles only.
enum GoalActivityFixture {
    static let auckland = TimeZone(identifier: "Pacific/Auckland")!

    static func calendar(_ zone: TimeZone = auckland) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// A moment in October 2026 in the given zone (Auckland is on daylight time, UTC+13).
    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0,
                     zone: TimeZone = auckland, month: Int = 10) -> Date {
        calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day,
                                                 hour: hour, minute: minute))!
    }

    /// Monday 19 October 2026, 10:00 in Auckland.
    static let now = date(19, 10)

    /// A stable, readable UUID: `uuid(7)` is 00000000-0000-0000-0000-000000000007.
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func step(_ n: Int, _ title: String, state: GoalStepState = .open, dueAt: Date? = nil,
                     action: StepAction? = nil) -> GoalStep {
        GoalStep(id: uuid(100 + n), title: title, state: state, dueAt: dueAt, suggestedAction: action)
    }

    static func goal(_ steps: [GoalStep], state: GoalState = .active, dueAt: Date? = nil,
                     checkIn: CheckInCadence = .none, title: String = "Clear the garage") -> Goal {
        Goal(id: uuid(1), title: title, createdAt: date(18, 9), dueAt: dueAt, state: state,
             checkIn: checkIn, steps: steps, source: .wearer)
    }

    static func entry(_ n: Int, at: Date, title: String, kind: ActivityKind = .action,
                      tool: String? = nil, outcome: ActivityOutcome = .done,
                      authorisation: ActivityAuthorisation = .asked,
                      goalID: UUID? = nil, stepID: UUID? = nil) -> ActivityEntry {
        ActivityEntry(id: uuid(500 + n), at: at, kind: kind, title: title, tool: tool,
                      goalID: goalID, stepID: stepID, authorisation: authorisation,
                      origin: .wearer, outcome: outcome)
    }
}

// MARK: - P1 fixtures

/// A recorder that keeps what it is told, for the feeder tests.
@MainActor
final class FakeActivityRecorder: ActivityRecording {
    private(set) var entries: [ActivityEntry] = []
    private(set) var settled: [(operationID: String, outcome: ActivityOutcome)] = []

    func record(_ entry: ActivityEntry) { entries.append(entry) }

    func settle(operationID: String, outcome: ActivityOutcome) {
        settled.append((operationID, outcome))
        guard let index = entries.lastIndex(where: { $0.refs.contains(.operation(operationID)) }) else { return }
        entries[index].outcome = outcome
    }

    /// Plan LE P1: answers every held entry still waiting under the key, as the store does.
    func resolveHold(key: String, resolution: ActivityResolution, at date: Date) {
        for index in entries.indices
        where entries[index].kind == .held && entries[index].holdKey == key && entries[index].isAwaitingWearer(at: date) {
            entries[index] = entries[index].resolved(resolution, at: date)
        }
    }
}

extension GoalActivityFixture {
    /// A fresh directory under the temporary folder; the caller removes it.
    static func workspace(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

