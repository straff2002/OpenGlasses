import Foundation

/// Native tool that runs a structured capture flow within an active Field Assist session (Plan U):
/// a typed, validated inspection/work-order template whose steps collect a reading, an enum choice,
/// a barcode, or a photo bound to a field — producing an audit-ready `CaptureRecord` rather than a
/// loose transcript. The current step/prompt is surfaced on the HUD; finishing queues the record
/// for sync (Plan T) and folds it into the session export (Plan F).
@MainActor
final class CaptureFlowTool: NativeTool {
    let name = "capture_flow"
    let description = """
    Run a structured, typed capture flow (inspection / work-order form) inside an active Field \
    Assist session. Actions: 'list' to see available flows, 'start' (flow_id, optional asset_id) to \
    begin, 'answer' (value) to record the current step's value, 'skip' to leave a field blank, \
    'back' to revisit the previous field, 'status' for progress, 'finish' to save the record, \
    'cancel' to discard. The runner validates each value (number ranges, enum options, required \
    fields) and re-prompts on a bad answer — pass the user's spoken value verbatim to 'answer'.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'list', 'start', 'answer', 'skip', 'back', 'status', 'finish', or 'cancel'."
            ],
            "flow_id": [
                "type": "string",
                "description": "On 'start': the flow id (e.g. 'asset_inspection_v1'). Use 'list' to discover ids."
            ],
            "asset_id": [
                "type": "string",
                "description": "On 'start' (optional): the asset/unit this record is for."
            ],
            "value": [
                "type": "string",
                "description": "On 'answer': the user's spoken value for the current step (a reading, an option word, a code, or a photo path)."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let service = CaptureFlowService.shared
        guard let action = (args["action"] as? String)?.lowercased() else {
            return "No action specified. Use 'list', 'start', 'answer', 'skip', 'back', 'status', 'finish', or 'cancel'."
        }

        switch action {
        case "list":
            let flows = service.availableFlows()
            return flows.isEmpty
                ? "No capture flows are available in the active vault."
                : "Available capture flows:\n" + flows.map { "• \($0)" }.joined(separator: "\n")

        case "start":
            guard let id = (args["flow_id"] as? String), !id.isEmpty else {
                return "Specify 'flow_id'. Use action 'list' to see available flows."
            }
            do { return try service.start(flowId: id, assetId: args["asset_id"] as? String) }
            catch { return "Could not start capture flow: \(error.localizedDescription)" }

        case "answer":
            guard let value = args["value"] as? String else {
                return "Provide 'value' — the user's answer for the current step."
            }
            return service.answer(value)

        case "skip":              return service.skip()
        case "back", "previous":  return service.back()
        case "status":            return service.status()
        case "finish", "complete": return service.finish()
        case "cancel":            return service.cancel()
        default:
            return "Unknown action '\(action)'. Use 'list', 'start', 'answer', 'skip', 'back', 'status', 'finish', or 'cancel'."
        }
    }
}
