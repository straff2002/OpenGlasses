import SwiftUI

struct LaunchScreen: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.15),
                    Color(red: 0.05, green: 0.05, blue: 0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Glasses icon representation
                ZStack {
                    // Glasses frame
                    HStack(spacing: 16) {
                        // Left lens
                        Circle()
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 3)
                            .frame(width: 60, height: 60)
                        
                        // Bridge
                        Rectangle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 20, height: 3)
                        
                        // Right lens
                        Circle()
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 3)
                            .frame(width: 60, height: 60)
                    }
                    .scaleEffect(isAnimating ? 1.0 : 0.8)
                    .opacity(isAnimating ? 1.0 : 0.5)
                    
                    // Voice wave indicator
                    HStack(spacing: 4) {
                        ForEach(0..<5) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.blue.opacity(0.7))
                                .frame(width: 3, height: CGFloat.random(in: 10...30))
                                .animation(
                                    Animation.easeInOut(duration: 0.5)
                                        .repeatForever()
                                        .delay(Double(index) * 0.1),
                                    value: isAnimating
                                )
                        }
                    }
                    .offset(y: 50)
                    .opacity(isAnimating ? 0.8 : 0)
                }
                .padding(.bottom, 20)
                
                // App name
                Text("OpenGlasses")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .opacity(isAnimating ? 1.0 : 0)
                
                // Tagline
                Text("Voice-Powered AI Assistant")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .opacity(isAnimating ? 1.0 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0)) {
                isAnimating = true
            }
        }
    }
}

#Preview {
    LaunchScreen()
}
