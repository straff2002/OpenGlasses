import SwiftUI

struct LaunchScreen: View {
    @State private var isAnimating = false
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            // Sit on the system UI background — adapts to light/dark mode.
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    // Soft coral glow behind the logo
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    AppAccent.aiCoral.opacity(glowPulse ? 0.30 : 0.10),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 40,
                                endRadius: 220
                            )
                        )
                        .frame(width: 420, height: 420)
                        .animation(
                            .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: glowPulse
                        )

                    // Vector logo — template-rendered so it picks up the coral tint.
                    Image("OpenGlassesLogo")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(AppAccent.aiCoral)
                        .frame(maxWidth: 240)
                        .scaleEffect(isAnimating ? 1.0 : 0.85)
                        .opacity(isAnimating ? 1.0 : 0)
                }

                Spacer()
                    .frame(height: 32)

                Text("OpenGlasses")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .opacity(isAnimating ? 1.0 : 0)

                Text("Voice-Powered AI Assistant")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .opacity(isAnimating ? 1.0 : 0)

                Spacer()
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                isAnimating = true
            }
            glowPulse = true
        }
    }
}

#Preview {
    LaunchScreen()
}
