import SwiftUI

/// Importing a model from a public repository: address, file, licence, and a last screen that says
/// exactly what will happen before anything is fetched.
///
/// The sheet draws what `LocalModelImportController` decides. Two rules it must not blur:
///
///  - **Refusals are shown verbatim.** The parser and the planner write their own sentences, and
///    those sentences deliberately never echo what was typed. Re-wording them here would lose both
///    the rule they name and that property.
///  - **Blockers disable; warnings permit.** The confirm button reads `canDownload`, which reads
///    the fit report. Nothing on this screen can talk a blocker into being advice.
struct LocalModelImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: LocalModelImportController
    @FocusState private var repositoryFieldFocused: Bool

    init(acquisition: LocalModelAcquisition) {
        _controller = StateObject(wrappedValue: LocalModelImportController(acquisition: acquisition))
    }

    /// Injection point for the suite and for previews.
    init(controller: @autoclosure @escaping () -> LocalModelImportController) {
        _controller = StateObject(wrappedValue: controller())
    }

    var body: some View {
        NavigationStack {
            List {
                repositorySection
                if case .failed(let message) = controller.stage {
                    Section {
                        OGStatusLabel(message, kind: .error, systemImage: "exclamationmark.triangle")
                    }
                }
                if controller.offer != nil {
                    fileSection
                    if !controller.projectorCandidates.isEmpty { projectorSection }
                }
                if let presentation = controller.fitPresentation {
                    licenceSection
                    confirmationSection(presentation)
                }
            }
            .ogFormStyle()
            .navigationTitle("Import a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: controller.stage) { _, stage in
                if case .started = stage { dismiss() }
            }
        }
    }

    // MARK: - Repository

    private var repositorySection: some View {
        Section {
            HStack {
                TextField("owner/repository", text: $controller.repositoryText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .focused($repositoryFieldFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await controller.resolve() } }
                    .accessibilityLabel("Model repository")
                    .accessibilityHint("Enter owner slash repository, or paste the repository's "
                                           + "web address.")
                if case .resolving = controller.stage {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Look up") {
                        repositoryFieldFocused = false
                        Task { await controller.resolve() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.repositoryText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Repository")
        } footer: {
            Text("Public repositories only, over https. The exact version is pinned before "
                     + "anything is downloaded, and every file is checked against its published "
                     + "checksum.")
        }
    }

    // MARK: - Files

    private var fileSection: some View {
        Section {
            ForEach(controller.weightsCandidates) { candidate in
                Button {
                    controller.choose(candidate.id)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.quantizationLabel ?? candidate.id)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(LocalModelImportController.candidateSubtitle(candidate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        OGSelectionCheck(controller.selectedCandidateID == candidate.id)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!candidate.isInstallable)
                .accessibilityLabel(LocalModelImportController.candidateSpokenLabel(candidate))
                .accessibilityAddTraits(controller.selectedCandidateID == candidate.id
                                            ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            Text("Choose a file")
        } footer: {
            Text(controller.offer?.requiresSelection == true
                     ? "Several quantizations are published. Smaller files use less memory and "
                         + "answer faster; larger ones answer better."
                     : "The recommended quantization is selected. Tap another to change it.")
        }
    }

    private var projectorSection: some View {
        Section {
            ForEach(controller.projectorCandidates) { candidate in
                LabeledContent(candidate.id,
                               value: LocalModelPresentation.formatBytes(candidate.byteCount))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Vision files in this repository")
        } footer: {
            Text("This repository also publishes vision projector files. This version of the app "
                     + "runs on-device models as text only, so they aren't installed.")
        }
    }

    // MARK: - Licence

    private var licenceSection: some View {
        Section {
            if let licence = controller.offer?.license {
                VStack(alignment: .leading, spacing: 6) {
                    Text(licence.displayName).font(.subheadline.weight(.semibold))
                    Text(licence.summary).font(.caption).foregroundStyle(.secondary)
                }
                if let url = controller.offer?.reference.webURL {
                    Link("Open the repository page", destination: url)
                        .font(.caption)
                }
            }
            if controller.requiresLicenceAcceptance {
                Toggle(isOn: $controller.licenceAccepted) {
                    Text("I accept this model's licence")
                }
                .onChange(of: controller.licenceAccepted) { _, _ in
                    controller.licenceAcceptanceChanged()
                }
                .accessibilityHint("Required before this model can be downloaded.")
            }
        } header: {
            Text("Licence")
        }
    }

    // MARK: - Confirmation

    @ViewBuilder
    private func confirmationSection(
        _ presentation: LocalModelPresentation.FitPresentation) -> some View {
        Section {
            ForEach(presentation.facts) { fact in
                LabeledContent(fact.label, value: fact.value)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(fact.label): \(fact.value)")
            }
            ForEach(Array(presentation.warningMessages.enumerated()), id: \.offset) { _, message in
                OGStatusLabel(message, kind: .warn)
            }
            ForEach(Array(presentation.blockerMessages.enumerated()), id: \.offset) { _, message in
                OGStatusLabel(message, kind: .error)
            }

            Button {
                Task { await controller.confirm() }
            } label: {
                Text("Download \(LocalModelPresentation.formatBytes(controller.fit?.downloadBytes ?? 0))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ogProminent)
            .disabled(!controller.canDownload)
            // The disabled reason is on the button, not only in the list above it: a person who
            // reaches the action first must hear why it will not move.
            .accessibilityHint(controller.canDownload
                                   ? "Starts the download. It continues in the background."
                                   : (presentation.blockerMessages.first
                                        ?? "This model can't be downloaded."))
        } header: {
            Text("Before downloading")
        } footer: {
            Text("Installing a model doesn't guarantee it will run: on-device models must use a "
                     + "supported architecture and chat template, and that's only known once it "
                     + "loads.")
        }
    }
}
