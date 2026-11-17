import SwiftUI

/// The glasses' battery, drawn as the ring of the session card's status mark.
///
/// While there is a reading the ring is the battery and nothing else: how far round it runs is the
/// level, and its colour is the charge — green, red when low, with a bolt while charging. The
/// session's state stays on the mark's wash and glyph. With no live reading — no glasses
/// connected, a phone-only build, a pair that does not report a level — there is no value at all,
/// and the mark keeps the plain full ring, in the session's hue, that it has always had.
///
/// Pure, so the rules are tested headless (`GlassesBatteryRingTests`); `StatusMarkRing` draws it.
struct GlassesBatteryRing: Equatable, Sendable {
    /// At or below this, and not charging, the arc turns red, the way iOS's own battery ring does.
    /// The same 20 % the widget treats as a level worth redrawing for
    /// (`WidgetGlassesPresentation.batteryThresholds`).
    static let lowPercent = 20

    /// 0...100.
    let percent: Int
    let isCharging: Bool

    /// The ring for a reading, or nil when there is none to show. `level` is
    /// `GlassesConnectionService.batteryLevel`, which is already nil unless the link is up;
    /// `connected` is asked as well, so a level can never outlive the link on this card.
    static func reading(level: Int?, isCharging: Bool, connected: Bool) -> GlassesBatteryRing? {
        guard connected, let level else { return nil }
        return GlassesBatteryRing(percent: min(max(level, 0), 100), isCharging: isCharging)
    }

    /// How far round the ring the arc runs, 0...1.
    var fraction: Double { Double(percent) / 100 }

    /// Low, and not already being fixed: charging glasses are not drawn as a warning.
    var isLow: Bool { !isCharging && percent <= Self.lowPercent }

    /// The arc's colour, from the charge alone.
    enum ArcTint: Equatable, Sendable { case charged, low }
    var arcTint: ArcTint { isLow ? .low : .charged }

    var accessibilityLabel: String { String(localized: "Glasses battery") }

    /// "64%", or "64%, charging". The level is said, not coloured, so a low battery needs no word
    /// of its own.
    var accessibilityValue: String {
        let level = percent.formatted(.percent)
        return isCharging ? level + String(localized: ", charging") : level
    }
}

/// The status mark's hue while the session is at rest: nothing listening, speaking, connecting or
/// failed. Grey on its own; green while glasses are connected, so the mark says at a glance that
/// the pair is on. Every other state keeps its own hue, which is what the mark exists to show.
enum StatusMarkRestTint: Equatable, Sendable {
    case glassesConnected
    case inactive

    static func tint(glassesConnected: Bool) -> StatusMarkRestTint {
        glassesConnected ? .glassesConnected : .inactive
    }

    var color: Color {
        switch self {
        case .glassesConnected: return OGTheme.ok
        case .inactive: return OGTheme.inactive
        }
    }
}

/// The status mark's ring. Observes the glasses service itself, so a battery change redraws the
/// ring alone rather than the whole session card.
struct StatusMarkRing: View {
    @ObservedObject var glasses: GlassesConnectionService
    /// The session state's hue — the ring's colour while there is no battery to show.
    let color: Color

    /// Thicker than the plain ring: a 2pt arc of a few percent is too short to read.
    @ScaledMetric(relativeTo: .body) private var arcWidth: CGFloat = 3
    @ScaledMetric(relativeTo: .caption2) private var boltBadge: CGFloat = 17

    private var battery: GlassesBatteryRing? {
        GlassesBatteryRing.reading(level: glasses.batteryLevel, isCharging: glasses.isCharging,
                                   connected: glasses.isConnected)
    }

    var body: some View {
        if let battery {
            let width = min(arcWidth, 4.5)
            ZStack {
                // The track: the whole ring, faint and neutral, so the arc reads as a share of it.
                Circle()
                    .strokeBorder(OGTheme.inactive.opacity(0.25), lineWidth: width)
                Circle()
                    .inset(by: width / 2)
                    .trim(from: 0, to: battery.fraction)
                    .stroke(arcColor(battery.arcTint),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    // From twelve o'clock, clockwise, like the system's battery rings.
                    .rotationEffect(.degrees(-90))
            }
            .overlay(alignment: .bottomTrailing) {
                if battery.isCharging { bolt }
            }
            .accessibilityElement(children: .ignore)
            // Read-only, and said so (see the mode pill): an element with no traits is audited as
            // something to tap.
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(battery.accessibilityLabel)
            .accessibilityValue(battery.accessibilityValue)
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            Circle()
                .strokeBorder(color.opacity(0.55), lineWidth: 2)
                .accessibilityHidden(true)
        }
    }

    private func arcColor(_ tint: GlassesBatteryRing.ArcTint) -> Color {
        switch tint {
        case .charged: return OGTheme.ok
        case .low: return OGTheme.error
        }
    }

    private var bolt: some View {
        let side = min(boltBadge, 17 * 1.5)
        return Image(systemName: "bolt.fill")
            .font(.system(size: side * 0.55, weight: .bold))
            .foregroundStyle(OGTheme.okLabel)
            .frame(width: side, height: side)
            .background(Color(.systemBackground), in: .circle)
            .offset(x: side * 0.2, y: side * 0.2)
            .accessibilityHidden(true)
    }
}
