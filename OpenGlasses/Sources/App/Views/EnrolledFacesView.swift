import SwiftUI

/// Devices & Privacy › Glasses › Enrolled Faces (Plan HP P2 item 8).
///
/// Face recognition is opt-in: this screen holds its switch, says what it does and that the person
/// isn't told, lists who is enrolled with when they were last seen, and forgets them — one at a time
/// by swiping, or everyone at once. It lives under Glasses because the tool only runs on the glasses
/// camera (`PhoneCapturePolicy`: `.glassesOnly`).
///
/// Forgetting stays reachable whatever an organisation has pinned: a profile may switch recognition
/// off, and erasing a stranger's face print must never depend on being allowed to change a setting.
struct EnrolledFacesView: View {
    @ObservedObject var faceService: FaceRecognitionService
    @ObservedObject private var adminGate = AdminGate.shared

    @State private var enabled = Config.faceRecognitionEnabled
    @State private var confirmingForgetEveryone = false

    private var switchPresentation: SettingPresentation {
        adminGate.presentation(.key(.faceRecognitionEnabled))
    }

    var body: some View {
        Form {
            Section {
                if switchPresentation.isShown {
                    Toggle("Face Recognition", isOn: $enabled)
                        .tint(AppAccent.color)
                        .disabled(!switchPresentation.isEditable)
                        .onChange(of: enabled) { _, on in
                            Config.faceRecognitionEnabled = on
                            // Read back: an organisation's ceiling refuses the write.
                            enabled = Config.faceRecognitionEnabled
                            if !enabled, faceService.isActive { faceService.stop() }
                        }
                    ManagedSettingNote(key: .faceRecognitionEnabled)
                }
            } footer: {
                Text(EnrolledFacesPresentation.optInFooter)
            }

            Section {
                let rows = EnrolledFacesPresentation.rows(for: faceService.knownFaces)
                if rows.isEmpty {
                    Text(EnrolledFacesPresentation.emptyList)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(row.lastSeen)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                        .accessibilityHint("Swipe up or down for actions, including Forget.")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Forget", role: .destructive) {
                                _ = faceService.forgetFace(name: row.name)
                            }
                        }
                        .accessibilityAction(named: Text("Forget")) {
                            _ = faceService.forgetFace(name: row.name)
                        }
                    }
                }
            } header: {
                Text("Enrolled")
            } footer: {
                Text("Swipe left on a name to forget that person. Face prints stay on this phone: they are never uploaded, and they are left out of backups.")
            }

            if !faceService.knownFaces.isEmpty {
                Section {
                    Button("Forget Everyone", role: .destructive) {
                        confirmingForgetEveryone = true
                    }
                }
            }
        }
        .navigationTitle("Enrolled Faces")
        .ogFormStyle()
        .onAppear { enabled = Config.faceRecognitionEnabled }
        .confirmationDialog(
            EnrolledFacesPresentation.forgetEveryoneQuestion(count: faceService.knownFaces.count),
            isPresented: $confirmingForgetEveryone,
            titleVisibility: .visible
        ) {
            Button("Forget Everyone", role: .destructive) {
                faceService.forgetAllFaces()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
