import SwiftUI

/// Model-editor rows for the Vertex-AI Gemini provider (Plan AI): the GCP client/project/region
/// fields every Vertex URL needs, plus the Google sign-in state. Unlike the paste-code flows
/// (`OAuthSignInRows`), Google requires a real browser session, so the button drives
/// `GoogleOAuthService.signIn()` (`ASWebAuthenticationSession`) directly.
struct GoogleSignInRows: View {
    var onChange: () -> Void = {}

    @ObservedObject private var google = GoogleOAuthService.shared
    @State private var clientID = Config.googleOAuthClientID
    @State private var projectID = Config.vertexProjectID
    @State private var region = Config.vertexRegion
    @State private var signingIn = false
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 44

    var body: some View {
        TextField("GCP OAuth Client ID (…apps.googleusercontent.com)", text: $clientID)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minHeight: rowMinHeight)
            .onChange(of: clientID) { _, value in Config.setGoogleOAuthClientID(value) }

        TextField("GCP Project ID", text: $projectID)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minHeight: rowMinHeight)
            .onChange(of: projectID) { _, value in
                Config.setVertexProjectID(value)
                onChange()
            }

        Picker("Region", selection: $region) {
            ForEach(VertexAI.regions, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: region) { _, value in
            Config.setVertexRegion(value)
            onChange()
        }

        if google.isConnected {
            HStack(spacing: OGMetrics.rowSpacing) {
                OGStatusLabel("Google account connected", kind: .ok)
                Spacer(minLength: 8)
                Button("Sign Out", role: .destructive) {
                    google.signOut()
                    onChange()
                }
                .buttonStyle(.borderless)
            }
            .frame(minHeight: rowMinHeight)

            Text("Requests authenticate with OAuth on your GCP project — no API key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button {
                Task {
                    signingIn = true
                    _ = await google.signIn()
                    signingIn = false
                    onChange()
                }
            } label: {
                HStack(spacing: 8) {
                    if signingIn {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .accessibilityHidden(true)
                        Text("Sign in with Google")
                    }
                }
                .frame(minHeight: rowMinHeight)
            }
            .disabled(signingIn || GoogleOAuth.callbackScheme(clientID: clientID) == nil)
            .accessibilityLabel(signingIn ? "Connecting" : "Sign in with Google")

            if GoogleOAuth.callbackScheme(clientID: clientID) == nil {
                Text("Create an iOS OAuth client in your GCP project (APIs & Services → Credentials) and paste its client ID above to enable sign-in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let error = google.lastError {
            OGStatusLabel(error, kind: .error)
        }
    }
}
