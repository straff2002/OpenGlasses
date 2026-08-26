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
//   * Semantic type only (.body / .footnote / …) so Dynamic Type works, and
//     the metrics that sit *beside* type (row height, icon tile, divider
//     inset) scale with it via `@ScaledMetric`.
//   * Neutral washes come from the system fill colours, so a chip's "off"
//     ground is the same grey the rest of iOS uses.
//   * Liquid Glass is reserved for chrome (hero card, floating bars) —
//     scrolling list content uses flat card fills so it stays calm.
//   * Every primitive carries its own VoiceOver semantics: decoration is
//     hidden, text composes into one element, controls keep their name.
//
// The palette, opacity roles and derived accent colours live in
// `OGDesignTokens.swift`. Everything here is presentation only — no view
// models, no state.

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
    /// The icon tile, at the same scale `OGIconTile` draws it — the inset is
    /// the row's leading padding plus the tile plus the row's gutter, so the
    /// hairline keeps meeting the text edge at every Dynamic Type size rather
    /// than drifting past it.
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = OGMetrics.iconTile

    var body: some View {
        Rectangle()
            .fill(OGTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, OGMetrics.rowHorizontalPadding + tile + OGMetrics.rowSpacing)
            .accessibilityHidden(true)
    }
}

/// The fixed metrics `OGRow` and `OGDivider` share, so the hairline's inset is
/// derived from the row's own geometry instead of a copied constant.
enum OGMetrics {
    static let iconTile: CGFloat = 30
    static let rowSpacing: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 16
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
                    // Read the header as written; VoiceOver spells some
                    // all-caps words out letter by letter.
                    .accessibilityLabel(header)
                    .accessibilityAddTraits(.isHeader)
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
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = OGMetrics.iconTile

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(muted ? Color(.quaternarySystemFill) : accent.opacity(OGTheme.Opacity.accentFill))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        muted
                            ? AnyShapeStyle(Color.secondary)
                            : AnyShapeStyle(OGTheme.tintedAccentLabel(accent))
                    )
            }
            // The row title says what the row is; the glyph repeats it.
            .accessibilityHidden(true)
    }
}

/// A card row: icon tile, title (+ optional subtitle), trailing value,
/// chevron. 52pt floor so one-line rows are uniform and wrapped
/// subtitles still breathe — and comfortably past the 44pt touch minimum.
struct OGRow<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    var mutedIcon: Bool = false
    var subtitle: String? = nil
    var showsChevron: Bool = true
    /// Fold the trailing view into the row's single VoiceOver element. True for
    /// a plain value ("Model — Claude Sonnet" is one thought); false when the
    /// trailing view is a control, which has to stay its own focusable element.
    var combinesTrailing: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    @ScaledMetric(relativeTo: .body) private var minRowHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: OGMetrics.rowSpacing) {
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
            // Title and subtitle are one thought, not two stops.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, OGMetrics.rowHorizontalPadding)
        .padding(.vertical, 10)
        .frame(minHeight: minRowHeight)
        .contentShape(Rectangle())
        .modifier(OGRowAccessibility(combines: combinesTrailing, navigates: showsChevron))
    }
}

/// Applied as a modifier so the two shapes stay one code path: a value row
/// becomes a single element (and, when it carries the chevron affordance, a
/// button); a control row keeps its children focusable.
private struct OGRowAccessibility: ViewModifier {
    let combines: Bool
    let navigates: Bool

    func body(content: Content) -> some View {
        if combines {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(navigates ? .isButton : [])
        } else {
            content
        }
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
            showsChevron: showsChevron, combinesTrailing: false, trailing: trailing
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
            showsChevron: showsChevron, combinesTrailing: true,
            trailing: { OGRowValue(value: value) }
        )
    }
}

extension OGRow where Trailing == OGToggle {
    /// Switch row. Use this rather than dropping a bare `Toggle("")` into the
    /// trailing closure: an empty title plus `.labelsHidden()` reaches VoiceOver
    /// as an unnamed switch, and the row title never gets attached to it.
    init(
        _ title: String,
        isOn: Binding<Bool>,
        icon: String? = nil,
        mutedIcon: Bool = false,
        subtitle: String? = nil
    ) {
        self.init(
            title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
            showsChevron: false, combinesTrailing: false,
            trailing: { OGToggle(label: title, isOn: isOn) }
        )
    }
}

/// A row-hosted switch that keeps its name. `.labelsHidden()` hides the label
/// visually but leaves it in the accessibility tree — which is exactly what a
/// row-titled switch wants, provided the label was ever set.
struct OGToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
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
                // The audit reports this as text that may clip, and it is right — at large sizes
                // `“Openglasses”` and `System` are both cut. Removing the cap was tried and
                // rejected: the row is title + subtitle + value competing for one width, so a
                // wrapping value takes its second line straight out of the subtitle, and then out
                // of the title. Which of the three yields is a layout decision for the phase that
                // owns this component; the cap stays until then. See the plan's deferrals.
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

    /// Availability is carried by colour alone on screen; VoiceOver gets it in
    /// words. Pure, so the wording is covered by the suite.
    static func spokenLabel(text: String, available: Bool) -> String {
        available ? text : "\(text), unavailable"
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(
                available
                    ? AnyShapeStyle(OGTheme.tintedAccentLabel(accent))
                    : AnyShapeStyle(Color.secondary)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                available
                    ? accent.opacity(OGTheme.Opacity.accentFill)
                    : Color(.quaternarySystemFill),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .accessibilityLabel(Self.spokenLabel(text: text, available: available))
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
            .foregroundStyle(
                prominent
                    ? AnyShapeStyle(OGTheme.tintedAccentLabel(accent))
                    : AnyShapeStyle(Color.secondary)
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                prominent
                    ? accent.opacity(OGTheme.Opacity.accentFill)
                    : Color(.quaternarySystemFill),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            // As written, not as displayed — short all-caps words get spelled out.
            .accessibilityLabel(text)
    }
}

/// Status capsule with a state dot — "Glasses · 82%".
struct OGStatusPill: View {
    let text: String
    var dot: Color? = nil
    var tinted: Bool = true
    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 7

    /// VoiceOver reads the middot as "middle dot"; the pill means it as a
    /// separator. Pure, so the suite covers it.
    static func spokenLabel(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: ", ")
    }

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: dotSize, height: dotSize)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    tinted
                        ? AnyShapeStyle(OGTheme.tintedAccentLabel(accent))
                        : AnyShapeStyle(Color.secondary)
                )
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            tinted
                ? accent.opacity(OGTheme.Opacity.accentPillFill)
                : Color(.quaternarySystemFill),
            in: Capsule()
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(text))
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
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            accent.opacity(OGTheme.Opacity.accentNoticeFill),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
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
        // "Sessions, 12" rather than "12" then "Sessions" as separate stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(value)
    }
}

// MARK: - Discover

/// A capability the hub is offering rather than listing (Plan DE).
///
/// A *card*, not a row, because the two mean different things: a row is a
/// destination, a card is an offer. Tapping it does not navigate — it turns the
/// card into the row, permanently, with no gate of any kind. Nothing here locks,
/// prices, or asks; the pitch is the whole mechanism.
///
/// `suggestion` is the quiet contextual highlight: at most a handful of them
/// ever, phone-screen only, and dismissible. It is a sentence rather than a dot,
/// so it carries its meaning without colour and reads the same to VoiceOver.
struct OGDiscoverCard: View {
    let title: String
    /// The one-line pitch: what this is for, in the user's terms.
    let pitch: String
    let icon: String
    /// A contextual note explaining why this is being offered now, or nil.
    var suggestion: String? = nil
    let unfold: () -> Void
    var dismissSuggestion: (() -> Void)? = nil

    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var dismissTarget: CGFloat = 44

    /// The card as one spoken thought. Pure, so the wording is covered headlessly.
    static func spokenLabel(title: String, pitch: String, suggestion: String?) -> String {
        [title, pitch, suggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: unfold) {
                HStack(spacing: OGMetrics.rowSpacing) {
                    OGIconTile(systemName: icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pitch)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Self.spokenLabel(title: title, pitch: pitch, suggestion: suggestion)
            )
            .accessibilityHint("Shows \(title) in Settings")
            .accessibilityAddTraits(.isButton)

            if let suggestion, let dismissSuggestion {
                HStack(alignment: .top, spacing: 8) {
                    Text(suggestion)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: dismissSuggestion) {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: dismissTarget, height: dismissTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss this suggestion")
                }
                .padding(.leading, 12)
                .padding(.trailing, 2)
                .padding(.vertical, 2)
                .background(
                    accent.opacity(OGTheme.Opacity.accentNoticeFill),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
        }
        .padding(.horizontal, OGMetrics.rowHorizontalPadding)
        .padding(.vertical, 12)
        .background(OGTheme.card, in: shape)
        .overlay {
            if suggestion != nil {
                shape.strokeBorder(
                    accent.opacity(OGTheme.Opacity.accentFill),
                    lineWidth: 1
                )
            }
        }
    }
}

// MARK: - Hero device card

/// Dark hero atop the Settings hub: device identity, live status, and
/// capability chips, under a soft accent glow. Chrome, so it earns glass.
///
/// The card is ink in both schemes, so every accent it uses comes from the
/// accent's *dark* side (`OGTheme.inkAccent…`) — an adaptive accent's
/// light-mode value is picked to sit on white and measures well under AA here.
struct OGHeroDeviceCard: View {
    let title: String
    let status: String
    var dot: Color = OGTheme.ok
    /// e.g. 82 — omitted when the firmware hasn't reported yet.
    var batteryPercent: Int? = nil
    var chips: [(label: String, available: Bool)] = []
    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var glyphTile: CGFloat = 50
    @ScaledMetric(relativeTo: .footnote) private var dotSize: CGFloat = 7

    /// The whole card as one spoken sentence — identity, state, power, then
    /// what the device can and can't do. Pure, so the suite covers the wording.
    static func spokenSummary(
        title: String,
        status: String,
        batteryPercent: Int?,
        chips: [(label: String, available: Bool)]
    ) -> String {
        var parts = [title, status]
        if let batteryPercent {
            parts.append("Battery \(batteryPercent) percent")
        }
        let available = chips.filter { $0.available }.map { $0.label }
        let unavailable = chips.filter { !$0.available }.map { $0.label }
        if !available.isEmpty {
            parts.append("Available: " + available.joined(separator: ", "))
        }
        if !unavailable.isEmpty {
            parts.append("Unavailable: " + unavailable.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        let inkAccent = OGTheme.inkAccent(accent)
        let inkAccentLabel = OGTheme.inkAccentLabel(accent)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: glyphTile * 0.26, style: .continuous)
                    .fill(inkAccent.opacity(0.2))
                    .frame(width: glyphTile, height: glyphTile)
                    .overlay {
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .foregroundStyle(inkAccentLabel)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OGTheme.onInk)
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: dotSize, height: dotSize)
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(OGTheme.onInk.opacity(OGTheme.Opacity.onInkTertiary))
                            // No line cap at all: `lineLimit(1)` truncated "Not connected"
                            // outright at accessibility sizes — the state of the device, on the
                            // card that exists to report it — and any cap is a size at which the
                            // text can still be cut. These statuses are two words; letting them
                            // wrap costs nothing at the sizes they already fit.
                            .fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(OGTheme.onInk.opacity(OGTheme.Opacity.onInkSecondary))
                }
            }

            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.label) { chip in
                        Text(chip.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                chip.available
                                    ? inkAccentLabel
                                    : OGTheme.onInk.opacity(OGTheme.Opacity.onInkTertiary)
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                chip.available
                                    ? inkAccent.opacity(OGTheme.Opacity.accentInkFill)
                                    : OGTheme.onInk.opacity(OGTheme.Opacity.onInkFill),
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
                        colors: [inkAccent.opacity(0.28), .clear],
                        center: .topLeading, startRadius: 0, endRadius: 240
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.spokenSummary(
                title: title, status: status,
                batteryPercent: batteryPercent, chips: chips
            )
        )
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

// MARK: - Selection & status

/// The trailing check on a row in a grouped selection list.
///
/// Kept in the layout at all times and merely faded, so choosing a different row
/// doesn't reflow the list under the user's finger. The glyph is decoration: the
/// state itself is spoken by the row's `.isSelected` trait, which is why this is
/// hidden from the accessibility tree rather than labelled "selected".
struct OGSelectionCheck: View {
    let isSelected: Bool

    @Environment(\.appAccent) private var accent

    init(_ isSelected: Bool) {
        self.isSelected = isSelected
    }

    var body: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(OGTheme.tintedAccentLabel(accent))
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// One row of a grouped selection list: a title, an optional supporting line,
/// and a trailing check.
///
/// This is the shape the credential pages settled on — a stock list row rather
/// than a custom pill, so it inherits the system's row material, separators and
/// highlight. The whole row is the target (`contentShape`) at a height that
/// scales past 44pt with Dynamic Type, and the selection reaches VoiceOver as
/// the `.isSelected` trait rather than as a coral tick.
struct OGSelectionRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    /// What VoiceOver reads. Defaults to the visible text; pass a fuller
    /// sentence where the row's meaning needs more than its label ("Claude
    /// Sonnet, Anthropic, active").
    var accessibilityText: String? = nil
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 44

    var body: some View {
        Button(action: action) {
            HStack(spacing: OGMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    // Two lines rather than one: model names are long, and at
                    // AX5 a single line truncates the part that distinguishes
                    // one entry from the next.
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                OGSelectionCheck(isSelected)
            }
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? [title, subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A one-line outcome beside a control: "Key valid — 12 models", a validation
/// failure, "Reachable — 40 ms".
///
/// The colour comes from the corrected `okLabel`/`warnLabel`/`errorLabel`
/// family rather than the raw status hues, which are picked to read as a 7pt dot
/// and measure ~2:1 as text. Colour is never the only carrier: the glyph differs
/// per kind and the sentence says what happened, so the meaning survives both a
/// monochrome display and a screen reader.
struct OGStatusLabel: View {
    enum Kind {
        case ok, warn, error

        /// The audited token this kind paints its text in. Exposed so the
        /// contrast suite can measure the mapping rather than the rendering.
        var token: OGColorToken {
            switch self {
            case .ok: return OGTheme.okLabelToken
            case .warn: return OGTheme.warnLabelToken
            case .error: return OGTheme.errorLabelToken
            }
        }

        var color: Color {
            switch self {
            case .ok: return OGTheme.okLabel
            case .warn: return OGTheme.warnLabel
            case .error: return OGTheme.errorLabel
            }
        }

        /// The default glyph, so the three states differ in shape and not only
        /// in hue.
        var systemImage: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle"
            case .error: return "exclamationmark.circle.fill"
            }
        }
    }

    let text: String
    let kind: Kind
    var systemImage: String? = nil

    init(_ text: String, kind: Kind, systemImage: String? = nil) {
        self.text = text
        self.kind = kind
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage ?? kind.systemImage)
            .font(.footnote)
            .foregroundStyle(kind.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Buttons

/// The filled accent button — one call to action per page, in the app's accent
/// rather than a hand-rolled white slab.
///
/// The label goes through `OGTheme.onAccentLabel`, because the accent is the
/// *ground* here: a bright preset needs dark text and a deep one needs light,
/// and picking one and hoping is how a filled button loses its contrast. The
/// height is a scaled metric so the target clears 44pt at every Dynamic Type
/// size, and a disabled button drops to the system's own inactive fill rather
/// than a washed-out accent that still claims to be tappable.
struct OGProminentButtonStyle: ButtonStyle {
    enum Size {
        /// Full-width page action.
        case full
        /// Inline capsule beside a row ("Grant").
        case compact
    }

    var size: Size = .full

    @Environment(\.appAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var fullHeight: CGFloat = 50
    @ScaledMetric(relativeTo: .subheadline) private var compactHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        let shape: AnyShape = size == .full
            ? AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            : AnyShape(Capsule())
        return configuration.label
            .font(size == .full ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(
                isEnabled
                    ? AnyShapeStyle(OGTheme.onAccentLabel(accent))
                    : AnyShapeStyle(Color.secondary)
            )
            .padding(.horizontal, size == .full ? 16 : 18)
            .frame(maxWidth: size == .full ? .infinity : nil)
            .frame(minHeight: size == .full ? fullHeight : compactHeight)
            .background(
                isEnabled ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.quaternarySystemFill)),
                in: shape
            )
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// The quiet companion to the filled button — "Skip setup", "I'll add it
/// later". Plain text, but padded to a full 44pt row so it is a real target.
struct OGQuietButtonStyle: ButtonStyle {
    @ScaledMetric(relativeTo: .subheadline) private var minHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == OGProminentButtonStyle {
    static var ogProminent: OGProminentButtonStyle { .init() }
    static var ogProminentCompact: OGProminentButtonStyle { .init(size: .compact) }
}

extension ButtonStyle where Self == OGQuietButtonStyle {
    static var ogQuiet: OGQuietButtonStyle { .init() }
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
