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

    var body: some View {
        TextField("GCP OAuth Client ID (…apps.googleusercontent.com)", text: $clientID)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: clientID) { _, value in Config.setGoogleOAuthClientID(value) }

        TextField("GCP Project ID", text: $projectID)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
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
            HStack {
                Label("Google account connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Sign Out") {
                    google.signOut()
                    onChange()
                }
                .foregroundStyle(.red)
            }
            Text("Requests authenticate with OAuth on your GCP project — no API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button {
                Task {
                    signingIn = true
                    _ = await google.signIn()
                    signingIn = false
                    onChange()
                }
            } label: {
                if signingIn {
                    ProgressView()
                } else {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .disabled(signingIn || GoogleOAuth.callbackScheme(clientID: clientID) == nil)
            if GoogleOAuth.callbackScheme(clientID: clientID) == nil {
                Text("Create an iOS OAuth client in your GCP project (APIs & Services → Credentials) and paste its client ID above to enable sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let error = google.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
