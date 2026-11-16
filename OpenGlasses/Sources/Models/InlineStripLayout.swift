import CoreGraphics

/// The tap targets in the bottom strip while it sits shrunk beside the Avenkin mark (Plan MC).
///
/// iOS draws that pill and sets its size: it fills the row beside the shrunk tab bar, and SwiftUI can
/// change only what is inside it. So the pill cannot hug its controls. Instead the controls keep to
/// its trailing end, as they always have, and their targets are made easy to hit:
///
/// - **as tall as the pill allows**, so a tap a little high or low still lands;
/// - **wider than they are tall**, for a thumb coming in from the side;
/// - **edge to edge**, so a tap between two controls goes to the nearer one, not to nothing;
/// - **one border on every side** — the same gap above, below and at the trailing end — which is
///   what makes the borders read as even, whatever height the system gives the pill.
///
/// Pure over the pill's size and the number of controls, so it is tested headless; the view reads
/// the pill's size and places each target from here. Right to left needs nothing of its own: the
/// row is an `HStack` aligned to the trailing edge, which SwiftUI mirrors.
struct InlineStripLayout: Equatable {
    /// The width a target gets when the pill has room for it.
    static let preferredTargetWidth: CGFloat = 60
    /// The gap between a target and the pill's edge, when the pill is tall enough to spare it.
    static let preferredBorder: CGFloat = 4
    /// No target is smaller than this either way.
    static let minimumTarget: CGFloat = 44
    /// The pill before its first measurement arrives: a 6.1″ phone's, near enough for one frame.
    static let unmeasuredPill = CGSize(width: 280, height: 50)

    /// Every target's size; they share one.
    let targetSize: CGSize
    /// The gap above, below and at the trailing end.
    let border: CGFloat
    /// How many targets sit in the row.
    let count: Int

    /// The width the targets and their trailing border take from the pill's trailing edge.
    var occupiedWidth: CGFloat { CGFloat(count) * targetSize.width + border }

    /// The layout for `count` controls in a pill of `pill`'s size.
    static func make(pill: CGSize, count: Int) -> InlineStripLayout {
        let count = max(0, count)
        // The border gives way first: a pill too short to spare it all keeps the targets at the
        // floor instead.
        let border = min(preferredBorder, max(0, (pill.height - minimumTarget) / 2))
        let height = max(minimumTarget, pill.height - 2 * border)
        // Then the width: on a pill too narrow for the preferred width (the smallest phones at the
        // largest text sizes), the targets narrow — never under the floor — rather than run past
        // the pill's leading edge.
        let room = pill.width - 2 * border
        let fitted = count > 0 ? room / CGFloat(count) : preferredTargetWidth
        let width = max(minimumTarget, min(preferredTargetWidth, fitted))
        return InlineStripLayout(targetSize: CGSize(width: width, height: height), border: border, count: count)
    }

    /// Each target's frame in the pill, leading to trailing, in left-to-right coordinates.
    func frames(in pill: CGSize) -> [CGRect] {
        (0..<count).map { index in
            let fromTrailing = CGFloat(count - index)
            return CGRect(x: pill.width - border - fromTrailing * targetSize.width,
                          y: border,
                          width: targetSize.width,
                          height: targetSize.height)
        }
    }
}
