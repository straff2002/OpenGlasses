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
    /// Plan HW P1: a raw frame that could not be converted has been reported for this stream.
    /// Once is enough; the next thousand frames of the same stream would say the same thing.
    private var loggedUnconvertible = false
    /// Plan HW P1: every frame that stamped the sample clock, since this pipeline was created.
    /// `reset()` leaves it alone on purpose. The stall record asks "did anything arrive from the
    /// old stream before it was torn down", and it asks after the teardown has already reset
    /// everything else here.
    private var samplesSeen = 0

    /// Turn one delivered frame into the picture to publish, and say whether that picture is
    /// *fresh* — newly produced from this frame — or the last good one handed over again.
    ///
    /// The caller needs both: the app should keep seeing the last good image, but the photo-capture
    /// fallback must not treat a held frame as a recent view of the world.
    ///
    /// This is the only place an SDK frame is touched. Everything that decides anything is in
    /// `picture(helperImage:sampleBuffer:)`, which the tests can call with a sample buffer of
    /// their own making.
    func picture(for frame: VideoFrame) -> (image: UIImage?, isFresh: Bool) {
        picture(helperImage: frame.makeUIImage(), sampleBuffer: frame.sampleBuffer)
    }

    /// The shape is read from the frame itself rather than from the codec we asked for: a
    /// firmware that decodes for us produces a picture from the helper, and that must not be
    /// decoded a second time.
    func picture(helperImage: UIImage?,
                 sampleBuffer: CMSampleBuffer) -> (image: UIImage?, isFresh: Bool) {
        let shape = StreamCodecPolicy.shape(
            helperProducedImage: helperImage != nil,
            hasDataBuffer: CMSampleBufferGetDataBuffer(sampleBuffer) != nil,
            hasImageBuffer: CMSampleBufferGetImageBuffer(sampleBuffer) != nil)

        lock.lock()
        defer { lock.unlock() }

        logShapeOnce(shape)

        switch StreamCodecPolicy.action(for: shape) {
        case .emit:
            // A picture implies a sample, so this refreshes both clocks.
            liveness.pictureProduced()
            samplesSeen += 1
            return (helperImage, true)
        case .decode:
            liveness.sampleArrived()
            samplesSeen += 1
            let decoded = decoder.image(for: sampleBuffer)
            if decoded.producedFreshPicture {
                liveness.pictureProduced()
            } else {
                // A held last-good frame is not a picture: it must not refresh either clock, or
                // a decoder stuck waiting for a keyframe would read as a healthy stream.
                liveness.heldFrameDelivered()
            }
            return (decoded.image, decoded.producedFreshPicture)
        case .convert:
            // Plan HW P1. The pixels are here and the helper could not draw them, which is what
            // a raw stream looks like with the phone locked. Drawing them on the CPU makes this
            // frame a picture like any other, clocks included. Before this the frame was an
            // `.empty` one: dropped, neither clock stamped, and so a raw stream under lock read
            // as a dead link and was rebuilt until recovery gave up.
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return (nil, false)
            }
            switch PixelBufferImageConverter.convert(pixelBuffer) {
            case .image(let image):
                liveness.pictureProduced()
                samplesSeen += 1
                return (image, true)
            case .unsupportedFormat(let format):
                // Exactly a `.drop`: pixels nobody can show are no more evidence of a working
                // stream than no pixels, and the reasoning below applies unchanged.
                logUnconvertibleOnce(.unsupportedPixelFormat, format: format)
                return (nil, false)
            case .failed(let format):
                logUnconvertibleOnce(.pixelConversionFailed, format: format)
                return (nil, false)
            }
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

    /// How long the link has been quiet, for the stall record: since the last sample, or since
    /// the clocks last (re)started when nothing has arrived yet.
    func secondsSinceLastSample(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return liveness.secondsSinceLastSample(now: now)
    }

    /// How many frames have stamped the sample clock since this pipeline was created. Never
    /// goes down and survives `reset()`; two readings subtract to "what arrived in between".
    var lifetimeSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samplesSeen
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

    /// A stream teardown. The decoder goes with it, and the next stream logs its own shape and
    /// its own keyframe evidence.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        decoder.resetForNewStream()
        liveness.restart()
        loggedShape = nil
        loggedUnconvertible = false
    }

    private func logShapeOnce(_ shape: StreamCodecPolicy.FrameShape) {
        guard loggedShape != shape else { return }
        loggedShape = shape
        PrivacyLog.camera(.glasses, .frameShape,
                          detail: PrivacyToken(String(describing: shape)))
    }

    /// The format is named so the device session reads which one the glasses sent rather than
    /// guessing: a four-character code, or its number in hex when the code is not text.
    private func logUnconvertibleOnce(_ event: PrivacyLog.CameraEvent, format: OSType) {
        guard !loggedUnconvertible else { return }
        loggedUnconvertible = true
        PrivacyLog.camera(.glasses, event,
                          detail: PrivacyToken(PixelBufferImageConverter.name(ofFormat: format)))
    }
}
