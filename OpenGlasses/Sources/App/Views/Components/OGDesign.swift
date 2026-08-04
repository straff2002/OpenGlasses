import SwiftUI

// OGDesign — the OpenGlasses design language, in one place (Plan CL).
//
// Rules the primitives enforce:
//   * ONE accent per screen. Everything tints from the environment accent
//     (`\.appAccent`), so the user's chosen preset applies everywhere.
//     Status semantics (ok/warn/error) appear only as small dots — never
//     as per-row icon colours.
//   * Warm neutrals. A slightly warm canvas and card fill in both schemes,
//     not stark systemGroupedBackground grey.
//   * Grouped cards: 22pt continuous corners, hairline dividers, 52pt rows.
//   * Semantic type only (.body / .footnote / …) so Dynamic Type works.
//   * Liquid Glass is reserved for chrome (hero card, floating bars) —
//     scrolling list content uses flat card fills so it stays calm.
//
// Everything here is presentation only — no view models, no state.

// MARK: - Palette

enum OGTheme {
    /// Adaptive pair helper: most tokens carry explicit light/dark values
    /// rather than relying on system semantic colours (which are cool-grey).
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    /// Screen background — warm off-white in light, warm near-black in dark.
    static let canvas = adaptive(light: 0xF5F3F0, dark: 0x151413)
    /// Card / row fill, one step above the canvas.
    static let card = adaptive(light: 0xFFFFFF, dark: 0x201E1C)
    /// Hero-card chrome, always dark — the accent glow carries the warmth.
    static let ink = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x1A / 255)
    /// Text on ink.
    static let onInk = Color(red: 0xF5 / 255, green: 0xF2 / 255, blue: 0xEE / 255)
    /// Hairline between rows inside a card.
    static let hairline = adaptive(light: 0x3C3C43, dark: 0xF5F2EE).opacity(0.12)

    // Status dots only — never row-icon tints.
    static let ok = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let warn = Color.orange
    static let error = Color(red: 0xE0 / 255, green: 0x30 / 255, blue: 0x26 / 255)
}

// MARK: - Containers

/// A grouped card: warm fill, 22pt continuous corners. Rows go inside,
/// separated by `OGDivider`.
struct OGCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(
                OGTheme.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Hairline between rows inside a card.
struct OGDivider: View {
    var body: some View {
        Rectangle()
            .fill(OGTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 57)   // clears the icon tile so text edges align
    }
}

/// Section = uppercase caption + card + optional footer, the unit hub
/// pages repeat.
struct OGSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header.uppercased())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            OGCard(content: content)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }
        }
    }
}

/// A hub page: warm canvas, stacked `OGSection`s.
struct OGScrollPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22, content: content)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 44)
        }
        .background(OGTheme.canvas.ignoresSafeArea())
    }
}

// MARK: - Row furniture

/// The one-accent row icon: an accent-tinted tile. `muted` for
/// power-user / destructive-adjacent rows that shouldn't pull the eye.
struct OGIconTile: View {
    let systemName: String
    var muted: Bool = false
    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(muted ? Color.primary.opacity(0.08) : accent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(muted ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(accent))
            }
    }
}

/// A card row: icon tile, title (+ optional subtitle), trailing value,
/// chevron. 52pt floor so one-line rows are uniform and wrapped
/// subtitles still breathe.
struct OGRow<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    var mutedIcon: Bool = false
    var subtitle: String? = nil
    var showsChevron: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                OGIconTile(systemName: icon, muted: mutedIcon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

extension OGRow {
    /// Unlabeled-title form with custom trailing content, so call sites read
    /// the same whether the trailing view is a value label or a control.
    init(
        _ title: String,
        icon: String? = nil,
        mutedIcon: Bool = false,
        subtitle: String? = nil,
        showsChevron: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
            showsChevron: showsChevron, trailing: trailing
        )
    }
}

extension OGRow where Trailing == OGRowValue {
    init(
        _ title: String,
        icon: String? = nil,
        mutedIcon: Bool = false,
        subtitle: String? = nil,
        value: String? = nil,
        showsChevron: Bool = true
    ) {
        self.init(
            title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
            showsChevron: showsChevron,
            trailing: { OGRowValue(value: value) }
        )
    }
}

/// Trailing summary on a row ("Claude Sonnet", "On", "iPhone").
struct OGRowValue: View {
    let value: String?

    var body: some View {
        if let value {
            Text(value)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Chips, badges & pills

/// Capability chip: accent-tinted when available, grey when absent.
struct OGChip: View {
    let text: String
    var available: Bool = true
    @Environment(\.appAccent) private var accent

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(available ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                available ? accent.opacity(0.14) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

/// Uppercase state badge ("BETA", "OWNER").
struct OGBadge: View {
    let text: String
    var prominent: Bool = false
    @Environment(\.appAccent) private var accent

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .kerning(0.4)
            .foregroundStyle(prominent ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                prominent ? accent.opacity(0.14) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}

/// Status capsule with a state dot — "Glasses · 82%".
struct OGStatusPill: View {
    let text: String
    var dot: Color? = nil
    var tinted: Bool = true
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tinted ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            tinted ? accent.opacity(0.12) : Color.secondary.opacity(0.12),
            in: Capsule()
        )
    }
}

/// Accent-tinted informational strip ("Stored on this iPhone only").
struct OGNotice: View {
    let text: String
    var systemImage: String = "lock"
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accent)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One number + caption, for compact stat rows.
struct OGStatTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Hero device card

/// Dark hero atop the Settings hub: device identity, live status, and
/// capability chips, under a soft accent glow. Chrome, so it earns glass.
struct OGHeroDeviceCard: View {
    let title: String
    let status: String
    var dot: Color = OGTheme.ok
    /// e.g. 82 — omitted when the firmware hasn't reported yet.
    var batteryPercent: Int? = nil
    var chips: [(label: String, available: Bool)] = []
    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(accent.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .foregroundStyle(accent)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OGTheme.onInk)
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(OGTheme.onInk.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let batteryPercent {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(batteryPercent))
                            .font(.footnote)
                        Text("\(batteryPercent)%")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(OGTheme.onInk.opacity(0.75))
                }
            }

            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.label) { chip in
                        Text(chip.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(chip.available ? accent : OGTheme.onInk.opacity(0.4))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                chip.available
                                    ? accent.opacity(0.22)
                                    : OGTheme.onInk.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background {
            // Ink base with a soft accent glow bleeding from the tile corner —
            // the same ambience language as the Voice tab, so the hero reads
            // as part of the same product.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OGTheme.ink)
                .overlay {
                    RadialGradient(
                        colors: [accent.opacity(0.28), .clear],
                        center: .topLeading, startRadius: 0, endRadius: 240
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Form adoption

private struct OGFormStyle: ViewModifier {
    @Environment(\.appAccent) private var accent

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(OGTheme.canvas.ignoresSafeArea())
            .tint(accent)
    }
}

extension View {
    /// Stock `Form`/`List` screens keep their controls but pick up the warm
    /// canvas and accent tint, so a sub-page never flashes cool iOS grey
    /// against the hub.
    func ogFormStyle() -> some View {
        modifier(OGFormStyle())
    }
}
