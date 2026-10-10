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

    /// How long a (re)started clock may wait for its *first* sample, and its first picture, before
    /// the silence counts as a stall.
    ///
    /// `stallThreshold` is a gap *between* frames, and it is the wrong question to ask of a stream
    /// that has not delivered anything yet. Device-traced 2026-09-25 (hvc1, high tier): the first
    /// sample landed ~1.3 s after `.streaming` on the one rebuild that got through, and the others
    /// were declared stalled at 1.5 s having delivered nothing. Every one of those rebuilds
    /// restarted a ~7 s warmup, so the detector kept the camera in a loop it had caused itself.
    /// The same grace covers a rebuilt decoder, which holds every sample until the next keyframe:
    /// judged at 1.5 s, an encoder whose keyframe interval is longer than that would never get one
    /// through.
    static let firstFrameGrace: TimeInterval = 5

    private(set) var lastSample: Date
    private(set) var lastPicture: Date
    /// Whether anything has arrived since the clocks last (re)started. Until it has, the clock is
    /// judged against `firstFrameGrace` rather than `stallThreshold`.
    private(set) var sawSampleSinceRestart = false
    private(set) var sawPictureSinceRestart = false

    init(now: Date = Date()) {
        lastSample = now
        lastPicture = now
    }

    /// Both clocks start again — used when a stream (re)starts, so a warmup is not read as a
    /// stall the instant the detector arms. Each clock is back on its first-frame grace.
    mutating func restart(at now: Date = Date()) {
        lastSample = now
        lastPicture = now
        sawSampleSinceRestart = false
        sawPictureSinceRestart = false
    }

    /// A frame arrived from the SDK, whatever shape it turned out to be.
    mutating func sampleArrived(at now: Date = Date()) {
        lastSample = now
        sawSampleSinceRestart = true
    }

    /// A picture was actually produced — the helper's image, or a freshly decoded one. A picture
    /// implies a sample, so it refreshes both clocks; that is what keeps a raw stream (which
    /// never reports samples separately) reading as healthy.
    mutating func pictureProduced(at now: Date = Date()) {
        lastSample = now
        lastPicture = now
        sawSampleSinceRestart = true
        sawPictureSinceRestart = true
    }

    /// The app was handed the *previous* picture again because the decoder is holding. Refreshes
    /// nothing, deliberately: this method exists so the call site says so out loud rather than
    /// silently omitting a stamp.
    mutating func heldFrameDelivered() {}

    func verdict(now: Date = Date()) -> Verdict {
        let sampleLimit = sawSampleSinceRestart ? Self.stallThreshold : Self.firstFrameGrace
        let pictureLimit = sawPictureSinceRestart ? Self.stallThreshold : Self.firstFrameGrace
        if now.timeIntervalSince(lastSample) > sampleLimit { return .linkStalled }
        if now.timeIntervalSince(lastPicture) > pictureLimit { return .decodeStalled }
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
///
/// Plan HW P0 — what counts as a keyframe is read from the video (`NALUnitInspector`), and the
/// sample's `NotSync` attachment is only asked when the video cannot be read. Three rules follow
/// from reading it properly.
///
/// **Leading pictures.** An HEVC stream may be entered at a CRA picture (or a BLA_W_LP), and the
/// pictures that follow it in the stream but precede it on screen come in two kinds. RASL pictures
/// may reference pictures from before the entry point, which a decoder that started there never
/// saw; they are withheld, and the last good picture stays up. RADL pictures reference nothing
/// from before it and pass. The two may be interleaved, so the rule stays in force until the
/// first picture that is neither: a trailing picture, or the next random-access point. A decoder
/// that met the same CRA mid-stream has the references, and its RASL pictures are ordinary frames.
///
/// **Patience.** Before this, the hold almost certainly never held on the glasses stream: an
/// absent attachment read as "keyframe" and the first sample went through. Reading the video makes
/// it hold for real, and that is only safe if the stream contains pictures this parser recognises
/// as places to start. One that refreshes gradually instead, with no such picture ever sent, would
/// be held forever: a black camera, on hardware nobody can test without wearing it. So the hold
/// counts the readable samples it has refused. The count survives `rearm()`, because the stall
/// detector rebuilds a waiting decoder every few seconds and would otherwise restart it each time.
/// At `patience` the hold stops believing the parser about this stream and lets the attachment
/// decide, which is exactly the behaviour that shipped before. Only a random-access picture
/// actually arriving restores the parser's standing.
struct KeyframeHold {

    /// Readable samples refused, across rebuilds, before the hold gives up on the parser. The one
    /// field measurement to hand is a random-access picture every 45 samples (3 s at 15 fps), so
    /// 240 is more than five of those, and 8 s of a 30 fps stream.
    static let patience = 240

    /// True from creation until the first keyframe clears it.
    private(set) var isHolding = true

    /// The hold was released by a picture whose RASL pictures this decoder cannot decode, and
    /// the leading pictures have not been seen to end yet.
    private(set) var isSkippingLeadingPictures = false

    /// Readable non-random-access samples refused while holding, since the last random-access
    /// picture was seen. Not reset by `rearm()`.
    private(set) var refusedWhileHolding = 0

    /// False once `patience` has run out, until a random-access picture is seen.
    private(set) var trustsParser = true

    /// Re-arm after invalidating or rebuilding a session.
    mutating func rearm() {
        isHolding = true
        isSkippingLeadingPictures = false
    }

    /// Whether this sample may reach the decoder, by the attachment alone. A keyframe both
    /// passes and ends the hold. This is the rule for a sample the parser could not read.
    mutating func admits(keyframe: Bool) -> Bool {
        admits(.unparseable, attachmentSaysKeyframe: keyframe)
    }

    /// Whether this sample may reach the decoder. `kind` is what the video says the sample is;
    /// `attachmentSaysKeyframe` is what the old rule would have said (no `NotSync`, or none at
    /// all, reads as a keyframe).
    mutating func admits(_ kind: NALUnitInspector.PictureKind,
                         attachmentSaysKeyframe: Bool) -> Bool {
        if case .randomAccess(_, let leadingMayBeUndecodable) = kind {
            // The stream has pictures the parser recognises after all.
            refusedWhileHolding = 0
            trustsParser = true
            // Only a decoder that *starts* here lacks the references its RASL pictures want.
            isSkippingLeadingPictures = isHolding && leadingMayBeUndecodable
            isHolding = false
            return true
        }

        guard isHolding else {
            guard isSkippingLeadingPictures else { return true }
            switch kind {
            case .leadingSkipped:
                return false
            case .leadingDecodable, .unparseable:
                // A RADL may sit between two RASLs, and a sample that cannot be read says
                // nothing about whether the leading pictures have ended. Both pass; neither
                // ends the rule.
                return true
            case .nonRandomAccess, .randomAccess:
                isSkippingLeadingPictures = false
                return true
            }
        }

        switch kind {
        case .randomAccess:
            return true   // handled above
        case .unparseable:
            break
        case .nonRandomAccess, .leadingSkipped, .leadingDecodable:
            if trustsParser {
                refusedWhileHolding += 1
                guard refusedWhileHolding >= Self.patience else { return false }
                trustsParser = false
            }
        }

        // The video could not be read, or patience has run out: the attachment decides.
        guard attachmentSaysKeyframe else { return false }
        isHolding = false
        return true
    }
}

/// Plan HW P0 — what one stream showed about where its keyframes can be read from (pure).
///
/// Two questions cannot be answered without glasses on a face: does this stream mark its
/// non-keyframes with the `NotSync` attachment at all, and how often does it send a picture a
/// decoder can start on. Each is answered by one log line per stream, and this is the bookkeeping
/// that decides when there is enough to say so. It returns what to log rather than logging, so
/// the rule can be tested without a log to read.
struct KeyframeEvidence {

    /// Which of the two sources turned out to be telling the truth about this stream.
    enum Source: String, Equatable {
        /// The parser found a non-keyframe the attachment would have called a keyframe. This is
        /// the field report confirmed: without the parser, the hold would not have held.
        case parser
        /// The parser cannot read this stream, so the attachment rule is what is in force.
        case attachment
        /// The parser found a non-keyframe and the attachment said `NotSync` too.
        case both
        /// The parser found a random-access picture the attachment marked `NotSync`.
        case disagree
    }

    enum Finding: Equatable {
        /// `samples` is how many had been seen when the answer became clear, and `notSync` is
        /// the attachment on the sample that settled it (nil: not there at all).
        case source(Source, samples: Int, notSync: Bool?)
        /// The second random-access picture of the stream arrived. `samples` is the distance
        /// from the first to it, which is the length of a group of pictures.
        case interval(samples: Int, pictureName: String, parameterSetsInBand: Bool)
    }

    /// Unreadable samples, with nothing decisive seen first, before the stream is called one the
    /// parser cannot read. Two seconds of a 15 fps stream.
    static let unparseableLimit = 30

    private(set) var samplesObserved = 0
    private var unparseableSeen = 0
    private var reportedSource = false
    private var firstRandomAccessSample: Int?
    private var reportedInterval = false

    /// A new stream: everything it shows is news again.
    mutating func reset() {
        self = KeyframeEvidence()
    }

    /// Takes one sample's readings and returns what, if anything, they settle. Each finding is
    /// returned once per stream. `parameterSetsInBand` matters only for a random-access sample.
    mutating func observe(_ kind: NALUnitInspector.PictureKind, notSync: Bool?,
                          parameterSetsInBand: Bool) -> [Finding] {
        samplesObserved += 1
        var findings: [Finding] = []

        if !reportedSource, let source = settledSource(kind, notSync: notSync) {
            reportedSource = true
            findings.append(.source(source, samples: samplesObserved, notSync: notSync))
        }

        if case .randomAccess(let nalType, _) = kind, !reportedInterval {
            if let first = firstRandomAccessSample {
                reportedInterval = true
                findings.append(.interval(
                    samples: samplesObserved - first,
                    pictureName: NALUnitInspector.randomAccessName(nalType: nalType),
                    parameterSetsInBand: parameterSetsInBand))
            } else {
                firstRandomAccessSample = samplesObserved
            }
        }

        return findings
    }

    /// A random-access picture with no `NotSync` settles nothing: both sources call it a
    /// keyframe, and they would whether or not the stream ever sets the attachment.
    private mutating func settledSource(_ kind: NALUnitInspector.PictureKind,
                                        notSync: Bool?) -> Source? {
        switch kind {
        case .nonRandomAccess, .leadingSkipped, .leadingDecodable:
            return notSync == true ? .both : .parser
        case .randomAccess:
            return notSync == true ? .disagree : nil
        case .unparseable:
            unparseableSeen += 1
            return unparseableSeen >= Self.unparseableLimit ? .attachment : nil
        }
    }
}
