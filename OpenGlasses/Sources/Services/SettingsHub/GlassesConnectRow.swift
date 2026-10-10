import Foundation

/// The row at the top of Devices & Privacy › Glasses that gives a wearer whose glasses are not
/// connected something to press (Plan HX P3a). Pure, over registration and the glasses' truthful
/// link phase, so which row shows is decided — and tested — without the SDK.
///
/// Before this the only connect action after onboarding was "Connect to Meta AI", shown only while
/// the app was *not* registered. A wearer who had registered and still had no link had nothing to
/// press anywhere: the SDK lists a device only once a permission is granted in Meta AI, the app
/// asked for it at launch with the outcome thrown away, and nothing asked again until a relaunch.
///
/// Deliberately small: Plan HX P3 replaces `resolve` with its reachability diagnosis, which can
/// tell a missing permission from a pair asleep in its case. Until then every registered pair
/// without a link gets the one action that can be taken from here, and `granted`'s footer says
/// what else to check when the permission turns out not to be the reason.
enum GlassesConnectRow: Equatable, Sendable {
    /// Not registered with Meta AI: "Connect to Meta AI", which starts registration.
    case connect
    /// Registered, no link: "Allow camera access in Meta AI", which checks the Meta camera
    /// permission and asks for it when it is not granted.
    case allowCameraAccess

    /// `nil` while a link is up or coming up — there is nothing to press. A link coming up means a
    /// device is listed, which is already past both registration and the permission.
    static func resolve(registration: GlassesRegistration,
                        phase: GlassesConnectionPhase) -> GlassesConnectRow? {
        guard !phase.isConnected, !phase.isConnecting else { return nil }
        return registration == .registered ? .allowCameraAccess : .connect
    }

    /// The footer under "Allow camera access in Meta AI": what the row is for until it has been
    /// pressed, then how the last press ended.
    static func allowCameraAccessFooter(outcome: GlassesCameraAccessOutcome?) -> String {
        guard let outcome else {
            return String(localized: "Avenkin is approved in Meta AI, but your glasses aren't connected. Meta AI shows Avenkin your glasses only after camera access is allowed there. This checks, and opens Meta AI if it needs your approval.")
        }
        return outcome.footer
    }
}

/// How the wearer's own "Allow camera access in Meta AI" ended. Kept and shown, where the launch
/// path's `try?` drops it.
enum GlassesCameraAccessOutcome: Equatable {
    /// The Meta camera permission is granted — just now, or already.
    case granted
    /// Meta AI answered, and the permission was not granted.
    case refused
    /// iOS has not let this app use a camera at all, which the glasses' permission is asked behind.
    case phoneCameraDenied
    /// The check itself failed. Carries a summary, never the error's text.
    case failed(SafeErrorSummary)

    /// From what `CameraService.ensurePermission()` threw. It throws `CameraError.permissionDenied`
    /// both for iOS's own camera permission and for Meta's, so `phoneCameraDenied` — read from iOS
    /// after the attempt — tells the two apart.
    init(error: Error, phoneCameraDenied: Bool) {
        if case .permissionDenied? = error as? CameraError {
            self = phoneCameraDenied ? .phoneCameraDenied : .refused
        } else {
            self = .failed(SafeErrorSummary(error))
        }
    }

    /// Runs the request and keeps how it ended. The two closures are the seams: the permission
    /// check-and-request (which can leave for Meta AI, so only ever a wearer's own action), and
    /// iOS's camera authorisation.
    @MainActor
    static func request(ensurePermission: () async throws -> Void,
                        phoneCameraDenied: () -> Bool) async -> GlassesCameraAccessOutcome {
        do {
            try await ensurePermission()
            return .granted
        } catch {
            return GlassesCameraAccessOutcome(error: error, phoneCameraDenied: phoneCameraDenied())
        }
    }

    /// What the row's footer says. `granted` carries the next things to check, because the row is
    /// still showing: the permission was not what kept the glasses away.
    var footer: String {
        switch self {
        case .granted:
            return String(localized: "Camera access is allowed in Meta AI. If your glasses still don't connect, check that they're switched on, out of their case and nearby, connected in the Meta AI app, and that no other glasses app is using Developer Mode.")
        case .refused:
            return String(localized: "Camera access wasn't allowed in Meta AI, and your glasses can't connect to Avenkin without it. Try again and allow it there.")
        case .phoneCameraDenied:
            return String(localized: "Avenkin isn't allowed to use the camera on this iPhone, which glasses camera access needs first. Turn Camera on for Avenkin in the iPhone's Settings app, then try again.")
        case .failed(let summary):
            return String(localized: "Avenkin couldn't check camera access with Meta AI (\(Self.reason(summary))). Make sure the Meta AI app is installed and Avenkin is still approved in it, then try again.")
        }
    }

    /// The summary as one word a wearer can quote to support: the error's case or type name when
    /// it has one, else its category. The code is left out — beside a case name it is that case's
    /// position in its enum, a number that means nothing to the person reading it.
    static func reason(_ summary: SafeErrorSummary) -> String {
        summary.detail?.description ?? summary.category.rawValue
    }
}
