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
            // Lock Screen presentation
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "eyeglasses")
                        .font(.title2)
                        .foregroundStyle(context.state.isConnected ? .green : .gray)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusIcon(for: context.state)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusText(for: context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !context.state.lastResponseSnippet.isEmpty {
                            Text(context.state.lastResponseSnippet)
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "eyeglasses")
                    .foregroundStyle(context.state.isConnected ? .cyan : .gray)
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
        HStack(spacing: 12) {
            // Glasses icon with connection dot
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
        .padding(16)
        .background(Color.black.opacity(0.6))
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
}
