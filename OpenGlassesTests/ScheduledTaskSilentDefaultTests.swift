import XCTest
import UserNotifications
@testable import OpenGlasses

/// New scheduled tasks start silent: their result arrives as one silent notification rather than
/// being spoken through the phone. A task already saved keeps its own setting.
@MainActor
final class ScheduledTaskSilentDefaultTests: XCTestCase {
    private var savedTasks: Data?

    override func setUp() {
        super.setUp()
        savedTasks = UserDefaults.standard.data(forKey: "agentScheduledTasks")
        AgentScheduler.saveTasks([])
    }

    override func tearDown() {
        UserDefaults.standard.set(savedTasks, forKey: "agentScheduledTasks")
        super.tearDown()
    }

    func testTheDefaultIsSilent() {
        XCTAssertFalse(AgentScheduler.ScheduledTask.speakResultDefault)
    }

    func testBuiltInTasksAreSilent() {
        for task in AgentScheduler.ScheduledTask.defaults {
            XCTAssertFalse(task.speakResult, task.id)
        }
    }

    func testEveryTemplateTaskIsSilent() {
        let tasks = ShortcutTemplate.allTemplates.compactMap(\.scheduledTask)
        XCTAssertFalse(tasks.isEmpty)
        for task in tasks {
            XCTAssertFalse(task.speakResult, task.id)
        }
    }

    func testManageScheduleCreatesSilentTasksUnlessAsked() async throws {
        _ = try await AgentScheduleTool().execute(args: [
            "action": "create", "task_name": "Train delays", "task_prompt": "Check the trains"])
        XCTAssertEqual(AgentScheduler.savedTasks().last?.speakResult, false)

        _ = try await AgentScheduleTool().execute(args: [
            "action": "create", "task_name": "Say it", "task_prompt": "Check the trains",
            "speak_result": true])
        XCTAssertEqual(AgentScheduler.savedTasks().last?.speakResult, true)
    }

    /// A task saved on a device keeps its own setting: nothing rewrites it to the new default.
    func testASavedSpokenTaskStaysSpoken() {
        let json = #"[{"id":"mine","name":"Mine","prompt":"P","intervalMinutes":15,"enabled":true,"speakResult":true}]"#
        UserDefaults.standard.set(Data(json.utf8), forKey: "agentScheduledTasks")
        XCTAssertEqual(AgentScheduler.savedTasks().first?.speakResult, true)
    }

    // MARK: - A silent result still leaves a notification

    func testASilentResultIsOneSoundlessNotificationPerTask() {
        let first = ScheduledTaskNotification.request(taskID: "trains", taskName: "Train delays",
                                                      result: "The 8:05 is cancelled.")
        XCTAssertNil(first.content.sound)
        XCTAssertEqual(first.content.title, "Train delays")
        XCTAssertEqual(first.content.body, "The 8:05 is cancelled.")
        XCTAssertNil(first.trigger)

        let next = ScheduledTaskNotification.request(taskID: "trains", taskName: "Train delays", result: "On time.")
        XCTAssertEqual(first.identifier, next.identifier, "a task's next result replaces its last one")
        let other = ScheduledTaskNotification.request(taskID: "weather", taskName: "Weather", result: "Rain.")
        XCTAssertNotEqual(first.identifier, other.identifier)
    }

    /// A goal's scheduled check is a new task too, and takes the silent default.
    func testGoalScheduledChecksAskForNoSpeech() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Goals/StepActionRun.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("\"speak_result\": .flag(true)"))
    }
}
