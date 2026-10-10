import Foundation

/// Plan HW P1 — what a stream actually delivered in its first thirty seconds (pure).
///
/// The size of the pictures the app received and how many arrived each second, measured rather
/// than read off the tier that was asked for. These go in the log and the support report beside
/// the link level and are **never turned into one**: nothing we have ties a size or a rate to a
/// radio. The one field measurement to hand had Bluetooth Classic carrying 29 to 32 pictures a
/// second at 504×896, which is as good as anyone would have guessed Wi-Fi to be.
struct StreamDeliveryMeter: Equatable {

    /// How much of a stream is measured. Long enough to be past the warmup and any first step
    /// of the SDK's own ladder, short enough that a support report sent a minute in has it.
    static let window: TimeInterval = 30

    struct Facts: Equatable {
        /// The size of the last picture inside the window, in pixels. The SDK may step the source
        /// down mid-stream, and the size it settled on is the one worth knowing.
        let width: Int
        let height: Int
        /// Pictures per second, averaged from the first picture to the end of the window. The
        /// wait for that first picture is a warmup, not a rate; a stall after it is part of what
        /// was delivered and does lower the figure.
        let framesPerSecond: Double
    }

    private var startedAt: Date?
    private var firstPictureAt: Date?
    private var pictures = 0
    private var width = 0
    private var height = 0

    /// A stream started streaming: measure from here.
    mutating func restart(at now: Date) {
        self = StreamDeliveryMeter()
        startedAt = now
    }

    /// A fresh picture reached the app. Pictures after the window has closed are not counted,
    /// so the facts stop moving once they have been given.
    mutating func pictureDelivered(width: Int, height: Int, at now: Date) {
        guard let startedAt, now >= startedAt,
              now.timeIntervalSince(startedAt) <= Self.window else { return }
        if firstPictureAt == nil { firstPictureAt = now }
        pictures += 1
        self.width = width
        self.height = height
    }

    /// Nil until the window has passed, and nil for a stream that delivered nothing in it.
    func facts(now: Date) -> Facts? {
        guard let startedAt, let firstPictureAt, pictures > 0,
              now.timeIntervalSince(startedAt) >= Self.window else { return nil }
        let measured = startedAt.addingTimeInterval(Self.window).timeIntervalSince(firstPictureAt)
        guard measured > 0 else { return nil }
        return Facts(width: width, height: height, framesPerSecond: Double(pictures) / measured)
    }
}
