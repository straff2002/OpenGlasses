import Foundation

/// What the camera preview may draw while the screen is being captured (Plan LT §1). Pure.
///
/// The preview is `PrivacyFilterScope.onDevicePreview`: unfiltered, because its pixels reach a
/// screen the wearer is holding and go nowhere else. A screen recording, a screen share or an
/// AirPlay mirror breaks that premise — the screen itself is leaving the device — so while the
/// bystander blur is on and the screen is captured, the preview stops drawing raw pixels:
///
/// - the glasses preview draws `OutboundFrameRelay`'s frames instead, the same blur pass a
///   recording or a broadcast already gets, so there is no second blur;
/// - with no filtered frame within `filteredFrameWait` it draws nothing but a short line, never the
///   raw picture;
/// - the phone camera's viewfinder has no filtered source at all (its frames never pass the relay),
///   so it goes blank.
///
/// With the blur off nothing changes, as the wearer chose; when capture stops, the raw preview
/// comes back on the next frame. A screenshot is not covered (iOS reports one only after it is
/// taken), nor is another device filming the phone.
enum PreviewCapturePolicy {

    /// What the preview draws.
    enum Display: Equatable {
        /// The camera's own pixels, as always.
        case raw
        /// The blur relay's frames.
        case filtered
        /// Nothing but the short line.
        case blank
    }

    /// How long a filtered frame stands for the live picture. Past it — or before the first one —
    /// the preview is blank: a frame the relay has stopped producing is either a scene the blur
    /// could not process or a stream that has gone, and the raw picture is not the stand-in.
    static let filteredFrameWait: TimeInterval = 0.5

    /// The decision for one preview surface.
    ///
    /// - Parameters:
    ///   - blurOn: the bystander blur's switch.
    ///   - isCaptured: the screen is being recorded, shared or mirrored (`ScreenCaptureState`).
    ///   - scope: the surface's privacy scope. Only `.onDevicePreview` is this policy's to decide;
    ///     every other scope already has its own filter rule.
    ///   - hasFilteredSource: the surface's pixels pass through `OutboundFrameRelay` — the glasses
    ///     preview does, the phone viewfinder does not.
    static func decide(blurOn: Bool, isCaptured: Bool, scope: PrivacyFilterScope,
                       hasFilteredSource: Bool) -> Display {
        guard scope == .onDevicePreview, blurOn, isCaptured else { return .raw }
        return hasFilteredSource ? .filtered : .blank
    }

    /// What a `.filtered` decision draws right now: the latest filtered frame while it is fresh,
    /// else blank. Any other decision is returned as it is.
    ///
    /// - Parameter filteredFrameAge: seconds since the relay's latest frame arrived, nil for none
    ///   since the screen began to be captured.
    static func resolve(_ display: Display, filteredFrameAge: TimeInterval?) -> Display {
        guard display == .filtered else { return display }
        guard let age = filteredFrameAge, age >= 0, age <= filteredFrameWait else { return .blank }
        return .filtered
    }

    /// The line a blank preview shows.
    static var hiddenLine: String {
        String(localized: "Preview hidden while the screen is recorded or shared.")
    }

    /// The line over a filtered preview, so a blurred face reads as deliberate.
    static var filteredLine: String {
        String(localized: "Faces blurred while the screen is recorded or shared.")
    }
}
