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
                            Link(destination: URL(string: "openglasses://connect")!) {
                                Label {
                                    Text("Connect")
                                } icon: {
                                    LogoIcon(size: 12)
                                }
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(.green.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    LogoIcon(size: 14)
                        .foregroundStyle(context.state.isConnected ? AccentColors.aiCoral : .gray)
                    if let battery = context.state.batteryLevel {
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
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    LogoIcon(size: 30)
                        .foregroundStyle(.white)
                    Circle()
                        .fill(context.state.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(statusText(for: context.state))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
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
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(5)
                                .background(Circle().fill(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        statusIcon(for: context.state)
                            .foregroundStyle(statusColor(for: context.state))
                    }

                    if !context.state.lastResponseSnippet.isEmpty {
                        Text(context.state.lastResponseSnippet)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }
            }

            // Quick actions — always shown so the Lock Screen stays useful even when the
            // glasses are disconnected (most actions just open the app via deep link).
            actionButtons(for: context.state, compact: false)
            if !context.state.isConnected {
                Link(destination: URL(string: "openglasses://connect")!) {
                    Label("Connect Glasses", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.10), in: Capsule())
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.6))
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
    /// then a generic Ask/Photo fallback. Capped at 4 for the chunky grid.
    private func actionItems(for state: GlassesActivityAttributes.ContentState) -> [ActionItem] {
        if !state.quickActionButtons.isEmpty {
            return state.quickActionButtons.prefix(4).map {
                ActionItem(id: $0.id, label: $0.label, icon: $0.icon,
                           url: URL(string: "openglasses://quickaction/\($0.id)")!,
                           accent: $0.id == "field-assist")
            }
        } else if !state.personaButtons.isEmpty {
            return state.personaButtons.prefix(4).map {
                ActionItem(id: $0.id, label: $0.name, icon: "person.fill",
                           url: URL(string: "openglasses://persona/\($0.id)")!, accent: false)
            }
        } else {
            return [
                ActionItem(id: "ask", label: "Ask", icon: "mic.fill",
                           url: URL(string: "openglasses://action/ask")!, accent: true),
                ActionItem(id: "photo", label: "Photo", icon: "camera.fill",
                           url: URL(string: "openglasses://action/photo")!, accent: false),
            ]
        }
    }

    @ViewBuilder
    private func actionButtons(for state: GlassesActivityAttributes.ContentState, compact: Bool) -> some View {
        let items = actionItems(for: state)
        if compact {
            // Dynamic Island: slim single row (space-constrained).
            HStack(spacing: 6) {
                ForEach(items.prefix(3)) { item in
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
        } else {
            // Lock Screen: chunky capsule buttons, two per row.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if items.indices.contains(0) { chunkyButton(items[0]) }
                    if items.indices.contains(1) { chunkyButton(items[1]) }
                }
                if items.count > 2 {
                    HStack(spacing: 8) {
                        chunkyButton(items[2])
                        if items.indices.contains(3) {
                            chunkyButton(items[3])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chunkyButton(_ item: ActionItem) -> some View {
        let tint: Color = item.accent ? AccentColors.aiCoral : .white
        Link(destination: item.url) {
            HStack(spacing: 7) {
                Image(systemName: item.icon)
                    .font(.callout.weight(.semibold))
                Text(item.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(tint.opacity(item.accent ? 0.30 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(item.accent ? 0.55 : 0.18), lineWidth: 1))
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
