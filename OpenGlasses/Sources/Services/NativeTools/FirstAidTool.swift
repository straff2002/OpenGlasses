import Foundation

/// `first_aid` — hands-free first-aid coaching (First-Aid / Emergency Assist). Walks the user through a
/// structured protocol (CPR/AED, choking, bleeding, recovery, trauma) with spoken steps + a CPR
/// metronome, and finds the nearest defibrillator. **Advisory only — not a medical device.**
@MainActor
struct FirstAidTool: NativeTool {
    let name = "first_aid"

    let description = """
    Hands-free first-aid coaching for an emergency. Speaks step-by-step guidance and paces CPR. \
    Use when the user says things like "start CPR", "someone is choking", "they're bleeding", \
    "first aid", or asks for the nearest defibrillator/AED. Use action=triage to assess a casualty \
    from the glasses camera ("what's wrong with them?", "assess this person") for a structured, advisory \
    triage. Advisory only — it always reminds the user to call emergency services first and is not a \
    substitute for professional care.
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["start", "next", "back", "aed", "triage", "stop"],
                    "description": "start a protocol, advance, go back, find the nearest AED, triage a casualty from the camera, or stop."
                ],
                "protocol": [
                    "type": "string",
                    "enum": FirstAidProtocol.ids,
                    "description": "Which protocol to start (only for action=start). Defaults to cpr."
                ],
                "note": [
                    "type": "string",
                    "description": "Optional context for action=triage (e.g. what happened)."
                ]
            ],
            "required": ["action"]
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let service = FirstAidAssistService.shared
        switch (args["action"] as? String ?? "").lowercased() {
        case "start":
            let protocolId = (args["protocol"] as? String ?? "cpr").lowercased()
            guard service.start(protocolId: protocolId) else {
                return "Unknown protocol. Available: \(FirstAidProtocol.ids.joined(separator: ", "))."
            }
            return "Started \(protocolId) guidance. Reminder: this is advisory only — call emergency services. \(service.currentInstruction)"
        case "next":
            service.next()
            return service.currentInstruction
        case "back":
            service.back()
            return service.currentInstruction
        case "aed":
            return await service.findNearestAED()
        case "triage":
            let rawNote = (args["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (rawNote?.isEmpty == false) ? rawNote : nil
            do {
                let card = try await StructuredVisionService.shared.assessCurrentFrame(kind: "first_aid_triage", note: note)
                return "Triage (advisory — call emergency services):\n" + VisionAssessTool.summarize(card)
            } catch StructuredVisionError.noFrame {
                return "I couldn't get a camera view of the casualty. Point the glasses at them and try again — and call emergency services."
            } catch {
                return "I couldn't complete the triage: \(error.localizedDescription). Call emergency services if this is serious."
            }
        case "stop":
            service.stop()
            return "First-aid guidance stopped."
        default:
            return "Unknown action. Use start, next, back, aed, triage, or stop."
        }
    }
}
