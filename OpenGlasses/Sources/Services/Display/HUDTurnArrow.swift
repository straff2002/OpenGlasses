import CoreGraphics
import Foundation
import UIKit

/// Plan KX §6 (Plan CA on the lens): the turn arrow, drawn on the phone and sent with the walking
/// route's guidance line through KV's `HUDPicture` path.
///
/// **What it draws.** A white arrow on black — black is clear on the additive lens, so the wearer
/// sees only the arrow — pointing the way the maneuver turns: straight up for ahead (and for the
/// walk's start, whose own words say which way to head), 45° for a bear left or right, 90° for a
/// turn, straight down for a U-turn. A roundabout (which exit is in the words, not the geometry)
/// and the arrival have no direction, so they draw nothing and the line goes alone, as today.
///
/// **The strip.** The arrow sits in a `arrowSide` (120 px) square at the start of a `stripWidth`
/// (552 px) × 120 px strip, the rest black. A strip rather than a 120 px square for the reason
/// `HUDAnswerThumbnail` gives: DAT's only non-icon image preset is `.fill`, which sizes the image
/// to the column, so a 120 px square would come back 552 px tall. The strip draws at its own size
/// in the column, the arrow under the start of the text. It is drawn above the guidance line
/// (`HUDPicture.Placement.aboveLines`), so the arrow leads.
///
/// **The key.** `contentKey` names the angle only (`kx.nav.arrow:<degrees>`), so a line whose
/// distance changed redraws, but the render queue's de-duplication still skips a frame that is the
/// same arrow and the same words. Pictures are drawn once per angle and kept.
enum HUDTurnArrow {
    static let stripWidth: CGFloat = 552
    static let arrowSide: CGFloat = 120
    static var canvas: CGSize { CGSize(width: stripWidth, height: arrowSide) }

    /// Degrees clockwise from straight ahead, or nil when the maneuver has no direction to draw.
    static func angle(for maneuver: Maneuver) -> Double? {
        switch maneuver {
        case .depart, .continueStraight: return 0
        case .slightLeft: return -45
        case .slightRight: return 45
        case .turnLeft: return -90
        case .turnRight: return 90
        case .uTurn: return 180
        case .roundabout, .arrive: return nil
        }
    }

    static func contentKey(angle: Double) -> String {
        "kx.nav.arrow:\(Int(angle.rounded()))"
    }

    /// The arrow for `maneuver` as a lens picture, or nil when it has no direction.
    @MainActor
    static func picture(for maneuver: Maneuver) -> HUDPicture? {
        guard let angle = angle(for: maneuver) else { return nil }
        let key = contentKey(angle: angle)
        if let cached = cache[key] { return cached }
        let picture = HUDPicture(image: draw(angle: angle), pixelSize: canvas, contentKey: key,
                                 placement: .aboveLines)
        cache[key] = picture
        return picture
    }

    @MainActor private static var cache: [String: HUDPicture] = [:]

    /// The arrow's outline, pointing up, in a unit square centred on the origin (y grows down).
    static let outline: [CGPoint] = [
        CGPoint(x: 0, y: -0.42),      // tip
        CGPoint(x: 0.34, y: -0.04),
        CGPoint(x: 0.13, y: -0.04),
        CGPoint(x: 0.13, y: 0.42),
        CGPoint(x: -0.13, y: 0.42),
        CGPoint(x: -0.13, y: -0.04),
        CGPoint(x: -0.34, y: -0.04),
    ]

    /// The outline turned `angle` degrees clockwise and placed in the strip's arrow square.
    static func points(angle: Double) -> [CGPoint] {
        let radians = angle * .pi / 180
        let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
        let centre = CGPoint(x: arrowSide / 2, y: arrowSide / 2)
        return outline.map { p in
            let x = p.x * c - p.y * s
            let y = p.x * s + p.y * c
            return CGPoint(x: centre.x + x * arrowSide, y: centre.y + y * arrowSide)
        }
    }

    /// Draw the strip: black, with the white arrow at `angle`. One pixel per point.
    static func draw(angle: Double) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(origin: .zero, size: canvas))
            let points = points(angle: angle)
            guard let first = points.first else { return }
            cg.beginPath()
            cg.move(to: first)
            for point in points.dropFirst() { cg.addLine(to: point) }
            cg.closePath()
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
        }
    }
}

/// Plan KX §6: whether the guidance line may carry its arrow now. "Text alone when the link is
/// slow": a picture send that failed, timed out, went again without its picture, or took longer
/// than `slowSend` puts the arrow off for `cooldown`; the line still goes, as text. "No more than
/// once a second" is the send pump's own rule (`HUDSendPacer.pictureGap`): a frame after a picture
/// waits a second, latest wins. Pure.
struct HUDGuidancePicturePolicy: Equatable {
    /// A picture send slower than this reads as a slow link (the survey's 552 px image took ~155 ms).
    static let slowSend = 1_000
    /// How long a slow link keeps the arrow off.
    static let cooldown: TimeInterval = 30

    private(set) var offUntil: Date?
    /// The last send the policy has read, so the same record is not counted twice.
    private var lastRead: HUDSendRecord?

    /// Read the send pump's last record at `now`.
    mutating func note(_ record: HUDSendRecord?, at now: Date) {
        guard let record, record != lastRead else { return }
        lastRead = record
        guard record.kind == .picture else { return }
        if record.outcome != .sent || record.milliseconds > Self.slowSend {
            offUntil = now.addingTimeInterval(Self.cooldown)
        }
    }

    /// Whether the arrow may go at `now`.
    func allows(at now: Date) -> Bool {
        guard let offUntil else { return true }
        return now >= offUntil
    }
}
