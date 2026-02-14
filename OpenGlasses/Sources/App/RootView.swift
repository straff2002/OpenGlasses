import SwiftUI

struct RootView: View {
    @State private var showLaunchScreen = true
    
    var body: some View {
        ZStack {
            ContentView()
            
            if showLaunchScreen {
                LaunchScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            // Show launch screen for 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.5)) {
                    showLaunchScreen = false
                }
            }
        }
    }
}
