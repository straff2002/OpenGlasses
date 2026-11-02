import SwiftUI

/// The Blur Bystander Faces switch, for a settings form (Plan KH): Hardware & Privacy and the Live
/// Streaming section show this same row. It writes as it changes, so a value held by one screen can
/// never overwrite a change made on another.
struct BystanderBlurSwitch: View {
    let appState: AppState
    @ObservedObject private var filter: PrivacyFilterService
    @ObservedObject private var adminGate = AdminGate.shared
    @State private var confirmingOff = false

    init(appState: AppState) {
        self.appState = appState
        filter = appState.privacyFilter
    }

    private var changeable: Bool { BystanderBlurControl.isChangeable(in: adminGate.settingsContext) }

    var body: some View {
        InfoToggle(
            title: "Blur Bystander Faces",
            isOn: Binding(get: { filter.isEnabled }, set: request),
            info: "Uses Apple's on-device Vision framework to detect faces in the camera feed and applies a Gaussian blur before a frame leaves your device — AI providers, video recordings, live broadcasts, browser streaming, and expert calls. Detection and blurring happen entirely on-device. On video, faces are found several times a second and the blur follows them in between, so someone stepping into shot can be briefly visible before the next detection catches them. Faces you have enrolled for recognition are matched on the unblurred frame, so recognition keeps working."
        )
        // Plan HA C4: pinned on, this is drawn read-only rather than hidden, even for the
        // technician — a bystander protection somebody on the phone must be able to see is
        // on (`SettingsVisibilityPolicy.alwaysShown`).
        .disabled(!changeable)
        .bystanderBlurOffConfirmation(isPresented: $confirmingOff, appState: appState)

        ManagedSettingNote(key: .privacyFilterEnabled)
        if !changeable, !PolicyEnvelope.isLocked(.privacyFilterEnabled),
           let organization = PolicyEnvelope.organizationName {
            ManagedLockNote(organization: organization)
        }
    }

    private func request(_ wanted: Bool) {
        switch BystanderBlurControl.request(wanted, isOn: filter.isEnabled, changeable: changeable,
                                            isLive: appState.isStreamingLive) {
        case .none: break
        case .set(let enabled): appState.setBystanderBlur(enabled)
        case .confirmTurningOff: confirmingOff = true
        }
    }
}

extension View {
    /// The question asked before the blur goes off during a live stream.
    func bystanderBlurOffConfirmation(isPresented: Binding<Bool>, appState: AppState) -> some View {
        alert("Turn off the blur while live?", isPresented: isPresented) {
            Button("Turn Off Blur", role: .destructive) { appState.setBystanderBlur(false) }
            Button("Keep Blur On", role: .cancel) {}
        } message: {
            Text("Faces from the glasses camera stop being blurred straight away, and viewers will see them. The blur stays off everywhere until you turn it back on.")
        }
    }
}
