import Foundation
import CoreMedia
import MWDATCamera
import UIKit

/// Plan EO P1 — the off-main half of the glasses frame path.
///
/// `MetaCameraBackend` is `@MainActor`, and the one thing that must not happen on the main actor
/// is decoding video. So the decoder, its liveness clocks and the once-per-stream shape log live
/// here, in a plain class the SDK's frame listener calls directly. What crosses back to the main
/// actor is a `UIImage` or nothing — the contract every consumer already has.
///
/// The lock is not an optimisation: the SDK makes no promise about which thread delivers a frame,
/// and a `VTDecompressionSession` driven from two threads at once is a crash waiting for a busy
/// moment. Decoding happens inline on the calling thread, which also gives the natural
/// back-pressure — a phone that cannot keep up holds the listener rather than growing a queue of
/// stale frames.
final class GlassesFramePipeline: @unchecked Sendable {

    private let lock = NSLock()
    private let decoder = VideoDecoder()
    private var liveness = StreamLiveness()
    /// Which branch the listener took, logged once per stream rather than once per frame.
    private var loggedShape: StreamCodecPolicy.FrameShape?

    /// Turn one delivered frame into the picture to publish, and say whether that picture is
    /// *fresh* — newly produced from this frame — or the last good one handed over again.
    ///
    /// The caller needs both: the app should keep seeing the last good image, but the photo-capture
    /// fallback must not treat a held frame as a recent view of the world.
    ///
    /// The shape is read from the frame itself rather than from the codec we asked for: a
    /// firmware that decodes for us produces a picture from the helper, and that must not be
    /// decoded a second time.
    func picture(for frame: VideoFrame) -> (image: UIImage?, isFresh: Bool) {
        let helperImage = frame.makeUIImage()
        let sampleBuffer = frame.sampleBuffer
        let shape = StreamCodecPolicy.shape(
            helperProducedImage: helperImage != nil,
            hasDataBuffer: CMSampleBufferGetDataBuffer(sampleBuffer) != nil)

        lock.lock()
        defer { lock.unlock() }

        logShapeOnce(shape)

        switch StreamCodecPolicy.action(for: shape) {
        case .emit:
            // A picture implies a sample, so this refreshes both clocks.
            liveness.pictureProduced()
            return (helperImage, true)
        case .decode:
            liveness.sampleArrived()
            let decoded = decoder.image(for: sampleBuffer)
            if decoded.producedFreshPicture {
                liveness.pictureProduced()
            } else {
                // A held last-good frame is not a picture: it must not refresh either clock, or
                // a decoder stuck waiting for a keyframe would read as a healthy stream.
                liveness.heldFrameDelivered()
            }
            return (decoded.image, decoded.producedFreshPicture)
        case .drop:
            // An empty frame is not evidence the link is alive, so it stamps *neither* clock —
            // note the sample clock is refreshed inside the switch for exactly this reason. If it
            // were stamped up front, a run of empties would keep `lastSample` fresh forever while
            // `lastPicture` went stale, the verdict would read `decodeStalled`, and the decoder
            // would be rebuilt every 1.5 s while the stream — the only lever that can help when
            // nothing decodable is arriving — was never touched.
            return (nil, false)
        }
    }

    /// The stall detector's question, answered from the two clocks this pipeline keeps.
    func verdict(now: Date = Date()) -> StreamLiveness.Verdict {
        lock.lock()
        defer { lock.unlock() }
        return liveness.verdict(now: now)
    }

    func secondsSinceLastPicture(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return liveness.secondsSinceLastPicture(now: now)
    }

    /// A stream (re)started: both clocks start again, so a warmup is never read as a stall.
    func restartClocks() {
        lock.lock()
        defer { lock.unlock() }
        liveness.restart()
    }

    /// `decodeStalled`: throw the decompression session away and let the next frame build a
    /// fresh one. The stream is untouched — that is the whole point of telling the two apart.
    func rebuildDecoder() {
        lock.lock()
        defer { lock.unlock() }
        decoder.rebuild()
        liveness.restart()
    }

    /// A stream teardown. The decoder goes with it, and the next stream logs its own shape.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        decoder.invalidateSession()
        liveness.restart()
        loggedShape = nil
    }

    private func logShapeOnce(_ shape: StreamCodecPolicy.FrameShape) {
        guard loggedShape != shape else { return }
        loggedShape = shape
        PrivacyLog.camera(.glasses, .frameShape,
                          detail: PrivacyToken(String(describing: shape)))
    }
}
