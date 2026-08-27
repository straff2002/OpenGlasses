import SwiftUI

struct LaunchScreen: View {
    @State private var isAnimating = false
    @State private var glowPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The warm app canvas, not stock system background — the launch
            // screen is the first thing seen, so it should already look like
            // the rest of the app rather than handing off to it a beat later.
            OGTheme.canvas
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
                        // Reduce Motion: the glow fades up once and stays put
                        // instead of breathing for as long as the screen is up.
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.8)
                                : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: glowPulse
                        )

                    // Vector logo — template-rendered so it picks up the coral tint.
                    Image("OpenGlassesLogo")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(AppAccent.aiCoral)
                        .frame(maxWidth: 240)
                        // Reduce Motion turns the entrance into a plain fade.
                        .scaleEffect(reduceMotion || isAnimating ? 1.0 : 0.85)
                        .opacity(isAnimating ? 1.0 : 0)
                }

                Spacer()
                    .frame(height: 32)

                Text("OpenGlasses")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .opacity(isAnimating ? 1.0 : 0)

                Text("Voice-Powered AI Assistant")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(OGTheme.secondaryLabel)
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
