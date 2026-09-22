import CoreGraphics
import Foundation

/// How big the pictures in the work order are allowed to be (Plan FO P2a).
///
/// A job with thirty photos on it is not unusual, and a full-resolution glasses still is a couple of
/// megabytes. Rendered as they are, that PDF is somewhere north of sixty megabytes: too big for the
/// mail composer, too big for most job systems, and too big for a technician on a plant-room LTE
/// signal. The full-size originals have their own route — the share sheet — so what the PDF needs is
/// the smallest copy a customer can still see the fault in.
///
/// **Deterministic and pure.** The same photo count always yields the same long edge and the same
/// JPEG quality, so re-sending a past job reproduces the same file rather than a differently
/// compressed one. No device state, no measurement of the actual images: the ladder is fixed and the
/// estimate is arithmetic, which is what makes "does a thirty-photo job still fit?" a test rather
/// than a hope.
struct EvidenceImageBudget: Equatable {

    /// One rung: how long the longest edge may be, and at what JPEG quality.
    struct Tier: Equatable {
        let longEdge: CGFloat
        let quality: CGFloat
    }

    /// What the whole picture set may add up to, before the rest of the document.
    let totalByteCeiling: Int
    /// Largest first. The chosen rung is the biggest one that fits the per-photo share.
    let tiers: [Tier]

    /// Six megabytes of pictures. Chosen against the constraint that actually bites — a mail
    /// attachment a phone will send over a mobile connection — rather than against any format
    /// limit, and low enough that the JSON, the transcript and the record still leave the composer
    /// with room.
    static let standard = EvidenceImageBudget(
        totalByteCeiling: 6_000_000,
        tiers: [
            Tier(longEdge: 1_600, quality: 0.75),
            Tier(longEdge: 1_280, quality: 0.70),
            Tier(longEdge: 1_024, quality: 0.65),
            Tier(longEdge: 800, quality: 0.60),
            Tier(longEdge: 640, quality: 0.50),
            // The floor. Below this a gauge face stops being readable, which would make the
            // picture worthless rather than merely small — so a job with a truly absurd number of
            // photos produces a larger file, honestly, instead of illegible evidence.
            Tier(longEdge: 480, quality: 0.40),
        ])

    /// What the renderer is told to do for a given number of pictures.
    struct Plan: Equatable {
        let photoCount: Int
        let longEdge: CGFloat
        let quality: CGFloat
        /// What one picture is expected to cost, by the estimate below.
        let estimatedBytesPerPhoto: Int
        /// Whether the plan had to stop at the floor rung and may exceed the ceiling.
        let atFloor: Bool

        var estimatedTotalBytes: Int { estimatedBytesPerPhoto * photoCount }

        /// The size to draw an image at, fitted inside `box` and never enlarged past the plan's
        /// long edge. Aspect ratio is preserved; a picture is never stretched to fill a slot.
        func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
            guard size.width > 0, size.height > 0 else { return .zero }
            let longest = max(size.width, size.height)
            let capped = longest > longEdge ? longEdge / longest : 1
            let scaled = CGSize(width: size.width * capped, height: size.height * capped)
            let fit = min(box.width / scaled.width, box.height / scaled.height, 1)
            return CGSize(width: scaled.width * fit, height: scaled.height * fit)
        }
    }

    /// The rung a job of this size gets.
    func plan(photoCount: Int) -> Plan {
        let count = max(0, photoCount)
        guard count > 0, let floor = tiers.last else {
            let tier = tiers.first ?? Tier(longEdge: 1_024, quality: 0.65)
            return Plan(photoCount: count, longEdge: tier.longEdge, quality: tier.quality,
                        estimatedBytesPerPhoto: Self.estimatedBytes(tier), atFloor: false)
        }
        let share = totalByteCeiling / count
        for tier in tiers where Self.estimatedBytes(tier) <= share {
            return Plan(photoCount: count, longEdge: tier.longEdge, quality: tier.quality,
                        estimatedBytesPerPhoto: Self.estimatedBytes(tier), atFloor: false)
        }
        return Plan(photoCount: count, longEdge: floor.longEdge, quality: floor.quality,
                    estimatedBytesPerPhoto: Self.estimatedBytes(floor), atFloor: true)
    }

    /// What a JPEG of that shape costs, near enough to choose a rung with.
    ///
    /// A 4:3 frame and a linear relationship between quality and bytes per pixel. Both are
    /// approximations — a photograph of a plain white panel compresses far smaller than one of a
    /// coil — but they are *monotone* in both arguments, which is the only property the ladder
    /// needs: a smaller rung must never be estimated larger than a bigger one.
    static func estimatedBytes(_ tier: Tier) -> Int {
        let pixels = tier.longEdge * (tier.longEdge * 0.75)
        return Int((pixels * (0.06 + 0.30 * tier.quality)).rounded())
    }
}
