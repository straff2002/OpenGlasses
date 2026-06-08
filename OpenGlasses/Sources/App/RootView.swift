import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var showLaunchScreen = true

    var body: some View {
        ZStack {
            MainView()

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
        // High-impact action confirmation (prompt-injection backstop). Presented whenever a
        // destructive tool call is awaiting the user's approval in agent mode.
        .toolConfirmation(coordinator: appState.toolConfirmationCoordinator)
    }
}

/// Presents an Approve / Deny prompt for a pending high-impact tool call.
private struct ToolConfirmationModifier: ViewModifier {
    @ObservedObject var coordinator: ToolConfirmationCoordinator

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Confirm action",
            isPresented: Binding(
                get: { coordinator.pending != nil },
                set: { if !$0 { coordinator.resolve(false) } }
            ),
            titleVisibility: .visible,
            presenting: coordinator.pending
        ) { pending in
            Button("Approve", role: .destructive) { coordinator.resolve(true) }
            Button("Cancel", role: .cancel) { coordinator.resolve(false) }
        } message: { pending in
            Text(pending.summary)
        }
    }
}

private extension View {
    func toolConfirmation(coordinator: ToolConfirmationCoordinator) -> some View {
        modifier(ToolConfirmationModifier(coordinator: coordinator))
    }
}
