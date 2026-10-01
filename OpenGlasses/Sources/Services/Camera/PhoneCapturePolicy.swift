import Foundation

/// How a camera tool gets its picture when no glasses camera can serve it (Plan GV).
///
/// There is deliberately no "silent phone capture" route for tools. A tool runs because somebody
/// spoke, or tapped a tile, and the phone is as likely to be in a pocket or flat on a bench as
/// pointing at anything — a headless back-camera shot then answers the question with a picture of
/// the lining. Silent capture survives only on the app's own non-tool paths, where it already
/// existed and is announced (see `CameraService.capturePhoto(allowPhoneFallback:)`).
enum PhoneCaptureRoute: Equatable, Sendable {
    /// Open the phone camera on screen: the user frames the shot and presses the shutter.
    case askOnPhone
    /// Never take a phone picture for this tool. The live-stream tools and identifying people.
    case glassesOnly
}

/// The per-tool table and the small rules around it. Pure, so the whole decision is tested
/// headless; `CameraService`, the router and `AppState` only ask it.
enum PhoneCapturePolicy {

    // MARK: - Timings

    /// How long a tool waits for the user to take the photo. Long enough to take the phone out,
    /// unlock it and frame a nameplate; short enough that an abandoned camera does not hold a turn.
    static let requestTimeout: TimeInterval = 90

    /// How long the camera view has to appear once asked for. The sheet is presented from the root
    /// view, and SwiftUI silently refuses a second sheet over one already open — this turns that
    /// silence into a sentence.
    static let presentationGrace: TimeInterval = 4

    /// How long a photo taken by a tile before its prompt stays available to the turn's tool.
    static let stagedPhotoLifetime: TimeInterval = 120

    // MARK: - The table

    /// Every camera-using tool, by registered name. A tool that reaches a still and is not here
    /// fails `CameraToolDescriptionTests`.
    static let routes: [String: PhoneCaptureRoute] = [
        // Ask on phone — the answer depends on what is framed.
        "capture_photo": .askOnPhone,
        "photo_log": .askOnPhone,
        "equipment_lookup": .askOnPhone,
        "manual_lookup": .askOnPhone,
        "safety_assessment": .askOnPhone,
        "vision_assess": .askOnPhone,
        "scan_document": .askOnPhone,
        "document_knowledge": .askOnPhone,
        "reading_assist": .askOnPhone,
        "look_closely": .askOnPhone,
        "smart_capture": .askOnPhone,
        "identify_medication": .askOnPhone,
        "identify_money": .askOnPhone,
        "identify_color": .askOnPhone,
        "scan_code": .askOnPhone,
        "qr_context": .askOnPhone,
        "scan_badge": .askOnPhone,
        "study": .askOnPhone,
        "teleprompter": .askOnPhone,
        "parking": .askOnPhone,
        // Glasses only — live-stream features, and identifying people.
        "face_recognition": .glassesOnly,
        "fitness_coach": .glassesOnly,
        "live_coach": .glassesOnly,
        "navigation_assist": .glassesOnly,
        "video_recording": .glassesOnly,
        "record_clip": .glassesOnly,
        "pin_frame": .glassesOnly,
    ]

    /// The route for a tool. A name the table does not know asks on the phone: the safe default is
    /// the user framing the shot, never a hidden one.
    static func route(forTool name: String) -> PhoneCaptureRoute {
        routes[name] ?? .askOnPhone
    }

    static var askOnPhoneTools: Set<String> { Set(routes.filter { $0.value == .askOnPhone }.keys) }
    static var glassesOnlyTools: Set<String> { Set(routes.filter { $0.value == .glassesOnly }.keys) }

    /// One short line shown over the phone camera, saying what to frame.
    static func framingHint(forTool name: String?) -> String {
        switch name {
        case "equipment_lookup", "manual_lookup":
            return String(localized: "Frame the fault code or nameplate, then take the photo.")
        case "safety_assessment":
            return String(localized: "Frame the work area, then take the photo.")
        case "photo_log":
            return String(localized: "Frame what to log for the job, then take the photo.")
        case "scan_document", "document_knowledge", "reading_assist", "study", "teleprompter":
            return String(localized: "Frame the text, then take the photo.")
        case "scan_code", "qr_context":
            return String(localized: "Frame the code, then take the photo.")
        case "identify_medication":
            return String(localized: "Frame the medication label, then take the photo.")
        case "scan_badge":
            return String(localized: "Frame the badge, then take the photo.")
        case "parking":
            return String(localized: "Frame the parking sign, then take the photo.")
        default:
            return String(localized: "Frame what you want me to look at, then take the photo.")
        }
    }

    // MARK: - Router budget

    /// The router's timeout for one call. A tool that may wait on the user's photo gets its usual
    /// budget *plus* the wait — only while the glasses are away, and only for ask-on-phone tools.
    static func timeoutBudget(base: TimeInterval, toolName: String,
                              glassesConnected: Bool) -> TimeInterval {
        guard !glassesConnected, routes[toolName] == .askOnPhone else { return base }
        return base + requestTimeout + presentationGrace
    }

    // MARK: - Field Assist tiles

    /// The job tiles that open the phone camera *before* their prompt when no glasses are
    /// connected, so the tool the prompt calls has its photo without a model round trip first.
    static let preCaptureTiles: [String: String] = [
        "fa-fault-code": "equipment_lookup",
        "fa-safety-check": "safety_assessment",
        "fa-log-photo": "photo_log",
    ]

    /// The framing hint for a tile that should open the phone camera first, or nil when it should
    /// not (glasses connected, or not a camera tile).
    static func preCaptureHint(forQuickAction id: String, glassesConnected: Bool) -> String? {
        guard !glassesConnected, let tool = preCaptureTiles[id] else { return nil }
        return framingHint(forTool: tool)
    }

    /// Added to a tile's prompt when its photo is waiting, so the model reaches for the camera
    /// tool rather than answering from the words alone.
    static let stagedPhotoPromptSuffix =
        "I've just taken the photo with my phone; use your camera tool to look at it."

    // MARK: - What the model is told

    /// Appended to a tool result that used a phone photo, so the model never says "through your
    /// glasses" about a picture the phone took.
    static let phonePhotoNote = "(Photo taken with the phone camera — no glasses are connected.)"

    /// The tool result the model receives, given what happened to phone photos during the call.
    ///
    /// A request that ended without a photo is *prepended*, not substituted: a tool that still did
    /// something useful — `parking` saves the spot without its photo — keeps saying so.
    @MainActor
    static func toolResult(_ raw: String, ledger: PhoneCaptureLedger) -> String {
        if let failure = ledger.failure, let sentence = failure.toolResultSentence {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? sentence : sentence + "\n" + trimmed
        }
        if ledger.phonePhotos > 0 {
            return raw + "\n" + phonePhotoNote
        }
        return raw
    }
}

/// How a request for a phone photo ended.
enum PhonePhotoOutcome: Equatable, Sendable {
    case photo(Data)
    /// The user closed the camera.
    case cancelled
    /// Nobody took a photo within `PhoneCapturePolicy.requestTimeout`.
    case timedOut
    /// Another request already has the camera open.
    case busy
    /// The app is backgrounded or the phone is locked, so no camera can be shown.
    case appNotOnScreen
    /// The camera view never appeared — another sheet was in the way, or nothing is wired to
    /// show it.
    case couldNotPresent

    var photo: Data? {
        if case .photo(let data) = self { return data }
        return nil
    }

    /// The sentence the model receives for an outcome without a photo. Each one says plainly that
    /// nothing was seen: a model told only "failed" has been known to describe the scene anyway.
    var toolResultSentence: String? {
        switch self {
        case .photo:
            return nil
        case .cancelled:
            return "The user cancelled the phone camera, so no photo was taken. Nothing was seen — do not describe or guess what is in front of them."
        case .timedOut:
            return "No photo was taken within \(Int(PhoneCapturePolicy.requestTimeout)) seconds, so the phone camera was closed. Nothing was seen — do not describe or guess what is in front of them."
        case .busy:
            return "The phone camera is already open for another request, so no photo was taken for this one. Ask the user to finish or cancel that photo first."
        case .appNotOnScreen:
            return "No glasses are connected, and the phone camera needs Avenkin open on screen, so no photo was taken. Ask the user to open the app and try again, or to describe what they see."
        case .couldNotPresent:
            return "The phone camera couldn't open over what is on screen, so no photo was taken. Ask the user to close the open screen and try again."
        }
    }

    /// A short line for the screen when a tile's own photo did not happen. `nil` for a cancel —
    /// the user did that on purpose and needs no telling.
    var userNotice: String? {
        switch self {
        case .photo, .cancelled: return nil
        case .timedOut: return String(localized: "No photo was taken.")
        case .busy: return String(localized: "The phone camera is already open.")
        case .appNotOnScreen: return String(localized: "Open Avenkin on your phone to take the photo.")
        case .couldNotPresent: return String(localized: "Close the open screen, then try again.")
        }
    }
}

/// Thrown by `CameraService.capturePhoto` when a tool's phone photo did not happen. Its message is
/// the same sentence the router gives the model, so a tool that reports the error text verbatim
/// still says the right thing.
struct PhonePhotoError: LocalizedError, Equatable {
    let outcome: PhonePhotoOutcome
    var errorDescription: String? { outcome.toolResultSentence }
}

/// What happened to phone photos during one tool call. Held task-locally by the router for the
/// duration of a native tool's `execute`, written by `CameraService`.
@MainActor
final class PhoneCaptureLedger {
    private(set) var phonePhotos = 0
    /// The first request that ended without a photo. Kept, so a second request in the same call is
    /// refused with the same outcome instead of opening the camera again.
    private(set) var failure: PhonePhotoOutcome?

    init() {}

    func record(_ outcome: PhonePhotoOutcome) {
        if outcome.photo != nil {
            phonePhotos += 1
        } else if failure == nil {
            failure = outcome
        }
    }
}

enum PhoneCaptureScope {
    @TaskLocal static var ledger: PhoneCaptureLedger?

    /// Run one tool's work with a fresh ledger and compose the result the model receives.
    @MainActor
    static func run(_ work: () async throws -> String) async throws -> String {
        let ledger = PhoneCaptureLedger()
        do {
            let raw = try await $ledger.withValue(ledger) { try await work() }
            return PhoneCapturePolicy.toolResult(raw, ledger: ledger)
        } catch {
            // A tool that threw after its photo did not happen: the sentence is the useful part.
            if let sentence = ledger.failure?.toolResultSentence { return sentence }
            throw error
        }
    }
}
