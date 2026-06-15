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

import MWDATDisplay
import SwiftUI

/// Renders a `HUDScreen` as it would appear on the lens, on a dark "glass" panel.
struct HUDPreviewView: View {
    let screen: HUDScreen

    var body: some View {
        HUDDSLView(flexBox: GlassesDisplayService.previewFlexBox(for: screen))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(AppAccent.aiCoral.opacity(0.25), lineWidth: 1)
                    )
            )
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
            HStack(alignment: crossVerticalAlignment, spacing: flexBox.spacing) {
                ForEach(Array(orderedChildren.enumerated()), id: \.offset) { item in
                    ComponentView(component: item.element)
                        .modifier(FlexGrowModifier(component: item.element, isRow: true))
                }
            }
        default:  // .column / .columnReverse / future
            VStack(alignment: crossHorizontalAlignment, spacing: flexBox.spacing) {
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
        return SwiftUI.EdgeInsets(top: p.top, leading: p.leading, bottom: p.bottom, trailing: p.trailing)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch flexBox.background {
        case .card:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
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

    var body: some View {
        if let text = component as? MWDATDisplay.Text {
            SwiftUI.Text(text.content)
                .font(displayFont(for: text.style))
                .foregroundColor(displayColor(for: text.color))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let button = component as? MWDATDisplay.Button {
            buttonView(button)
        } else if let image = component as? MWDATDisplay.Image {
            imageView(image)
        } else if let icon = component as? MWDATDisplay.Icon {
            SwiftUI.Image(systemName: sfSymbol(for: icon.name))
                .foregroundColor(AppAccent.aiCoral)
        } else if let nested = component as? MWDATDisplay.FlexBox {
            FlexBoxView(flexBox: nested)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func buttonView(_ button: MWDATDisplay.Button) -> some View {
        SwiftUI.Button(action: { button.onClick?() }) {
            HStack(spacing: 6) {
                if let iconName = button.iconName {
                    SwiftUI.Image(systemName: sfSymbol(for: iconName))
                }
                SwiftUI.Text(button.label).fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(buttonBackground(button.style))
            .foregroundColor(buttonForeground(button.style))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    AppAccent.aiCoral.opacity(button.style == .outline ? 0.8 : 0),
                    lineWidth: 1.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func imageView(_ image: MWDATDisplay.Image) -> some View {
        let isIcon = image.sizePreset == .icon
        AsyncImage(url: URL(string: image.uri)) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fit)
            } else if phase.error != nil {
                Color.white.opacity(0.12)
            } else {
                ProgressView()
            }
        }
        .frame(width: isIcon ? 28 : nil, height: isIcon ? 28 : 120)
        .frame(maxWidth: isIcon ? nil : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner(image.cornerRadius), style: .continuous))
    }
}

// MARK: - Style mapping (Display enums → SwiftUI, OpenGlasses brand)

private func displayFont(for style: MWDATDisplay.TextStyle) -> Font {
    switch style {
    case .heading: return .system(size: 22, weight: .bold)
    case .meta: return .system(size: 12, weight: .regular)
    default: return .system(size: 15, weight: .regular)  // .body
    }
}

private func displayColor(for color: MWDATDisplay.TextColor) -> Color {
    switch color {
    case .secondary: return .white.opacity(0.6)
    default: return .white  // .primary
    }
}

/// Primary = coral (the active/AI accent); secondary = subtle; outline = clear + coral stroke.
private func buttonBackground(_ style: MWDATDisplay.ButtonStyle) -> Color {
    switch style {
    case .primary: return AppAccent.aiCoral
    case .secondary: return .white.opacity(0.16)
    default: return .clear  // .outline
    }
}

private func buttonForeground(_ style: MWDATDisplay.ButtonStyle) -> Color {
    switch style {
    case .primary: return .white
    case .outline: return AppAccent.aiCoral
    default: return .white  // .secondary
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
    ZStack { Color(white: 0.12).ignoresSafeArea(); HUDPreviewView(screen: sampleTaskCard()).padding() }
}

#Preview("Launcher menu") {
    ZStack { Color(white: 0.12).ignoresSafeArea(); HUDPreviewView(screen: sampleMenu()).padding() }
}
#endif
