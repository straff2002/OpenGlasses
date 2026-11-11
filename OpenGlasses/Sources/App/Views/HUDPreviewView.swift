#if !AVENKIN_PHONE_ONLY
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HUDPreviewView.swift
//
// Native SwiftUI renderer for the MWDATDisplay DSL, adapted for OpenGlasses.
//
// The SDK only *sends* Display views to the glasses (`Display.send` over a
// DeviceSession); it has no phone-side renderer. The DSL types (FlexBox / Text /
// Button / Image / Icon) are public, readable structs, so this view walks the same
// `FlexBox` tree that `GlassesDisplayService.makeScreenView(_:)` builds and renders it
// natively — a single-source-of-truth on-phone mirror of the in-lens HUD. With no
// Display hardware on hand, this is how we preview and snapshot-test the HUD.
//
// Styling is OpenGlasses' own (coral accent for active/AI elements, capsule buttons)
// rather than a generic card. MWDATDisplay's `Text`/`Button`/`Image` names collide with
// SwiftUI, so SDK types are written fully-qualified.
//

#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
#endif
import SwiftUI

/// Renders a `HUDScreen` as it would appear on the lens, drawn to the lens's shape (Plan KP §6):
/// a black 600 × 600 square for the Meta Display, the 2:1 576 × 288 panel for Even G2, fitted to
/// the space available by `HUDCanvasScale` (letterboxed, on whole device pixels, never past one
/// point per lens pixel). Text is drawn at each token's *estimated* lens size, scaled with the
/// canvas, so the answer card's pages show exactly as `HUDAnswerPager` cuts them and text length
/// can be judged without hardware. VoiceOver hears that the sizes are estimates.
///
/// A screen's picture (the page view's crop, Plan KV P3) is drawn from the same `HUDPicture` the
/// lens was sent. With `onPress`, the buttons work: each press goes out by the button's id
/// (`HUDRouter.pressFromPreview`), so a reviewer without a Display can walk the page view.
struct HUDPreviewView: View {
    let screen: HUDScreen
    /// The lens to draw; nil follows the display backend chosen in Settings.
    var canvas: HUDCanvas?
    /// Where a button press goes; nil leaves the preview view-only.
    var onPress: (@MainActor @Sendable (String) -> Void)?

    @AppStorage("displayBackend") private var displayBackendRaw = DisplayBackendChoice.metaRayBan.rawValue
    @Environment(\.displayScale) private var displayScale

    init(screen: HUDScreen, canvas: HUDCanvas? = nil,
         onPress: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.screen = screen
        self.canvas = canvas
        self.onPress = onPress
    }

    private var resolvedCanvas: HUDCanvas {
        if let canvas { return canvas }
        return HUDCanvas.canvas(for: DisplayBackendChoice(rawValue: displayBackendRaw) ?? .metaRayBan)
    }

    var body: some View {
        let canvas = resolvedCanvas
        Color.clear
            .aspectRatio(canvas.aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let fit = HUDCanvasScale.fit(canvas, in: geometry.size, displayScale: displayScale)
                    HUDCanvasView(screen: screen, fit: fit, onPress: onPress)
                        .offset(x: fit.origin.x, y: fit.origin.y)
                }
            }
            .frame(maxWidth: CGFloat(canvas.widthPixels) * HUDCanvasScale.maxPointsPerPixel)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(canvas.accessibilitySummary)
    }
}

/// One fitted lens: the black canvas, the screen drawn the way its backend draws it, clipped to
/// the lens's edges (what doesn't fit is cut, as on the lens).
private struct HUDCanvasView: View {
    let screen: HUDScreen
    let fit: HUDCanvasScale
    var onPress: (@MainActor @Sendable (String) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            switch fit.canvas.backend {
            case .metaDisplay:
                HUDDSLView(flexBox: GlassesDisplayService.previewFlexBox(for: screen, onSelect: onPress))
                    .environment(\.hudCanvasFit, fit)
                    .environment(\.hudPicture, screen.picture?.image)
                    .frame(width: fit.size.width, height: fit.size.height, alignment: .topLeading)
            case .evenG2:
                EvenPanelView(screen: screen, fit: fit)
            }
        }
        .frame(width: fit.size.width, height: fit.size.height, alignment: .topLeading)
        .clipped()
        .overlay(Rectangle().strokeBorder(AppAccent.color.opacity(0.25), lineWidth: 1))
    }
}

/// The Even G2 panel: the frame `EvenScreenRenderer` sends, one monochrome line per row at the
/// renderer's estimated cell metrics (12 px advance, 36 px pitch, 44 cells centred).
private struct EvenPanelView: View {
    let screen: HUDScreen
    let fit: HUDCanvasScale

    /// The panel's green, as a phone colour.
    private static let panelGreen = Color(red: 0.42, green: 1.0, blue: 0.52)

    private var lines: [String] {
        if case .lines(let lines) = EvenScreenRenderer.render(screen: screen) { return lines }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { item in
                SwiftUI.Text(verbatim: item.element)
                    .font(.system(size: fit.points(HUDCanvas.evenFontPixels), design: .monospaced))
                    .foregroundColor(Self.panelGreen)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)  // overflow is cut, never ellipsised
                    .frame(height: fit.points(HUDCanvas.evenLinePitchPixels), alignment: .leading)
            }
        }
        .padding(.leading, fit.points(fit.canvas.evenLeftMarginPixels))
    }
}

/// The fit a Display tree is drawn at: every DAT length (padding, spacing) and every estimated text
/// size is in lens pixels, and the renderer multiplies by `pointsPerPixel`. Defaults to one point
/// per pixel.
private struct HUDCanvasFitKey: EnvironmentKey {
    static let defaultValue = HUDCanvasScale.fit(.metaDisplay, in: CGSize(width: 600, height: 600))
}

/// The picture the screen was sent with (Plan KV P3), drawn where its tree has a `.fill` image:
/// the phone draws the very image the lens got, not a decode of the tree's copy.
private struct HUDPictureKey: EnvironmentKey {
    static let defaultValue: UIImage? = nil
}

private extension EnvironmentValues {
    var hudCanvasFit: HUDCanvasScale {
        get { self[HUDCanvasFitKey.self] }
        set { self[HUDCanvasFitKey.self] = newValue }
    }
    var hudPicture: UIImage? {
        get { self[HUDPictureKey.self] }
        set { self[HUDPictureKey.self] = newValue }
    }
}

/// Renders a Display `FlexBox` (the root view sent to the glasses) natively.
struct HUDDSLView: View {
    let flexBox: MWDATDisplay.FlexBox

    var body: some View {
        FlexBoxView(flexBox: flexBox)
    }
}

// MARK: - FlexBox

private struct FlexBoxView: View {
    let flexBox: MWDATDisplay.FlexBox
    @Environment(\.hudCanvasFit) private var fit

    var body: some View {
        stack
            .padding(edgeInsets)
            .background(backgroundView)
            .modifier(TapModifier(onTap: flexBox.onClick))
    }

    @ViewBuilder
    private var stack: some View {
        switch flexBox.direction {
        case .row, .rowReverse:
            HStack(alignment: crossVerticalAlignment, spacing: fit.points(flexBox.spacing)) {
                ForEach(Array(orderedChildren.enumerated()), id: \.offset) { item in
                    ComponentView(component: item.element)
                        .modifier(FlexGrowModifier(component: item.element, isRow: true))
                }
            }
        default:  // .column / .columnReverse / future
            VStack(alignment: crossHorizontalAlignment, spacing: fit.points(flexBox.spacing)) {
                ForEach(Array(orderedChildren.enumerated()), id: \.offset) { item in
                    ComponentView(component: item.element)
                        .modifier(FlexGrowModifier(component: item.element, isRow: false))
                }
            }
        }
    }

    private var orderedChildren: [any MWDATDisplay.ViewComponent] {
        switch flexBox.direction {
        case .rowReverse, .columnReverse: return flexBox.children.reversed()
        default: return flexBox.children
        }
    }

    private var crossHorizontalAlignment: HorizontalAlignment {
        switch flexBox.crossAlignment {
        case .start: return .leading
        case .end: return .trailing
        default: return .center
        }
    }

    private var crossVerticalAlignment: VerticalAlignment {
        switch flexBox.crossAlignment {
        case .start: return .top
        case .end: return .bottom
        default: return .center
        }
    }

    private var edgeInsets: SwiftUI.EdgeInsets {
        guard let p = flexBox.padding else { return SwiftUI.EdgeInsets() }
        return SwiftUI.EdgeInsets(top: fit.points(p.top), leading: fit.points(p.leading),
                                  bottom: fit.points(p.bottom), trailing: fit.points(p.trailing))
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch flexBox.background {
        case .card:
            RoundedRectangle(cornerRadius: fit.points(16), style: .continuous)
                .fill(OGTheme.onMedia.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: fit.points(16), style: .continuous)
                        .strokeBorder(OGTheme.onMedia.opacity(0.12), lineWidth: 1)
                )
        default:
            Color.clear
        }
    }
}

/// Applies an optional tap handler without changing the view type.
private struct TapModifier: ViewModifier {
    let onTap: (@Sendable () -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onTap {
            content.onTapGesture { onTap() }
        } else {
            content
        }
    }
}

/// Honors a child FlexBox's `flexGrow` (e.g. equal-width row columns).
private struct FlexGrowModifier: ViewModifier {
    let component: any MWDATDisplay.ViewComponent
    let isRow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let box = component as? MWDATDisplay.FlexBox, box.flexGrow > 0 {
            if isRow { content.frame(maxWidth: .infinity) } else { content.frame(maxHeight: .infinity) }
        } else {
            content
        }
    }
}

// MARK: - Leaf components

private struct ComponentView: View {
    let component: any MWDATDisplay.ViewComponent
    @Environment(\.hudCanvasFit) private var fit
    @Environment(\.hudPicture) private var picture

    var body: some View {
        if let text = component as? MWDATDisplay.Text {
            SwiftUI.Text(text.content)
                .font(displayFont(for: text.style, fit: fit))
                .foregroundColor(displayColor(for: text.color))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let button = component as? MWDATDisplay.Button {
            buttonView(button)
        } else if let image = component as? MWDATDisplay.Image {
            imageView(image)
        } else if let icon = component as? MWDATDisplay.Icon {
            SwiftUI.Image(systemName: sfSymbol(for: icon.name))
                .font(.system(size: fit.fontPoints(.body)))
                .foregroundColor(AppAccent.color)
        } else if let group = component as? MWDATDisplay.ButtonGroup {
            buttonGroupView(group)
        } else if let nested = component as? MWDATDisplay.FlexBox {
            FlexBoxView(flexBox: nested)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func buttonGroupView(_ group: MWDATDisplay.ButtonGroup) -> some View {
        HStack(spacing: fit.points(8)) {
            ForEach(Array(group.buttons.enumerated()), id: \.offset) { item in
                buttonView(item.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: groupAlignment(group.alignment))
    }

    private func groupAlignment(_ alignment: MWDATDisplay.ButtonGroupAlignment) -> SwiftUI.Alignment {
        switch alignment {
        case .start: return .leading
        case .end: return .trailing
        default: return .center
        }
    }

    @ViewBuilder
    private func buttonView(_ button: MWDATDisplay.Button) -> some View {
        SwiftUI.Button(action: { button.onClick?() }) {
            HStack(spacing: fit.points(6)) {
                if let iconName = button.iconName {
                    SwiftUI.Image(systemName: sfSymbol(for: iconName))
                }
                SwiftUI.Text(button.label)
            }
            .font(.system(size: fit.fontPoints(.body), weight: .semibold))
            .padding(.horizontal, fit.points(16))
            .padding(.vertical, fit.points(10))
            .frame(maxWidth: .infinity)
            .background(buttonBackground(button.style))
            .foregroundColor(buttonForeground(button.style))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    AppAccent.color.opacity(button.style == .outline ? 0.8 : 0),
                    lineWidth: max(1, fit.points(2))
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func imageView(_ image: MWDATDisplay.Image) -> some View {
        if image.sizePreset == .fill, let picture {
            // The page view's picture (Plan KV P3): the space the lines and the button row leave,
            // at the picture's own shape (the box the frame left it), as on the lens.
            SwiftUI.Image(uiImage: picture)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
                .accessibilityLabel(SwiftUI.Text("Manual page", comment: "HUD preview: the manual page picture shown on the lens."))
        } else {
            uriImageView(image)
        }
    }

    @ViewBuilder
    private func uriImageView(_ image: MWDATDisplay.Image) -> some View {
        let isIcon = image.sizePreset == .icon
        AsyncImage(url: URL(string: image.uri)) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fit)
            } else if phase.error != nil {
                OGTheme.onMedia.opacity(0.12)
            } else {
                ProgressView()
            }
        }
        .frame(width: isIcon ? fit.points(28) : nil, height: fit.points(isIcon ? 28 : 120))
        .frame(maxWidth: isIcon ? nil : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: fit.points(corner(image.cornerRadius)), style: .continuous))
    }
}

// MARK: - Style mapping (Display enums → SwiftUI, OpenGlasses brand)

/// Deliberately *fixed* sizes, and the one place in the app they are right: this view is a
/// scaled picture of a fixed-geometry lens, so it has to reproduce what the wearer sees rather
/// than what the phone's text size asks for. Growing these with Dynamic Type would make the
/// preview misreport the HUD. Each token's size is `HUDCanvas.textSize(_:)`'s **estimate** in lens
/// pixels (P6 calibrates it), scaled with the canvas.
private func displayFont(for style: MWDATDisplay.TextStyle, fit: HUDCanvasScale) -> Font {
    switch style {
    case .heading: return .system(size: fit.fontPoints(.heading), weight: .bold)
    case .meta: return .system(size: fit.fontPoints(.meta), weight: .regular)
    default: return .system(size: fit.fontPoints(.body), weight: .regular)  // .body
    }
}

private func displayColor(for color: MWDATDisplay.TextColor) -> Color {
    switch color {
    case .secondary: return OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaTertiary)
    default: return OGTheme.onMedia  // .primary
    }
}

/// Primary = coral (the active/AI accent); secondary = subtle; outline = clear + coral stroke.
private func buttonBackground(_ style: MWDATDisplay.ButtonStyle) -> Color {
    switch style {
    case .primary: return AppAccent.color
    case .secondary: return OGTheme.onMedia.opacity(0.16)
    default: return .clear  // .outline
    }
}

private func buttonForeground(_ style: MWDATDisplay.ButtonStyle) -> Color {
    switch style {
    // The accent is the *ground* on a filled button, so the label is whichever
    // pole reads on it rather than an assumed white.
    case .primary: return OGTheme.onAccentLabel(AppAccent.color)
    case .outline: return OGTheme.inkAccentLabel(AppAccent.color)
    default: return OGTheme.onMedia  // .secondary
    }
}

private func corner(_ radius: MWDATDisplay.CornerRadius) -> CGFloat {
    switch radius {
    case .small: return 8
    case .medium: return 14
    default: return 0
    }
}

/// SF Symbols for the IconName cases our HUD produces (HUDIcon → IconName); others fall
/// back to a neutral dot.
private func sfSymbol(for name: MWDATDisplay.IconName) -> String {
    switch name {
    case .checkmarkCircle: return "checkmark.circle.fill"
    case .iCircle: return "info.circle"
    case .exclamationTriangle: return "exclamationmark.triangle.fill"
    case .exclamationCircle: return "exclamationmark.circle.fill"
    case .compassNorthUpRed: return "location.north.circle"
    case .calendar: return "calendar"
    case .house: return "house"
    case .bell: return "bell.fill"
    case .speechBubble: return "bubble.left.and.text.bubble.right"
    case .cloud: return "cloud"
    case .clock: return "clock"
    case .threeDotSpeechBubble: return "ellipsis.bubble"
    case .musicNote: return "music.note"
    case .triangleRightCircle: return "play.circle"
    default: return "circle.fill"
    }
}

// MARK: - Previews

#if DEBUG
private func sampleTaskCard() -> HUDScreen {
    HUDScreen(
        title: "Torque the manifold bolts",
        lines: [
            HUDLine("Step 3 of 7", emphasis: .meta),
            HUDLine("45 Nm, crosswise, 2 passes", emphasis: .secondary),
            HUDLine("De-energize before contact", icon: .hazard, emphasis: .secondary),
            HUDLine("Next: Reconnect the sensor", emphasis: .meta),
        ],
        items: [
            HUDItem(id: "done", label: "Done", icon: .success, style: .primary) {},
            HUDItem(id: "skip", label: "Skip", style: .secondary) {},
            HUDItem(id: "back", label: "Back", style: .outline) {},
        ]
    )
}

private func sampleMenu() -> HUDScreen {
    HUDScreen(title: "Menu", items: [
        HUDItem(id: "quick", label: "Quick Actions", icon: .message, style: .secondary) {},
        HUDItem(id: "modes", label: "Mode / Persona", style: .secondary) {},
        HUDItem(id: "close", label: "Close", style: .outline) {},
    ])
}

#Preview("Task card") {
    ZStack { Color(white: 0.12).ignoresSafeArea(); HUDPreviewView(screen: sampleTaskCard(), canvas: .metaDisplay).padding() }
}

#Preview("Task card, Even G2") {
    ZStack { Color(white: 0.12).ignoresSafeArea(); HUDPreviewView(screen: sampleTaskCard(), canvas: .evenG2).padding() }
}

#Preview("Launcher menu") {
    ZStack { Color(white: 0.12).ignoresSafeArea(); HUDPreviewView(screen: sampleMenu(), canvas: .metaDisplay).padding() }
}
#endif

#else
import SwiftUI

/// Phone-side rendering uses the app's own screen data, without the Meta display DSL.
struct HUDPreviewView: View {
    let screen: HUDScreen
    /// Unused here: the phone-only build has no lens to walk.
    var onPress: (@MainActor @Sendable (String) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = screen.title { Text(title).font(.headline) }
            ForEach(Array(screen.lines.enumerated()), id: \.offset) { entry in Text(entry.element.text) }
            ForEach(screen.items) { item in Button(item.label, action: item.action) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }
}
#endif
