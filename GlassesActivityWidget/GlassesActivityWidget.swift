import WidgetKit
import SwiftUI
import ActivityKit

@main
struct GlassesActivityWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        GlassesActivityWidget()
        OpenGlassesHomeWidget()
        if #available(iOS 18.0, *) {
            AskAvenkinControlWidget()
            ListeningControlWidget()
        }
    }
}

struct GlassesActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlassesActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        LogoIcon(size: 22)
                            .foregroundStyle(context.state.isConnected ? .green : .gray)
                        if let battery = context.state.batteryLevel {
                            Text("\(battery)%")
                                .font(.caption2)
                                .foregroundStyle(battery < 20 ? .red : .secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusIcon(for: context.state)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if !context.state.lastResponseSnippet.isEmpty {
                            Text(context.state.lastResponseSnippet)
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if context.state.isConnected {
                            actionButtons(for: context.state, compact: true)
                        } else {
                            // The one primary action while disconnected: a solid accent fill,
                            // labelled the way the app's primary button is.
                            Link(destination: DeepLinkTrust.signedURL("openglasses://connect")!) {
                                Label {
                                    Text("Connect")
                                } icon: {
                                    LogoIcon(size: 12)
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AccentColors.onAiCoral)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(AccentColors.aiCoral, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    LogoIcon(size: 14)
                        .foregroundStyle(context.state.isConnected ? AccentColors.aiCoral : .gray)
                    if let battery = context.state.batteryLevel {
                        // Fixed size on purpose: the Dynamic Island's compact leading
                        // slot is a hard geometry, and text that grows is text that
                        // gets truncated away entirely. The expanded and Lock Screen
                        // presentations below carry the same number at Dynamic Type.
                        Text("\(battery)")
                            .font(.system(size: 9))
                            .foregroundStyle(battery < 20 ? .red : .secondary)
                    }
                }
            } compactTrailing: {
                statusIcon(for: context.state)
                    .foregroundStyle(statusColor(for: context.state))
            } minimal: {
                LogoIcon(size: 16)
                    .foregroundStyle(context.state.isConnected ? AccentColors.aiCoral : .gray)
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<GlassesActivityAttributes>) -> some View {
        let plan = LockScreenActivityLayout.plan(availableActions: actionItems(for: context.state).count,
                                                 isConnected: context.state.isConnected)
        VStack(spacing: LockScreenActivityLayout.sectionSpacing) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    LogoIcon(size: 30)
                        .foregroundStyle(.white)
                    Circle()
                        .fill(context.state.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: LockScreenActivityLayout.headerStatusSpacing) {
                    HStack {
                        Text(statusText(for: context.state))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        if let battery = context.state.batteryLevel {
                            HStack(spacing: 2) {
                                Image(systemName: batteryIcon(battery))
                                    .font(.caption2)
                                Text("\(battery)%")
                                    .font(.caption2)
                            }
                            .foregroundStyle(battery < 20 ? .red : .white.opacity(0.6))
                        }
                        // Power button to disable listening from Lock Screen
                        Button(intent: DisableListeningIntent()) {
                            Image(systemName: "power")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(5)
                                .background(Circle().fill(.white.opacity(0.15)))
                                // The drawn circle keeps its size; the target
                                // around it clears 44pt.
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        statusIcon(for: context.state)
                            .foregroundStyle(statusColor(for: context.state))
                    }

                    // One line, not two: the Lock Screen presentation has a hard height
                    // budget, and a second snippet line is the cheapest thing to give up.
                    if !context.state.lastResponseSnippet.isEmpty {
                        Text(context.state.lastResponseSnippet)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }

            // Quick actions — always shown so the Lock Screen stays useful even when the
            // glasses are disconnected (most actions just open the app via deep link). One row,
            // never two: the Lock Screen slot is a hard height and a 2 × 2 grid had its bottom row
            // cut off on a phone (`LockScreenActivityLayout`). Disconnected, Connect leads the
            // row in the place an action would have taken.
            lockScreenActionRow(for: context.state, plan: plan)
        }
        .padding(LockScreenActivityLayout.outerPadding)
        .background(Color.black.opacity(0.6))
        // The slot's height does not grow with the text, so the text cannot grow without limit
        // either: past xLarge the row would push past the Lock Screen's cut-off again. The app
        // itself, where nothing is clipped, carries the full range.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    @ViewBuilder
    private func lockScreenActionRow(for state: GlassesActivityAttributes.ContentState,
                                     plan: LockScreenActivityLayout.Plan) -> some View {
        let items = Array(actionItems(for: state).prefix(plan.actionCount))
        HStack(spacing: 8) {
            if plan.showsConnect {
                rowButton(label: "Connect", icon: "antenna.radiowaves.left.and.right",
                          url: DeepLinkTrust.signedURL("openglasses://connect")!,
                          tint: AccentColors.aiCoral, strong: true, filled: true,
                          style: plan.style)
            }
            ForEach(items) { item in
                rowButton(label: item.label, icon: item.icon, url: item.url,
                          tint: item.accent ? AccentColors.aiCoral : .white, strong: item.accent,
                          style: plan.style)
            }
        }
    }

    /// One button of the Lock Screen row: a glyph over a one-line caption when the row holds three
    /// or four, beside it when one or two. At least 44 pt tall either way.
    @ViewBuilder
    private func rowButton(label: String, icon: String, url: URL, tint: Color, strong: Bool,
                           filled: Bool = false,
                           style: LockScreenActivityLayout.ButtonStyle) -> some View {
        Link(destination: url) {
            Group {
                if style == .glyphOverLabel {
                    VStack(spacing: LockScreenActivityLayout.glyphCaptionSpacing) {
                        Image(systemName: icon)
                            .font(.callout.weight(.semibold))
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.callout.weight(.semibold))
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }
            .foregroundStyle(filled ? AccentColors.onAiCoral : .white)
            .frame(maxWidth: .infinity, minHeight: LockScreenActivityLayout.minimumButtonHeight
                   - LockScreenActivityLayout.buttonVerticalPadding * 2)
            .padding(.vertical, LockScreenActivityLayout.buttonVerticalPadding)
            .padding(.horizontal, 6)
            .background(filled ? tint : tint.opacity(strong ? 0.30 : 0.16),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(filled ? 0 : (strong ? 0.55 : 0.18)), lineWidth: 1))
        }
        .accessibilityLabel(label)
    }

    // MARK: - Action Buttons

    /// A resolved button for the Live Activity (quick action, persona, or fallback).
    private struct ActionItem: Identifiable {
        let id: String
        let label: String
        let icon: String
        let url: URL
        let accent: Bool   // coral-tinted (AI/Field Assist) vs neutral
    }

    /// Quick actions take priority (incl. the built-in Field Assist action), then personas,
    /// then a generic Ask/Photo fallback. Capped at 4 — the Lock Screen row's most.
    private func actionItems(for state: GlassesActivityAttributes.ContentState) -> [ActionItem] {
        if !state.quickActionButtons.isEmpty {
            return state.quickActionButtons.prefix(LockScreenActivityLayout.maxButtons).map {
                ActionItem(id: $0.id, label: $0.label, icon: $0.icon,
                           url: DeepLinkTrust.signedURL("openglasses://quickaction/\($0.id)")!,
                           accent: $0.id == "field-assist")
            }
        } else if !state.personaButtons.isEmpty {
            return state.personaButtons.prefix(LockScreenActivityLayout.maxButtons).map {
                ActionItem(id: $0.id, label: $0.name, icon: "person.fill",
                           url: DeepLinkTrust.signedURL("openglasses://persona/\($0.id)")!, accent: false)
            }
        } else {
            return [
                ActionItem(id: "ask", label: "Ask", icon: "mic.fill",
                           url: DeepLinkTrust.signedURL("openglasses://action/ask")!, accent: true),
                ActionItem(id: "photo", label: "Photo", icon: "camera.fill",
                           url: DeepLinkTrust.signedURL("openglasses://action/photo")!, accent: false),
            ]
        }
    }

    /// The Dynamic Island's slim single row (space-constrained). The Lock Screen draws its own
    /// row — `lockScreenActionRow`.
    @ViewBuilder
    private func actionButtons(for state: GlassesActivityAttributes.ContentState,
                               compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(actionItems(for: state).prefix(3)) { item in
                Link(destination: item.url) {
                    Label(item.label, systemImage: item.icon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background((item.accent ? AccentColors.aiCoral : .white).opacity(0.22), in: Capsule())
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusIcon(for state: GlassesActivityAttributes.ContentState) -> some View {
        if state.isListening {
            Image(systemName: "waveform")
        } else if state.isProcessing {
            Image(systemName: "brain")
        } else if state.isSpeaking {
            Image(systemName: "speaker.wave.2.fill")
        } else if state.isConnected {
            Image(systemName: "checkmark.circle")
        } else {
            Image(systemName: "wifi.slash")
        }
    }

    private func statusText(for state: GlassesActivityAttributes.ContentState) -> String {
        if state.isListening { return "Listening..." }
        if state.isProcessing { return "Thinking..." }
        if state.isSpeaking { return "Speaking..." }
        if state.isConnected { return state.deviceName ?? "Connected" }
        return "Disconnected"
    }

    private func statusColor(for state: GlassesActivityAttributes.ContentState) -> Color {
        if state.isListening { return AccentColors.aiCoral }
        if state.isProcessing { return .orange }
        if state.isSpeaking { return .green }
        if state.isConnected { return .green }
        return .gray
    }

    private func batteryIcon(_ level: Int) -> String {
        if level < 10 { return "battery.0percent" }
        if level < 25 { return "battery.25percent" }
        if level < 50 { return "battery.50percent" }
        if level < 75 { return "battery.75percent" }
        return "battery.100percent"
    }
}
