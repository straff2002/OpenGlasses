import Foundation

/// Compatibility tool name for the shared deterministic My Day briefing.
/// Selection and time math happen in `MyDayComposer`; no model discovers or ranks commitments.
struct DailyBriefingTool: NativeTool {
    let name = "daily_briefing"
    let description = "Get My Day: a concise, authoritative briefing of today's calendar, due reminders, and weather."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    private let myDayService: MyDayService

    init(myDayService: MyDayService) {
        self.myDayService = myDayService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.myDayEnabled else {
            return "My Day is off. Turn it on in Settings under Works with your iPhone."
        }
        return await myDayService.spokenBriefing()
    }
}
