import Foundation

/// "Build yourself a skill for that": starts, reports on, improves or stops an add-on the
/// assistant builds for the wearer (`AddOnAuthoringService`).
///
/// Declared only while building is allowed (`AddOnAuthoringAvailability`: Agent Mode on, not under
/// Medical Compliance or Local Only, add-ons on, the organisation allowing it); offline it is not
/// offered either (`OfflineToolPolicy`). Every action checks again when it runs. Starting returns
/// at once: the session runs on its own, asks before it tests anything, and ends on the phone's
/// add-on sheet, which is the only way anything it builds is installed.
struct BuildAddOnTool: NativeTool, ConditionallyOfferedTool {

    static let toolName = "build_addon"
    let name = "build_addon"

    /// The running app's service; nil in a registry built without one, which refuses every call.
    var service: @MainActor () -> AddOnAuthoringService? = { nil }
    var availability: @MainActor () -> AddOnAuthoringAvailability.Unavailable? = {
        AddOnAuthoringAvailability.unavailable(BuildAddOnTool.liveConditions())
    }

    @MainActor var isOfferedNow: Bool { availability() == nil && service() != nil }

    let description = """
        Build a new add-on (a small skill that looks something up from a free public web service) when \
        the wearer asks you to build yourself a skill for something no tool covers, for example tide \
        times at a beach. It searches for a keyless public API, drafts the add-on, asks the wearer \
        before testing it once, and then shows it on the phone for the wearer to review and approve. \
        It never installs anything silently: nothing is kept unless the wearer approves it on the \
        phone. Actions: start (goal, in the wearer's words), improve (addon name and what to change; \
        only add-ons you built), status, cancel. Starting returns at once; tell the wearer you've \
        started and that they'll be asked before the test.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "improve", "status", "cancel"],
                "description": "What to do",
            ],
            "goal": [
                "type": "string",
                "maxLength": 200,
                "description": "What the add-on should do, in the wearer's words (start, improve)",
            ],
            "addon": [
                "type": "string",
                "maxLength": 60,
                "description": "The name of the add-on to improve (improve only)",
            ],
        ],
        "required": ["action"],
    ]

    /// It records a draft and the day's session count on the phone; the research and the test
    /// happen later, inside the session, each behind its own gate.
    var executionSemantics: ToolExecutionSemantics { .local(.cooperative, timeout: .seconds(20)) }

    func execute(args: [String: Any]) async throws -> String {
        await perform(args)
    }

    @MainActor
    private func perform(_ args: [String: Any]) -> String {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        guard let service = service() else {
            return String(localized: "Building add-ons isn't available right now.")
        }
        if action == "status" { return service.status() }
        if action == "cancel" { return service.cancel() }
        if let reason = availability() { return AddOnAuthoringAvailability.message(reason) }
        let goal = (args["goal"] as? String) ?? ""
        switch action {
        case "start":
            return service.start(goal: goal).text
        case "improve":
            return service.improve(addOnNamed: (args["addon"] as? String) ?? "", goal: goal).text
        default:
            return String(localized: "Use start, improve, status or cancel.")
        }
    }

    /// The live conditions, from settings, Medical Compliance and the organisation's profile.
    @MainActor
    static func liveConditions() -> AddOnAuthoringAvailability.Conditions {
        AddOnAuthoringAvailability.Conditions(
            agentModeEnabled: Config.agentModeEnabled,
            hipaaMode: Config.hipaaMode,
            localOnly: MedicalEgressGuard.blocks(.addOnAuthoringDocs),
            addOnsEnabled: Config.addOnsEnabled,
            policy: AddOnLiveContext.policy(),
            organisationForbidsSelfBuilt: Config.organizationForbidsSelfBuiltAddOns)
    }
}
