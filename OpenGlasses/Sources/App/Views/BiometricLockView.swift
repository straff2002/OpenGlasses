import SwiftUI
import LocalAuthentication

/// Full-screen biometric lock overlay for HIPAA mode.
/// Shown when the app returns from background and HIPAA mode is enabled.
struct BiometricLockView: View {
    @Binding var isLocked: Bool
    @State private var authFailed = false
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(AppAccent.aiCoral)

                Text("OpenGlasses")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text("HIPAA Protected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if authFailed {
                    Text("Authentication failed. Tap to try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }

                Button {
                    authenticate()
                } label: {
                    Label("Unlock", systemImage: biometricIcon)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(AppAccent.aiCoral)
                        .clipShape(Capsule())
                }
                .padding(.top, 16)
                .disabled(isAuthenticating)
            }
        }
        .onAppear {
            authenticate()
        }
    }

    private func authenticate() {
        isAuthenticating = true
        authFailed = false

        let context = LAContext()
        var error: NSError?

        // Try biometrics first, fall back to passcode
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        context.evaluatePolicy(policy, localizedReason: "Unlock OpenGlasses to access protected health data") { success, _ in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isLocked = false
                    }
                } else {
                    authFailed = true
                }
            }
        }
    }

    private var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open.fill"
        }
    }
}
