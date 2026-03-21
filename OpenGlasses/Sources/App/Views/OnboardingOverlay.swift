import SwiftUI

/// First-run overlay that guides new users through initial setup.
/// Shown when no API keys are configured and onboarding hasn't been completed.
struct OnboardingOverlay: View {
    @Binding var showSettings: Bool
    @Binding var isVisible: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // App icon / title
                VStack(spacing: 12) {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.cyan)

                    Text("Welcome to OpenGlasses")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }

                // Steps
                VStack(alignment: .leading, spacing: 20) {
                    stepRow(
                        number: 1,
                        icon: "eyeglasses",
                        title: "Connect Your Glasses",
                        subtitle: "Pair your Ray-Ban Meta glasses via the Meta AI app."
                    )

                    stepRow(
                        number: 2,
                        icon: "brain",
                        title: "Add Your AI Model",
                        subtitle: "Add an API key from Anthropic, OpenAI, Google, or others."
                    )

                    stepRow(
                        number: 3,
                        icon: "mic",
                        title: "Say Your Wake Word",
                        subtitle: "Say \"Hey OpenGlasses\" to start a conversation."
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // Actions
                VStack(spacing: 12) {
                    Button {
                        showSettings = true
                    } label: {
                        Text("Open Settings")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.cyan, in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        Config.setHasCompletedOnboarding(true)
                        withAnimation { isVisible = false }
                    } label: {
                        Text("Skip for Now")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to OpenGlasses. Three setup steps.")
    }

    private func stepRow(number: Int, icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.cyan)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(subtitle)")
    }
}
