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

            // Quick-launch buttons or Connect button
            if context.state.isConnected {
                actionButtons(for: context.state, compact: false)
            } else {
                Link(destination: URL(string: "openglasses://connect")!) {
                    Label {
                        Text("Connect & Talk")
                    } icon: {
                        LogoIcon(size: 16)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Action Buttons

    /// Shows persona buttons if available, otherwise quick action buttons.
    @ViewBuilder
    private func actionButtons(for state: GlassesActivityAttributes.ContentState, compact: Bool) -> some View {
        let fontSize: Font = compact ? .caption2.weight(.medium) : .caption.weight(.medium)
        let vPadding: CGFloat = compact ? 4 : 6
        let cornerRadius: CGFloat = compact ? 6 : 8

        HStack(spacing: compact ? 6 : 8) {
            if !state.personaButtons.isEmpty {
                ForEach(state.personaButtons, id: \.id) { persona in
                    Link(destination: URL(string: "openglasses://persona/\(persona.id)")!) {
                        Text(persona.name)
                            .font(fontSize)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, vPadding)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: cornerRadius))
                    }
                }
            } else if !state.quickActionButtons.isEmpty {
                ForEach(state.quickActionButtons, id: \.id) { action in
                    Link(destination: URL(string: "openglasses://quickaction/\(action.id)")!) {
                        Label(action.label, systemImage: action.icon)
                            .font(fontSize)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, vPadding)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: cornerRadius))
                    }
                }
            } else {
                // Fallback: generic actions
                Link(destination: URL(string: "openglasses://action/ask")!) {
                    Label("Ask", systemImage: "mic.fill")
                        .font(fontSize)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, vPadding)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: cornerRadius))
                }
                Link(destination: URL(string: "openglasses://action/photo")!) {
                    Label("Photo", systemImage: "camera.fill")
                        .font(fontSize)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, vPadding)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: cornerRadius))
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
