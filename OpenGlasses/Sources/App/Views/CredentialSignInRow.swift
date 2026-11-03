import SwiftUI

/// The status card's sign-in row (Plan KL P0): while the assistant model has no usable sign-in or
/// key, one tap to the setting that fixes it. The spoken notice says why once; this stays until it
/// is fixed. Zero height while the model is ready — it carries its own gap above it, so the card's
/// module costs nothing extra when the row is absent.
struct CredentialSignInRow: View {
    @ObservedObject var llmService: LLMService
    let onOpen: () -> Void
    // Observed so the row goes the moment a sign-in completes, and comes back on a sign-out.
    @ObservedObject private var claudeOAuth = ClaudeOAuthService.shared
    @ObservedObject private var chatgptOAuth = ChatGPTOAuthService.shared
    @ObservedObject private var googleOAuth = GoogleOAuthService.shared
    @ObservedObject private var xaiOAuth = XAIOAuthService.shared

    var body: some View {
        // `activeModelName` is read so a model switch or a saved edit redraws the row.
        let _ = llmService.activeModelName
        let prompt = CredentialSignInPrompt.resolve(
            model: Config.activeModel,
            claudeConnected: claudeOAuth.isConnected, chatgptConnected: chatgptOAuth.isConnected,
            googleConnected: googleOAuth.isConnected, xaiConnected: xaiOAuth.isConnected)
        ZStack {
            if let prompt {
                Button(prompt.title, action: onOpen)
                    .buttonStyle(.bordered)
                    .accessibilityLabel(prompt.title)
                    .accessibilityHint(prompt.accessibilityHint)
                    .padding(.top, DockGridMetrics.moduleGap)
                    .transition(.opacity)
            }
        }
    }
}
