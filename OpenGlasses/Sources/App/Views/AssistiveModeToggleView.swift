import SwiftUI

/// Compact toggle for Assistive Mode (A3), intended for the main bottom bar. Shows the active mode
/// (scene/social) and the latest advice line. Only meaningful when the Accessibility tier is enabled.
@MainActor
struct AssistiveModeToggleView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var service = AssistiveModeService.shared

    var body: some View {
        VStack(spacing: 6) {
            Button {
                appState.toggleAssistiveMode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: service.isActive ? "eye.fill" : "eye")
                    Text(service.isActive ? "Assistive: \(service.currentMode.rawValue.capitalized)" : "Assistive Mode")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(service.isActive ? AppAccent.color.opacity(0.25) : Color.secondary.opacity(0.15))
                )
                .overlay(
                    Capsule().stroke(service.isActive ? AppAccent.color : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)

            if service.isActive, let advice = service.latestAdvice {
                Text(advice.advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.latestAdvice)
    }
}

#Preview {
    AssistiveModeToggleView()
        .environmentObject(AppState())
}
