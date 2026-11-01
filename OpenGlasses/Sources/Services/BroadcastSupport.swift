import AVFoundation
import Foundation
import UIKit

// MARK: - Plan BS P2/P3 — pure broadcast support types

/// Output geometry for the RTMP encoder (was hardcoded 720×1280 portrait).
enum BroadcastGeometry {
    static func outputSize(orientation: String) -> (width: Int, height: Int) {
        orientation == "landscape" ? (1280, 720) : (720, 1280)
    }

    /// Aspect-fit rect for drawing a frame into the output buffer (black letterbox around
    /// it). The previous stretch-to-fill distorted any source whose aspect didn't match.
    static func aspectFitRect(imageSize: CGSize, in canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Monotonic sample-time clock for the broadcast audio track: mic buffers arrive without
/// usable timeline context, so the stream's audio PTS is a running sample count.
struct BroadcastAudioClock {
    private(set) var sampleTime: Int64 = 0

    /// Returns the presentation sample-time for a buffer of `frames`, then advances.
    mutating func take(frames: AVAudioFrameCount) -> Int64 {
        let time = sampleTime
        sampleTime += Int64(frames)
        return time
    }
}

/// A selectable broadcast video source.
enum BroadcastVideoSource: String, CaseIterable, Codable {
    case glasses
    case phoneBack = "phone_back"
    case phoneFront = "phone_front"

    var displayLabel: String {
        switch self {
        case .glasses: return "Glasses"
        case .phoneBack: return "Phone (Back)"
        case .phoneFront: return "Phone (Front)"
        }
    }

    var isPhone: Bool { self != .glasses }

    var phonePosition: AVCaptureDevice.Position? {
        switch self {
        case .glasses: return nil
        case .phoneBack: return .back
        case .phoneFront: return .front
        }
    }
}

/// What Go Live does, and what may reach the encoder while a stream runs (pure).
///
/// **Phone frames are never blurred** (`PhoneVideoSource` hands them straight to the encoder, and
/// Plan KH deliberately builds no phone-frame blur). So while Blur Bystander Faces is on, every
/// route from the phone camera to the encoder is refused here: the fallback, a phone Camera
/// setting, the Dual Capture inset and a mid-stream switch. `BroadcastService` asks
/// `phoneFramesAllowed(faceBlurOn:)` at each of those routes too, so a caller that skipped this
/// type still cannot put a phone frame on air with the blur on.
enum BroadcastGoLive {
    struct Facts: Equatable {
        var isBroadcasting: Bool
        var isConfigured: Bool
        /// Live Streaming's Camera setting.
        var preferredSource: BroadcastVideoSource
        var glassesConnected: Bool
        /// Blur Bystander Faces is on.
        var faceBlurOn: Bool
        /// iOS has refused the phone camera, or a restriction has.
        var phoneCameraDenied: Bool
        /// Capture & Streaming can be opened on this phone.
        var setupReachable: Bool
        /// Live Streaming's Dual Capture setting: the phone camera as an inset.
        var dualCaptureOn = false
    }

    /// The ways a phone frame could reach the encoder.
    enum PhoneRoute: Equatable {
        /// Camera is set to Glasses, none are connected, and the phone would stand in.
        case fallback
        /// Camera is set to a phone camera.
        case chosen
        /// Dual Capture would put the phone camera in the picture.
        case inset
        /// A switch of camera during a stream.
        case midStreamSwitch
    }

    enum Decision: Equatable {
        /// Start or stop. `startSource` is nil to start on the Camera setting.
        case toggle(startSource: BroadcastVideoSource?)
        case needsSetup(canOpenSettings: Bool)
        /// The phone camera would go out with the blur the wearer has on not covering it.
        case phoneCameraNotBlurred(PhoneRoute)
        case phoneCameraDenied
    }

    /// The one rule every route asks.
    static func phoneFramesAllowed(faceBlurOn: Bool) -> Bool { !faceBlurOn }

    /// Stopping always wins: nothing below may stand between the wearer and ending a stream.
    ///
    /// A glasses stream with no glasses connected would go LIVE with a black picture and an open
    /// microphone, so it falls back to the phone's back camera, unless the blur is on.
    static func decide(_ facts: Facts) -> Decision {
        guard !facts.isBroadcasting else { return .toggle(startSource: nil) }
        guard facts.isConfigured else { return .needsSetup(canOpenSettings: facts.setupReachable) }
        let fallsBack = facts.preferredSource == .glasses && !facts.glassesConnected
        if !phoneFramesAllowed(faceBlurOn: facts.faceBlurOn) {
            if fallsBack { return .phoneCameraNotBlurred(.fallback) }
            if facts.preferredSource.isPhone { return .phoneCameraNotBlurred(.chosen) }
            if facts.dualCaptureOn { return .phoneCameraNotBlurred(.inset) }
        }
        if (fallsBack || facts.preferredSource.isPhone) && facts.phoneCameraDenied {
            return .phoneCameraDenied
        }
        return .toggle(startSource: fallsBack ? .phoneBack : nil)
    }

    // MARK: Siri and Shortcuts

    /// Why a stream asked for by voice or a Shortcut did not start. There is no button to go back
    /// to and no alert to answer, so each is a sentence to say.
    enum IntentRefusal: Equatable {
        case notSetUp
        case phoneCameraNotBlurred(PhoneRoute)
        case phoneCameraDenied
        /// iOS has never been asked for the phone camera. Asking here would raise a prompt out of
        /// nowhere, with nobody holding the phone.
        case phoneCameraNotAsked
        /// The camera it would use gave no picture, so going live would be an open microphone over
        /// a black screen.
        case noPicture
        /// The streaming server would not take the stream. What it said is on screen, not spoken:
        /// a connection error can name the destination.
        case couldNotConnect
    }

    enum IntentDecision: Equatable {
        case stop
        /// Start on this camera, once it is giving a picture.
        case start(BroadcastVideoSource)
        case refuse(IntentRefusal)
    }

    /// The same checks as Go Live, then what only an intent has to care about: nobody is looking at
    /// the phone, so nothing may ask them anything. Stopping still wins before all of it.
    static func decideForIntent(_ facts: Facts, phoneCameraNotAsked: Bool) -> IntentDecision {
        guard !facts.isBroadcasting else { return .stop }
        switch decide(facts) {
        case .needsSetup:
            return .refuse(.notSetUp)
        case .phoneCameraNotBlurred(let route):
            return .refuse(.phoneCameraNotBlurred(route))
        case .phoneCameraDenied:
            return .refuse(.phoneCameraDenied)
        case .toggle(let source):
            let start = source ?? facts.preferredSource
            if phoneCameraNotAsked && (start.isPhone || facts.dualCaptureOn) {
                return .refuse(.phoneCameraNotAsked)
            }
            return .start(start)
        }
    }

    static func spokenRefusal(_ refusal: IntentRefusal) -> String {
        switch refusal {
        case .notSetUp:
            return String(localized: "Live streaming isn't set up. Add your platform and stream key in Avenkin first.")
        case .phoneCameraNotBlurred(.inset):
            return String(localized: "I can't go live. Blur Bystander Faces is on, and Dual Capture would put the phone camera on the stream.")
        case .phoneCameraNotBlurred(.fallback):
            return String(localized: "I can't go live. No glasses are connected, and Blur Bystander Faces doesn't cover the phone camera.")
        case .phoneCameraNotBlurred:
            return String(localized: "I can't go live. Camera is set to the phone, and Blur Bystander Faces doesn't cover it.")
        case .phoneCameraDenied:
            return String(localized: "I can't go live. Camera access is off for Avenkin in iOS Settings.")
        case .phoneCameraNotAsked:
            return String(localized: "I can't go live yet. Open Preview in Avenkin and tap Go Live once, to allow the phone camera.")
        case .noPicture:
            return String(localized: "I can't go live, because the camera isn't giving a picture.")
        case .couldNotConnect:
            return String(localized: "I couldn't reach the streaming server, so you aren't live.")
        }
    }

    /// How long the phone camera has to come up for an intent. It starts in a moment or not at all.
    static let phonePictureTimeout: TimeInterval = 4

    enum SwitchDecision: Equatable {
        case switchCamera
        case phoneCameraNotBlurred
    }

    /// A camera chosen during a stream. The glasses are always open: their frames are blurred.
    static func decideSwitch(to source: BroadcastVideoSource, faceBlurOn: Bool) -> SwitchDecision {
        source.isPhone && !phoneFramesAllowed(faceBlurOn: faceBlurOn) ? .phoneCameraNotBlurred : .switchCamera
    }

    /// What a stream that is already on air is doing, read when something it depends on changes.
    struct LiveFacts: Equatable {
        var isBroadcasting: Bool
        var activeSource: BroadcastVideoSource
        /// The phone camera is in the picture as an inset.
        var phoneInsetOn: Bool
        var faceBlurOn: Bool
        var glassesConnected: Bool
    }

    /// Why a running stream was ended rather than left to carry on.
    enum EndReason: Equatable {
        /// The blur came on during a phone stream with no glasses to move to.
        case blurNeedsGlasses
        /// The blur came on during a phone stream, and the glasses gave no picture to move to.
        case glassesGaveNoPicture
    }

    enum LiveAction: Equatable {
        case carryOn
        /// The stream stays on the glasses, whose frames are blurred. Only the inset goes.
        case dropPhoneInset
        case moveToGlasses
        case end(EndReason)
    }

    /// Turning the blur on during a phone stream must not leave faces going out unblurred: the
    /// wearer asked for them to be covered, and viewers are watching now. The stream moves to the
    /// glasses when there are glasses, which keeps it on air and covers the faces. Otherwise it
    /// ends, because there is no third picture to send.
    static func whileLive(_ facts: LiveFacts) -> LiveAction {
        guard facts.isBroadcasting else { return .carryOn }
        guard !phoneFramesAllowed(faceBlurOn: facts.faceBlurOn) else { return .carryOn }
        if facts.activeSource.isPhone {
            return facts.glassesConnected ? .moveToGlasses : .end(.blurNeedsGlasses)
        }
        return facts.phoneInsetOn ? .dropPhoneInset : .carryOn
    }

    /// How long a glasses camera has to give a picture: its cold start takes up to twenty seconds.
    static let glassesPictureTimeout: TimeInterval = 20

    static func endMessage(_ reason: EndReason) -> String {
        switch reason {
        case .blurNeedsGlasses:
            return String(localized: "The live stream has ended. Blur Bystander Faces is on, it can't cover the phone camera, and no glasses are connected.")
        case .glassesGaveNoPicture:
            return String(localized: "The live stream has ended. Blur Bystander Faces is on, it can't cover the phone camera, and the glasses camera didn't start.")
        }
    }

    static var movedToGlassesMessage: String {
        String(localized: "Blur Bystander Faces is on, so the stream has moved to the glasses camera.")
    }

    static var insetDroppedMessage: String {
        String(localized: "Blur Bystander Faces is on, so the phone camera inset has left the stream.")
    }
}

/// Mid-stream source-switch state machine (pure). Debounces rapid switches so the RTMP
/// pipeline isn't churned, and remembers the active source for frame routing.
struct BroadcastSourceSelector {
    private(set) var active: BroadcastVideoSource
    let debounce: TimeInterval
    private var lastSwitch: Date?

    init(initial: BroadcastVideoSource, debounce: TimeInterval = 1.0) {
        self.active = initial
        self.debounce = debounce
    }

    /// Attempt a switch at `now`. Returns true if accepted (and applied).
    mutating func requestSwitch(to source: BroadcastVideoSource, now: Date) -> Bool {
        guard source != active else { return false }
        if let last = lastSwitch, now.timeIntervalSince(last) < debounce { return false }
        active = source
        lastSwitch = now
        return true
    }

    /// A move a safety rule made. The debounce exists to save the pipeline from churn, and a frame
    /// of unblurred faces is worth more than that, so this one is not held back. It still starts
    /// the debounce, so a tap straight after cannot bounce back.
    mutating func moveNow(to source: BroadcastVideoSource, now: Date) {
        active = source
        lastSwitch = now
    }
}

/// Dual-capture picture-in-picture compositing (pure — UIGraphicsImageRenderer, CPU path,
/// preserving the broadcast pipeline's background safety; no Metal).
enum FrameCompositor {
    struct Spec {
        /// Inset width as a fraction of the canvas width.
        var insetFraction: CGFloat = 0.30
        var margin: CGFloat = 16
        var cornerRadius: CGFloat = 10
    }

    /// Bottom-trailing inset rect for a secondary frame of `insetSize` aspect on `canvas`.
    static func insetRect(canvas: CGSize, insetAspect: CGFloat, spec: Spec = Spec()) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, insetAspect > 0 else { return .zero }
        let width = canvas.width * spec.insetFraction
        let height = width / insetAspect
        return CGRect(
            x: canvas.width - width - spec.margin,
            y: canvas.height - height - spec.margin,
            width: width,
            height: height
        )
    }

    /// Compose `inset` over `main` (canvas = main's size). Returns `main` untouched when
    /// there is no inset.
    static func compose(main: UIImage, inset: UIImage?, spec: Spec = Spec()) -> UIImage {
        guard let inset, inset.size.width > 0, inset.size.height > 0 else { return main }
        let canvas = main.size
        guard canvas.width > 0, canvas.height > 0 else { return main }

        let rect = insetRect(
            canvas: canvas,
            insetAspect: inset.size.width / inset.size.height,
            spec: spec
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            main.draw(in: CGRect(origin: .zero, size: canvas))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: spec.cornerRadius)
            context.cgContext.saveGState()
            path.addClip()
            inset.draw(in: rect)
            context.cgContext.restoreGState()
        }
    }
}
