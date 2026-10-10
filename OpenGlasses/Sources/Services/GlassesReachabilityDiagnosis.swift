import Foundation

// Why glasses that are added are not connected (Plan HX P3).
//
// Pure and SDK-free, like `GlassesConnectionPhase` beside it. The phase answers "are the glasses
// connected"; this answers "and if not, what is in the way", from the same facts plus one more:
// the Meta camera permission's last known status. Before it, "registered, nothing listed" (most
// often the permission was never granted), "listed but out of reach" and "never added" all read
// "Not connected", and a wearer who had just paired had no way to tell which they were in.
//
// A reading of state, never a source of it. `GlassesConnectionSnapshot` still owns the phase, and
// nothing here can make the glasses connected.

/// The Meta camera permission as the app last knew it. A device is listed by the SDK only once a
/// permission is granted in Meta AI, so this is what separates "Meta AI has not been asked" from
/// "Meta AI was asked and the glasses still are not there".
enum GlassesCameraPermission: Equatable, Sendable {
    /// Not read yet in this process, or there was nothing to read it from.
    case notChecked
    case granted
    /// Read without asking, and not granted.
    case notGranted
    /// Asked for in Meta AI, and not granted.
    case declined
    /// iOS has not let this app use a camera at all, which the request is made behind.
    case phoneCameraDenied
    /// The check or the request itself failed. Carries a summary, never the error's text.
    case failed(SafeErrorSummary)

    var isGranted: Bool { self == .granted }

    /// Meta AI or iOS has said no, as opposed to not having been asked or not having answered.
    var isKnownNotGranted: Bool {
        switch self {
        case .notGranted, .declined, .phoneCameraDenied: return true
        case .notChecked, .granted, .failed: return false
        }
    }

    /// The status as one token, for the support report and the log.
    var reportToken: String {
        switch self {
        case .notChecked: return "notChecked"
        case .granted: return "granted"
        case .notGranted: return "notGranted"
        case .declined: return "declined"
        case .phoneCameraDenied: return "phoneCameraDenied"
        case .failed(let summary): return "failed(\(Self.reason(summary)))"
        }
    }

    /// A failure as one word a wearer can quote to support: the error's case or type name when it
    /// has one, else its category. The code is left out: beside a case name it is that case's
    /// position in its enum, the same kind of number as a raw registration state.
    static func reason(_ summary: SafeErrorSummary) -> String {
        summary.detail?.description ?? summary.category.rawValue
    }
}

/// Where the glasses are on the way to connected, and what is in the way.
enum GlassesReachabilityDiagnosis: Equatable, Sendable, CaseIterable {
    /// Not registered with Meta AI and nothing listed.
    case notAdded
    /// A registration is in flight: the wearer is approving the app in Meta AI.
    case awaitingApproval
    /// Registered, nothing listed, and the camera permission is not known to be granted.
    case permissionNeeded
    /// Registered, the permission granted, and Meta AI still lists no device.
    case noDeviceSeen
    /// A device is listed and none is connected or connecting: off, in its case, out of range.
    case linkDown
    /// A listed device's link is coming up.
    case linkComingUp
    /// A listed device's link is up.
    case connected

    /// The table. A listed device decides it by its link, whatever registration and the permission
    /// read: a device is only ever listed past both, and registration has been seen dipping during
    /// a healthy session (`GlassesConnectionSnapshot`). Several devices follow the snapshot's rule:
    /// connected when any is, coming up when none is connected and any is connecting.
    ///
    /// With nothing listed, a permission that is not known to be granted is the thing to fix
    /// first, so a check that failed or has not run reads `permissionNeeded`, not `noDeviceSeen`.
    static func resolve(registration: GlassesRegistration, links: [GlassesLinkState],
                        permission: GlassesCameraPermission) -> GlassesReachabilityDiagnosis {
        if !links.isEmpty {
            if links.contains(.connected) { return .connected }
            if links.contains(.connecting) { return .linkComingUp }
            return .linkDown
        }
        switch registration {
        case .notRegistered: return .notAdded
        case .registering: return .awaitingApproval
        case .registered: return permission.isGranted ? .noDeviceSeen : .permissionNeeded
        }
    }

    /// The phase this diagnosis is a finer reading of. They are folded from the same snapshot, so
    /// they cannot disagree; the mapping is here for the tests that say so.
    var phase: GlassesConnectionPhase {
        switch self {
        case .notAdded, .awaitingApproval: return .noGlassesAdded
        case .permissionNeeded, .noDeviceSeen, .linkDown: return .addedDisconnected
        case .linkComingUp: return .connecting
        case .connected: return .connected
        }
    }

    /// The short status line `GlassesConnectionService.connectionStatus` carries: sized for the
    /// session card's headline, and something to do rather than a state. "Not connected" is the
    /// wording the card maps to its own headline.
    func statusLine(deviceName: String?, appName: String = RegistrationFlow.appName) -> String {
        switch self {
        case .notAdded: return "Not connected"
        case .awaitingApproval:
            return RegistrationFlow.status(stateRaw: RegistrationFlow.registeredStateRawValue - 1,
                                           appName: appName)
        case .permissionNeeded: return "Allow camera access in Meta AI"
        case .noDeviceSeen: return "Waiting for Meta AI to show your glasses…"
        case .linkDown: return "Glasses out of reach"
        case .linkComingUp: return "Connecting…"
        case .connected: return "Connected to \(deviceName ?? "glasses")"
        }
    }
}

/// The facts a diagnosis is read from, kept together so every reader — the session card, Devices
/// & Privacy › Glasses, the connect failure message, the Developer panel, the support report —
/// describes the same moment.
struct GlassesReachability: Equatable, Sendable {
    var registration: GlassesRegistration = .notRegistered
    /// Each listed device's link, in the SDK's order. Its count is the number of devices listed.
    var links: [GlassesLinkState] = []
    var permission: GlassesCameraPermission = .notChecked

    init(registration: GlassesRegistration = .notRegistered, links: [GlassesLinkState] = [],
         permission: GlassesCameraPermission = .notChecked) {
        self.registration = registration
        self.links = links
        self.permission = permission
    }

    init(snapshot: GlassesConnectionSnapshot, permission: GlassesCameraPermission) {
        self.init(registration: snapshot.registration,
                  links: snapshot.deviceIds.map { snapshot.state(of: $0).link },
                  permission: permission)
    }

    var diagnosis: GlassesReachabilityDiagnosis {
        .resolve(registration: registration, links: links, permission: permission)
    }

    /// Whether a Connect the wearer pressed should ask for the camera permission now: registration
    /// has landed and nothing is listed. A listed device is already past the permission, and an
    /// app that is not registered has nothing to ask Meta AI about.
    var connectShouldAskForCameraAccess: Bool {
        registration == .registered && links.isEmpty
    }

    /// Nothing is listed and the permission is known to be missing, so no link can come up
    /// however long a Connect waits: its failure is reported at once. A check that has not run or
    /// did not answer is not that; the device may yet be listed.
    var waitsOnCameraAccess: Bool {
        diagnosis == .permissionNeeded && permission.isKnownNotGranted
    }

    /// The support report's line for glasses that are not in use: the diagnosis, then the four
    /// facts it was read from. Case names and a count only. A device's name or identifier never
    /// reaches this type, so it cannot reach the line.
    var reportLine: String {
        var listed = "devices listed \(links.count)"
        if !links.isEmpty {
            listed += " (" + links.map { "\($0)" }.joined(separator: ", ") + ")"
        }
        return "Glasses link: \(diagnosis) — registration \(registration), \(listed), "
            + "camera permission \(permission.reportToken)"
    }

    /// What the Developer panel's Glasses Link check says when the glasses are not in use.
    /// For someone debugging, so it names the facts; still no raw state number.
    var probeDetail: String {
        switch diagnosis {
        case .notAdded:
            return "Not added — connect in Settings › Devices & Privacy › Glasses"
        case .awaitingApproval:
            return "Registration in flight — approve the app in Meta AI"
        case .permissionNeeded:
            return "Registered, no device listed — camera access in Meta AI is \(permission.reportToken)"
        case .noDeviceSeen:
            return "Registered, camera access granted — Meta AI lists no device"
        case .linkDown:
            return "\(links.count) listed, none in reach — on, out of the case, nearby?"
        case .linkComingUp:
            return "Link coming up"
        case .connected:
            return "Link up, but the app is stood down from the glasses — resume them"
        }
    }
}
