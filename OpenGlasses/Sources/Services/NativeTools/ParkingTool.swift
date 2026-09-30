import CoreLocation
import Foundation

/// Plan GH — "where did I park?": save the spot by voice or from a sign photo, recall it with
/// level, space, distance and direction, walk back to it, forget it.
///
/// Everything stays on the phone: the spot and its photo live in `ParkingStore`, the sign is read by
/// on-device OCR, and directions are MapKit's walking route. Not agentic, so no Agent Mode gate.
@MainActor
final class ParkingTool: NativeTool {
    let name = "parking"
    let description = """
        Remember and find where the wearer parked their car. Actions: 'save' — store the spot at \
        the current location, with level, space and zone taken from 'details' (the wearer's own \
        words, e.g. "level 2 space 41", "P3 bay B12", "green zone", "near the lifts"); 'photo' — \
        read a parking sign or bay marker through the glasses camera and save the spot with the \
        photo (for "remember this" at a pillar); 'update' — correct the level/space/zone of the \
        saved spot from 'details'; 'where' — say where the car is (level, space, distance, \
        direction, how long ago) and show it on the glasses; 'directions' — walking directions \
        back to the car; 'clear' — forget the spot; 'history' — recent spots, when history is on. \
        Use for "I parked on level 2", "remember where I parked", "where did I park?", "where's \
        my car?", "take me back to my car". Nothing leaves the phone.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'save', 'photo', 'update', 'where' (default), 'directions', 'clear' or 'history'."
            ],
            "details": [
                "type": "string",
                "description": "For 'save'/'photo'/'update': what the wearer said about the spot, verbatim — e.g. 'level 2, space 41'."
            ],
            "level": ["type": "string", "description": "Optional explicit level/floor, e.g. '2', 'B1', 'G'."],
            "space": ["type": "string", "description": "Optional explicit space/bay, e.g. '41', 'B12'."],
            "zone": ["type": "string", "description": "Optional explicit zone/row/colour, e.g. 'Green', 'Row G'."]
        ],
        "required": [] as [String]
    ]

    /// Everything device-facing, so the tool runs headless against a temp-directory store.
    struct Seams {
        var store: @MainActor () -> ParkingStore = { ParkingStore.shared }
        /// A current fix, waiting briefly for one. Nil indoors or without permission.
        var currentLocation: () async -> CLLocation? = { nil }
        var photoFlow: () -> ParkingPhotoFlow? = { nil }
        var startDirections: ((CLLocationCoordinate2D, String) async throws -> String)?
        var showPin: ((String) -> Void)?
        var metric: () -> Bool = { ParkingTool.prefersMetric }
        var now: () -> Date = Date.init
        var keepHistory: () -> Bool = { Config.parkingKeepHistory }
        /// Knowledge-graph ingest. Only called while history is on — with history off the wearer
        /// has asked for the spot to be forgotten when it is replaced, and a copy in the graph
        /// would be a history by the back door.
        var ingest: ((String) -> Void)?
    }

    private let seams: Seams

    init(seams: Seams) {
        self.seams = seams
    }

    /// The production wiring: location from `LocationService`, everything else through
    /// `AppStateProvider` at execution time, the way `navigate` and `pin_frame` resolve theirs.
    convenience init(locationService: LocationService) {
        self.init(seams: Seams(
            currentLocation: { [weak locationService] in await locationService?.awaitFix(timeout: 3) },
            photoFlow: { AppStateProvider.shared?.parkingPhotoFlow },
            startDirections: { coordinate, label in
                guard let appState = AppStateProvider.shared else { throw NavigationError.noRoute }
                return try await appState.walkingRoute.start(to: coordinate, label: label)
            },
            showPin: { line in AppStateProvider.shared?.glassesDisplay.showNavigation(line) },
            ingest: { text in BrainStore.shared.ingest(text: text, sourceRef: "parking", sourceKind: "place") }
        ))
    }

    nonisolated static var prefersMetric: Bool {
        switch Config.navigationUnits {
        case .metric: return true
        case .imperial: return false
        case .auto: return Locale.current.measurementSystem == .metric
        }
    }

    func execute(args: [String: Any]) async throws -> String {
        let details = (args["details"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultAction = (details?.isEmpty == false) ? "save" : "where"
        let action = (args["action"] as? String ?? defaultAction).lowercased()

        switch action {
        case "save", "remember", "set":
            return await save(fields: fields(from: args, details: details))
        case "photo", "sign", "scan", "capture":
            return await savePhoto(fields: fields(from: args, details: details))
        case "update", "correct", "fix":
            return update(fields: fields(from: args, details: details))
        case "directions", "navigate", "guide", "take_me":
            return await directions()
        case "clear", "forget", "delete", "found":
            return clear()
        case "history", "list":
            return history()
        default:
            return await recall()
        }
    }

    // MARK: - Actions

    private func save(fields: ParkingFields) async -> String {
        let now = seams.now()
        let location = await seams.currentLocation()
        var spot = ParkingSpot(coordinate: location?.coordinate,
                               horizontalAccuracy: location?.horizontalAccuracy,
                               locationAt: location?.timestamp,
                               savedAt: now, capture: .voice)
        spot.merge(fields)
        let saved = seams.store().saveManual(spot, now: now)
        feedGraph(saved)
        return saveReply(saved, hadFix: location != nil, photoNote: nil)
    }

    private func savePhoto(fields spoken: ParkingFields) async -> String {
        let now = seams.now()
        let location = await seams.currentLocation()
        var spot = ParkingSpot(coordinate: location?.coordinate,
                               horizontalAccuracy: location?.horizontalAccuracy,
                               locationAt: location?.timestamp,
                               savedAt: now, capture: .photo)

        guard let flow = seams.photoFlow(), flow.hasCamera else {
            spot.capture = .voice
            spot.merge(spoken)
            let saved = seams.store().saveManual(spot, now: now)
            return saveReply(saved, hadFix: location != nil,
                             photoNote: "The glasses camera isn't available, so there's no photo — you can add one from the Parking card on the phone.")
        }

        switch await flow.captureFromGlasses() {
        case .read(let reading, let jpeg):
            spot.merge(reading.fields)
            spot.merge(spoken)   // what the wearer said beats what the sign seemed to say
            let saved = seams.store().saveManual(spot, photo: jpeg, now: now)
            feedGraph(saved)
            if reading.isEmpty, spoken.isEmpty {
                return saveReply(saved, hadFix: location != nil,
                                 photoNote: "I kept the photo but couldn't read a level or space from the sign.")
            }
            if reading.needsConfirmation, spoken.level == nil, spoken.space == nil {
                let read = ParkingRecallPhraser.detailPhrase(saved)?
                    .replacingOccurrences(of: "on ", with: "", options: .anchored) ?? "the sign"
                return "Saved with the photo. I read \(read) — is that right? If not, tell me the level and space."
                    + (location == nil ? " I couldn't get a GPS fix here." : "")
            }
            return saveReply(saved, hadFix: location != nil, photoNote: "The photo is kept with it.")
        case .unavailable(let reason):
            spot.capture = .voice
            spot.merge(spoken)
            let saved = seams.store().saveManual(spot, now: now)
            let why = reason == .filterUnavailable || reason == .filterNotWired
                ? "Face blur is on and couldn't run just now, so I saved the spot without the photo."
                : "I couldn't get a picture of the sign, so I saved the spot without it."
            return saveReply(saved, hadFix: location != nil, photoNote: why)
        case .unreadable:
            spot.capture = .voice
            spot.merge(spoken)
            let saved = seams.store().saveManual(spot, now: now)
            return saveReply(saved, hadFix: location != nil,
                             photoNote: "The picture couldn't be kept, so I saved the spot without it.")
        }
    }

    private func update(fields: ParkingFields) -> String {
        guard !fields.isEmpty else { return "Tell me the level or space to change it to." }
        guard let spot = seams.store().updateActive(fields) else {
            return "I don't have a parking spot saved to correct. Say where you parked and I'll save it."
        }
        let details = ParkingRecallPhraser.detailPhrase(spot) ?? "your spot"
        return "Updated — \(details)."
    }

    private func recall() async -> String {
        guard let spot = seams.store().active else {
            return "I don't have a parking spot saved. Say \u{201C}I parked on level 2, space 41\u{201D} and I'll remember it."
        }
        let current = await seams.currentLocation()?.coordinate
        seams.showPin?(ParkingRecallPhraser.hudLine(spot, from: current, metric: seams.metric()))
        return ParkingRecallPhraser.spoken(spot, from: current, now: seams.now(), metric: seams.metric())
    }

    private func directions() async -> String {
        guard let spot = seams.store().active else {
            return "I don't have a parking spot saved, so I can't take you back to it."
        }
        guard let coordinate = spot.coordinate else {
            let details = ParkingRecallPhraser.detailPhrase(spot).map { "You parked \($0), but I" } ?? "I"
            return "\(details) don't have a map position for the car, so I can't give walking directions."
        }
        guard let startDirections = seams.startDirections else {
            return "Walking directions aren't available right now."
        }
        do {
            return try await startDirections(coordinate, "your car")
        } catch {
            return error.localizedDescription
        }
    }

    private func clear() -> String {
        let store = seams.store()
        guard store.active != nil else { return "There's no parking spot saved." }
        store.clear()
        return "Okay, I've forgotten where you parked."
    }

    private func history() -> String {
        guard seams.keepHistory() else {
            return "Parking history is off, so only the current spot is kept. It can be turned on in Settings under Parking."
        }
        let store = seams.store()
        let spots = ([store.active].compactMap { $0 } + store.history).prefix(ParkingStore.historyCap)
        guard !spots.isEmpty else { return "No parking spots saved yet." }
        let now = seams.now()
        let lines = spots.map { spot -> String in
            let when = ParkingRecallPhraser.agePhrase(now.timeIntervalSince(spot.savedAt))
            let what = ParkingRecallPhraser.detailPhrase(spot) ?? (spot.coordinate != nil ? "a map position" : "no details")
            return "\(when): \(what)"
        }
        return "Recent parking spots — " + lines.joined(separator: "; ") + "."
    }

    // MARK: - Helpers

    /// Parsed details, with any explicit field arguments taking precedence.
    private func fields(from args: [String: Any], details: String?) -> ParkingFields {
        var fields = details.map(ParkingUtteranceParser.parse) ?? ParkingFields()
        if let level = nonEmpty(args["level"]) { fields.level = level }
        if let space = nonEmpty(args["space"]) { fields.space = space.uppercased() }
        if let zone = nonEmpty(args["zone"]) { fields.zone = zone }
        return fields
    }

    private func nonEmpty(_ value: Any?) -> String? {
        if let number = value as? Int { return "\(number)" }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private func saveReply(_ spot: ParkingSpot, hadFix: Bool, photoNote: String?) -> String {
        var parts: [String] = []
        if let details = ParkingRecallPhraser.detailPhrase(spot) {
            parts.append("Saved — you parked \(details).")
        } else {
            parts.append("Saved where you parked.")
        }
        if !hadFix {
            parts.append(spot.coordinate != nil
                ? "I couldn't get a fresh GPS fix, so I kept the position from your drive."
                : "I couldn't get a GPS fix here, so I'll remember the details but can't point you back on a map.")
        }
        if let note = spot.note, !note.isEmpty, spot.level == nil, spot.space == nil {
            parts.append("Noted: \(note).")
        }
        if let photoNote { parts.append(photoNote) }
        return parts.joined(separator: " ")
    }

    private func feedGraph(_ spot: ParkingSpot) {
        guard seams.keepHistory(), let details = ParkingRecallPhraser.detailPhrase(spot) else { return }
        seams.ingest?("I parked \(details)")
    }
}
