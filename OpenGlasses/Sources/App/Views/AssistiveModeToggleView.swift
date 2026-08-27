import SwiftUI

/// Compact toggle for Assistive Mode (A3), intended for the main bottom bar. Shows the active mode
/// (scene/social) and the latest advice line. Only meaningful when the Accessibility tier is enabled.
@MainActor
struct AssistiveModeToggleView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var service = AssistiveModeService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(spacing: 6) {
            Button {
                appState.toggleAssistiveMode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: service.isActive ? "eye.fill" : "eye")
                        .accessibilityHidden(true)
                    Text(service.isActive ? "Assistive: \(service.currentMode.rawValue.capitalized)" : "Assistive Mode")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(
                    service.isActive
                        ? AnyShapeStyle(OGTheme.tintedAccentLabel(accent))
                        : AnyShapeStyle(Color.secondary)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    service.isActive
                        ? accent.opacity(OGTheme.Opacity.accentPillFill)
                        : Color(.quaternarySystemFill),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                service.isActive
                    ? "Assistive Mode, \(service.currentMode.rawValue.capitalized), on"
                    : "Assistive Mode, off"
            )
            .accessibilityHint("Double-tap to toggle Assistive Mode.")

            if service.isActive, let advice = service.latestAdvice {
                Text(advice.advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: service.latestAdvice)
    }
}

#Preview {
    AssistiveModeToggleView()
        .environmentObject(AppState())
}
