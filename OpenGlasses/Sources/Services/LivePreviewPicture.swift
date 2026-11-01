import AVFoundation
import Foundation

/// Which camera the live preview draws (Plan KH, pure).
///
/// The preview shows what Go Live would put on air, so a phone-only wearer frames the shot before
/// they stream it and glasses are one way in rather than the only one.
enum LivePreviewPicture: Equatable {
    case glasses
    case phone(AVCaptureDevice.Position)

    struct Facts: Equatable {
        var isBroadcasting: Bool
        /// The camera on air now, which a mid-stream switch moves.
        var activeSource: BroadcastVideoSource
        /// Live Streaming's Camera setting.
        var preferredSource: BroadcastVideoSource
        var glassesConnected: Bool
    }

    /// While live, the camera on air, whatever else is true: a phone stream stays on the phone's
    /// picture when glasses connect, and a glasses stream that loses its glasses says so rather
    /// than showing a phone picture nobody is watching.
    ///
    /// Off air, connected glasses keep the preview they always had, even with Camera set to the
    /// phone. With none connected it is the phone camera the Camera setting names, or the back
    /// camera when that setting is Glasses, which is what Go Live falls back to.
    static func decide(_ facts: Facts) -> LivePreviewPicture {
        if facts.isBroadcasting {
            return facts.activeSource.phonePosition.map(LivePreviewPicture.phone) ?? .glasses
        }
        if facts.glassesConnected { return .glasses }
        return .phone(facts.preferredSource.phonePosition ?? .back)
    }

    /// The Take Photo button. Glasses take it as they always did. With none, it goes through
    /// `CameraService.capturePhoto()`, whose phone path is its own session on the back camera: only
    /// while that is the camera in view, and never during a stream, which it would interrupt.
    static func photoEnabled(glassesConnected: Bool, capturing: Bool, picture: LivePreviewPicture,
                             viewfinder: PhoneViewfinderPhase?, isBroadcasting: Bool) -> Bool {
        guard !capturing else { return false }
        if glassesConnected { return true }
        return picture == .phone(.back) && viewfinder == .live && !isBroadcasting
    }

    /// Why there is no Go Live button in Medical Compliance mode.
    static var streamingOffCaption: String {
        String(localized: "Preview only. Live streaming is off in Medical Compliance mode.")
    }

    /// The line over the phone camera's picture: what Go Live does with it, and the blur.
    ///
    /// A phone stream with the blur on does not exist (`BroadcastGoLive`), so nothing here has to
    /// warn that faces are going out unblurred.
    static func phoneCaption(isBroadcasting: Bool, blurOn: Bool) -> String {
        if isBroadcasting { return String(localized: "Streaming from the phone camera.") }
        return blurOn ? String(localized: "Phone camera. Go Live needs glasses while Blur Bystander Faces is on.")
                      : String(localized: "Phone camera. Go Live streams this picture.")
    }
}

/// What the phone camera's viewfinder has to show for itself (pure).
enum PhoneViewfinderPhase: Equatable {
    /// iOS has not been asked yet. The prompt is up, or about to be.
    case askingForAccess
    case denied
    case starting
    case live
    /// iOS has the camera for now, and will hand it back.
    case paused
    case unavailable

    static func decide(access: AVAuthorizationStatus, capture: PhoneCaptureStatus) -> PhoneViewfinderPhase {
        switch access {
        case .notDetermined: return .askingForAccess
        case .denied, .restricted: return .denied
        case .authorized:
            switch capture {
            case .stopped: return .starting
            case .running: return .live
            case .interrupted: return .paused
            case .unavailable: return .unavailable
            }
        @unknown default: return .denied
        }
    }
}
