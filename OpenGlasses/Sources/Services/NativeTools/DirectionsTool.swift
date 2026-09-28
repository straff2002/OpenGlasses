import Foundation
import UIKit

/// Opens the wearer's maps app with directions to a destination.
///
/// Which app is the wearer's choice, made once in Settings (`Config.preferredMapsApp`, Plan FO
/// P3c): Apple Maps, Google Maps or Waze. A spoken "in Google Maps" still wins for that one
/// request. When the chosen app is missing the hand-off falls back to Apple Maps and says so —
/// the same table (`MapsHandoff`) the Job tab and the car screen use, so there is one rule rather
/// than three.
struct DirectionsTool: NativeTool {
    let name = "get_directions"
    let description = "Get directions to a destination. Opens the user's chosen maps app (Apple Maps, Google Maps or Waze) with turn-by-turn navigation; a named app overrides the setting for this request. For \"take me there\" about the next Field Assist job, pass next_job instead of a destination."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "destination": [
                "type": "string",
                "description": "The destination address or place name. Omit when next_job is true."
            ],
            "mode": [
                "type": "string",
                "description": "Travel mode: 'driving', 'walking', or 'transit'. Defaults to driving."
            ],
            "app": [
                "type": "string",
                "description": "Only when the user names one: 'apple', 'google' or 'waze'. Omit to use their setting."
            ],
            "next_job": [
                "type": "boolean",
                "description": "True to navigate to the next upcoming Field Assist job's site address, as the office or technician gave it."
            ]
        ]
    ]

    func execute(args: [String: Any]) async throws -> String {
        var destination = (args["destination"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if destination.isEmpty, args["next_job"] as? Bool == true {
            let next = await MainActor.run { AppStateProvider.shared?.upcomingJobs.next }
            guard let next else { return "There is no upcoming job on this phone." }
            guard let address = next.destination else {
                return "\(next.title) has no address on file, so there is nowhere to navigate to. Add one on the Job tab."
            }
            destination = address
        }
        guard !destination.isEmpty else { return "No destination provided." }

        let mode = TravelMode(spoken: args["mode"] as? String)
        let requested = (args["app"] as? String).flatMap(MapsApp.init(spoken:))
        let target = destination
        let handoff = await MainActor.run { MapsLauncher.plan(destination: target, mode: mode, requested: requested) }
        guard let handoff else { return "Couldn't build directions for \(destination)." }
        await MainActor.run { MapsLauncher.open(handoff) }
        return handoff.spoken
    }
}
