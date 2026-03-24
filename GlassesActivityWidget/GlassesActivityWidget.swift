import WidgetKit
import SwiftUI
import ActivityKit

@main
struct GlassesActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlassesActivityWidget()
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
                        Image(systemName: "eyeglasses")
                            .font(.title2)
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
                        // Quick-launch buttons: personas first, then quick actions
                        actionButtons(for: context.state, compact: true)
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    Image(systemName: "eyeglasses")
                        .foregroundStyle(context.state.isConnected ? .cyan : .gray)
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
                Image(systemName: "eyeglasses")
                    .foregroundStyle(context.state.isConnected ? .cyan : .gray)
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<GlassesActivityAttributes>) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "eyeglasses")
                        .font(.title)
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

            // Quick-launch buttons
            if context.state.isConnected {
                actionButtons(for: context.state, compact: false)
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
        if state.isListening { return .cyan }
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
