import Foundation

/// The row at the top of Devices & Privacy › Glasses while the glasses are not connected: what
/// there is to press, if anything, and the line under it that says why they are not connected.
/// Pure, over the reachability diagnosis (Plan HX P3), so what shows is decided — and tested —
/// without the SDK.
///
/// Before P3a the only connect action after onboarding was "Connect to Meta AI", shown only while
/// the app was *not* registered. A wearer who had registered and still had no link had nothing to
/// press anywhere: the SDK lists a device only once a permission is granted in Meta AI, the app
/// asked for it at launch with the outcome thrown away, and nothing asked again until a relaunch.
/// P3a gave every registered pair without a link the one action that can be taken from here. The
/// diagnosis now tells them apart: only a pair Meta AI lists no device for, with the permission
/// not known to be granted, is asked to allow it; a pair that is listed and out of reach is told
/// that, and has nothing to press because there is nothing the app can do about it.
struct GlassesConnectRow: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// "Connect to Meta AI", which starts registration and then asks for camera access.
        case connect
        /// "Allow camera access in Meta AI", which checks the Meta camera permission and asks
        /// for it once when it is not granted.
        case allowCameraAccess
    }

    /// The button, or nil when the row only says where things stand.
    let action: Action?
    /// The row's own words when it is not a button.
    let title: String?
    /// The line under the row: why the glasses are not connected, and what to do about it.
    let footer: String

    /// `nil` while a link is up or coming up — there is nothing to say or press.
    init?(_ reachability: GlassesReachability) {
        switch reachability.diagnosis {
        case .notAdded, .awaitingApproval:
            // Removed from Meta AI, or never added past onboarding. A registration in flight
            // keeps the row and its spinner. The gate is named before the hand-off: Meta AI's
            // own refusal is a bare "Internal error" (see `RegistrationFlow.beforeHandoffMessage`).
            action = .connect
            title = nil
            footer = "Avenkin isn't connected to your glasses in the Meta AI app. "
                + RegistrationFlow.beforeHandoffMessage()
        case .permissionNeeded:
            action = .allowCameraAccess
            title = nil
            footer = Self.allowCameraAccessFooter(reachability.permission)
        case .noDeviceSeen:
            action = nil
            title = String(localized: "Meta AI isn't showing your glasses yet")
            footer = String(localized: "Camera access is allowed in Meta AI. If your glasses still don't connect, check that they're switched on, out of their case and nearby, connected in the Meta AI app, and that no other glasses app is using Developer Mode.")
        case .linkDown:
            action = nil
            title = String(localized: "Glasses out of reach")
            footer = String(localized: "Your glasses are added but out of reach. Check that they're switched on, out of their case and nearby, and that Bluetooth is on. They connect on their own once they are.")
        case .linkComingUp, .connected:
            return nil
        }
    }

    /// The footer under "Allow camera access in Meta AI": what the row is for until the
    /// permission has been asked for, then how asking ended. The status is the published one, so
    /// a check made at launch and a press on the row feed the same line.
    static func allowCameraAccessFooter(_ permission: GlassesCameraPermission) -> String {
        switch permission {
        case .notChecked, .notGranted, .granted:
            // `granted` does not reach this row (the diagnosis is then `noDeviceSeen`).
            return String(localized: "Avenkin is approved in Meta AI, but your glasses aren't connected. Meta AI shows Avenkin your glasses only after camera access is allowed there. This checks, and opens Meta AI if it needs your approval.")
        case .declined:
            return String(localized: "Camera access wasn't allowed in Meta AI, and your glasses can't connect to Avenkin without it. Try again and allow it there.")
        case .phoneCameraDenied:
            return String(localized: "Avenkin isn't allowed to use the camera on this iPhone, which glasses camera access needs first. Turn Camera on for Avenkin in the iPhone's Settings app, then try again.")
        case .failed(let summary):
            return String(localized: "Avenkin couldn't check camera access with Meta AI (\(GlassesCameraPermission.reason(summary))). Make sure the Meta AI app is installed and Avenkin is still approved in it, then try again.")
        }
    }

    /// What VoiceOver is told once the wearer's own request has ended. The row changes while
    /// focus is still on the button that was pressed — to another footer, to a row with nothing to
    /// press, or away altogether when the glasses connect — so the new state is said.
    static func announcement(after reachability: GlassesReachability) -> String {
        if let row = GlassesConnectRow(reachability) {
            return [row.title, row.footer].compactMap { $0 }.joined(separator: ". ")
        }
        return reachability.diagnosis.statusLine(deviceName: nil)
    }
}
