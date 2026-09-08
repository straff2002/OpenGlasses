import Foundation
import MWDATCamera

/// Plan EO P1 — what the glasses are asked to send, and what to do with each frame that
/// comes back (pure).
///
/// The stream used to be requested as **raw** pixels. A 720×1280 raw frame is ~1.4 MB, which the
/// glasses link cannot carry at any useful rate, so the SDK's ladder quietly steps the source down
/// and the delivered rate sags. Asking for `hvc1` instead moves roughly 10–30× less over the wire
/// and leaves the decode to the phone. `raw` stays reachable as a setting because a firmware that
/// mishandles compressed video must not need a reinstall to work around.
enum StreamCodecPolicy {

    /// The two values `Config.cameraCodec` may hold. Anything else is somebody's typo or an
    /// older build's string, and reads as the default.
    static let hevcSetting = "hevc"
    static let rawSetting = "raw"

    /// Maps the stored setting to the codec asked of the SDK. Unknown → `hvc1`, because the
    /// default has to survive a value nobody recognises.
    static func videoCodec(for setting: String) -> VideoCodec {
        setting == rawSetting ? .raw : .hvc1
    }

    /// What a delivered frame turned out to be, as two observations rather than a guess about
    /// the codec: whether the SDK's `makeUIImage()` helper produced a picture, and whether the
    /// sample carries a data buffer (`CMSampleBufferGetDataBuffer` — a raw frame carries an
    /// *image* buffer, a compressed one a *data* buffer).
    enum FrameShape: Equatable {
        /// The helper handed us a picture. Either the frame was raw, or the SDK decoded it
        /// for us — from here the two are the same thing and neither needs our decoder.
        case picture
        /// No picture, but there are compressed bytes to decode.
        case compressed
        /// Neither. Nothing to show and nothing to decode.
        case empty
    }

    /// What the listener does with a frame of that shape.
    enum FrameAction: Equatable {
        case emit
        case decode
        case drop
    }

    static func shape(helperProducedImage: Bool, hasDataBuffer: Bool) -> FrameShape {
        if helperProducedImage { return .picture }
        return hasDataBuffer ? .compressed : .empty
    }

    static func action(for shape: FrameShape) -> FrameAction {
        switch shape {
        case .picture: return .emit
        case .compressed: return .decode
        case .empty: return .drop
        }
    }
}

/// Plan EO P1 — tells a dead link from a decoder that is waiting (pure).
///
/// The stall detector used to watch one clock: the moment a decoded *image* reached the main
/// actor. With a decoder in the path that clock stops for two entirely different reasons — the
/// glasses stopped sending, or the decoder is holding for a keyframe — and only the first one is
/// fixed by tearing the stream down. The second is made *worse* by it, because the rebuild
/// restarts the wait for a keyframe.
///
/// So two clocks: a sample arrived, and a picture was produced. A held last-good frame is not a
/// picture and must not refresh either clock, or the app would look alive while showing a
/// still.
struct StreamLiveness {

    enum Verdict: Equatable {
        case healthy
        /// Nothing is arriving from the glasses. Rebuild the stream (the behaviour that shipped).
        case linkStalled
        /// Samples are arriving and none of them becomes a picture. Rebuild the **decoder**,
        /// never the stream.
        case decodeStalled
    }

    /// How long either clock may stand still before it counts as a stall. 1.5 s is the value the
    /// stream-level detector has always used; keeping them equal means a link stall is still
    /// caught exactly as fast as it was before the decoder existed.
    static let stallThreshold: TimeInterval = 1.5

    private(set) var lastSample: Date
    private(set) var lastPicture: Date

    init(now: Date = Date()) {
        lastSample = now
        lastPicture = now
    }

    /// Both clocks start again — used when a stream (re)starts, so a warmup is not read as a
    /// stall the instant the detector arms.
    mutating func restart(at now: Date = Date()) {
        lastSample = now
        lastPicture = now
    }

    /// A frame arrived from the SDK, whatever shape it turned out to be.
    mutating func sampleArrived(at now: Date = Date()) {
        lastSample = now
    }

    /// A picture was actually produced — the helper's image, or a freshly decoded one. A picture
    /// implies a sample, so it refreshes both clocks; that is what keeps a raw stream (which
    /// never reports samples separately) reading as healthy.
    mutating func pictureProduced(at now: Date = Date()) {
        lastSample = now
        lastPicture = now
    }

    /// The app was handed the *previous* picture again because the decoder is holding. Refreshes
    /// nothing, deliberately: this method exists so the call site says so out loud rather than
    /// silently omitting a stamp.
    mutating func heldFrameDelivered() {}

    func verdict(now: Date = Date()) -> Verdict {
        if now.timeIntervalSince(lastSample) > Self.stallThreshold { return .linkStalled }
        if now.timeIntervalSince(lastPicture) > Self.stallThreshold { return .decodeStalled }
        return .healthy
    }

    func secondsSinceLastPicture(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastPicture)
    }
}

/// Plan EO P1 — a freshly created decompression session cannot start mid-GOP (pure).
///
/// Feeding a decoder non-keyframe samples after a (re)creation produces smeared, half-referenced
/// pictures. Those would reach a vision model, a recording and the lens as if they were real, so
/// the rule is to withhold them: nothing goes to the decoder until the first keyframe, and the
/// last good picture is what the app keeps seeing in the meantime.
struct KeyframeHold {

    /// True from creation until the first keyframe clears it.
    private(set) var isHolding = true

    /// Re-arm after invalidating or rebuilding a session.
    mutating func rearm() { isHolding = true }

    /// Whether this sample may reach the decoder. A keyframe both passes and ends the hold.
    mutating func admits(keyframe: Bool) -> Bool {
        guard isHolding else { return true }
        guard keyframe else { return false }
        isHolding = false
        return true
    }
}
