import QuickLook
import SwiftUI

/// The Modes tab while Field Assist mode is on (Plan HB): the job, the vault, its scenarios, the
/// manuals, the way to Field Assist settings — and the other modes tucked under an accordion.
///
/// Thin on purpose. What a scenario tap does is `FieldAssistScenarioStart`'s, which manuals are
/// listed and when one can be asked is `FieldAssistManualShelf`'s, and whether this tab exists at
/// all is `ModesTabPresentation`'s.
struct FieldAssistModeTab: View {
    @ObservedObject var appState: AppState
    /// False under the edition's technician view: the organisation chose the persona.
    let showsOtherModes: Bool

    @ObservedObject private var sessions = FieldSessionService.shared
    @ObservedObject private var adminGate = AdminGate.shared
    @AppStorage("fieldAssistDefaultVaultId") private var faVaultId: String = "refrigeration"

    @State private var pendingScenario: Procedure?
    @State private var problem: String?
    /// Collapsed every time the tab is built — "minimised" is the resting state, not a preference.
    @State private var otherModesExpanded = false
    @State private var editingPersona: Persona?
    @State private var shelf: [FieldAssistManualShelf.Vault] = []
    @State private var previewURL: URL?
    @State private var askingManual: FieldAssistManualShelf.Manual?

    // MARK: - Facts

    private var openSession: FieldSession? {
        guard let session = sessions.activeSession, session.endedAt == nil,
              session.outcome != .cancelled else { return nil }
        return session
    }

    private func label(for session: FieldSession) -> String {
        session.jobReference.flatMap { $0.isEmpty ? nil : "Job \($0)" } ?? "the open job"
    }

    private var openJob: FieldAssistScenarioStart.OpenJob? {
        guard let session = openSession else { return nil }
        return .init(vaultId: session.vaultId,
                     vaultName: VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId,
                     label: label(for: session))
    }

    private var current: VaultManifest? { VaultRegistry.shared.manifest(id: faVaultId) }

    /// The vault switcher is the organisation's to lock when it locks Field Assist's settings.
    private var vaultLocked: Bool { adminGate.lock(.fieldAssist).isLocked }

    private var manuals: [FieldAssistManualShelf.Manual] {
        FieldAssistManualShelf.manuals(vaults: shelf, activeVaultId: faVaultId)
    }

    // MARK: - Body

    var body: some View {
        List {
            jobSection
            vaultSection
            scenariosSection
            manualsSection
            settingsSection
            if showsOtherModes { otherModesSections }
        }
        .navigationTitle("Field Assist")
        .listStyle(.insetGrouped)
        .ogFormStyle()
        .onAppear(perform: reloadShelf)
        .onChange(of: faVaultId) { _, _ in reloadShelf() }
        .quickLookPreview($previewURL)
        .sheet(item: $editingPersona) { persona in
            PersonaDetailView(persona: persona, appState: appState)
        }
        .sheet(item: $askingManual) { manual in
            ManualAskSheet(manual: manual) { question in ask(manual, question) }
        }
        .alert("Can't start that scenario",
               isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Job

    private var jobSection: some View {
        Section {
            Button {
                // The open job's page, or the start page — over the Jobs list (Plan HC).
                appState.openJobs(openSession == nil ? .newJob : .currentJob)
            } label: {
                FieldAssistTabRow(
                    symbol: openSession == nil ? "play.circle.fill" : "briefcase.fill",
                    title: openSession.map { "Resume \(label(for: $0))" } ?? "Start a job",
                    subtitle: openSession.map {
                        "\(VaultRegistry.shared.manifest(id: $0.vaultId)?.name ?? $0.vaultId) · "
                            + ($0.pausedAt == nil ? "In progress" : "Paused")
                    } ?? "On \(current?.name ?? faVaultId)")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Jobs tab.")
        } header: {
            Text("Job")
        }
    }

    // MARK: - Vault

    @ViewBuilder
    private var vaultSection: some View {
        let unlockedVaults = VaultRegistry.shared.allManifests.filter { VaultRegistry.shared.isUnlocked($0) }
        Section {
            if vaultLocked {
                FieldAssistTabRow(symbol: "books.vertical.fill", title: current?.name ?? "No vault",
                                  subtitle: "Set by \(ManagedLockReason.organization)")
            } else {
                Menu {
                    ForEach(unlockedVaults, id: \.id) { manifest in
                        Button {
                            faVaultId = manifest.id
                        } label: {
                            if faVaultId == manifest.id {
                                Label(manifest.name, systemImage: "checkmark")
                            } else {
                                Text(manifest.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        FieldAssistTabRow(symbol: "books.vertical.fill", title: current?.name ?? "Choose a vault",
                                          subtitle: "Vault for new jobs")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Vault for new jobs: \(current?.name ?? "none")")
                .accessibilityHint("Switches the vault new jobs start on.")
            }

            // The organisation chose the model on its phones — the same rule as the dock's model
            // tile under the edition.
            if !adminGate.isRestricted && !vaultLocked {
                Picker("Model for this vault", selection: Binding(
                    get: { Config.fieldAssistVaultModelId(for: faVaultId) ?? "" },
                    set: { newId in
                        // Linked to the vault and applied only while a job is running
                        // (`AppState.applyFieldSessionModel`).
                        Config.setFieldAssistVaultModelId(newId.isEmpty ? nil : newId, for: faVaultId)
                    }
                )) {
                    Text("Use current model").tag("")
                    ForEach(Config.savedModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
            }
        } header: {
            Text("Vault")
        } footer: {
            Text(adminGate.isRestricted || vaultLocked
                 ? "New jobs start on this vault."
                 : "New jobs start on this vault. A vault can link its own model, used only while a job is running.")
        }
    }

    // MARK: - Scenarios

    @ViewBuilder
    private var scenariosSection: some View {
        if let current {
            let procedures = ProcedureLibrary(store: VaultRegistry.shared.store(for: current)).all
            let unlocked = VaultRegistry.shared.isUnlocked(current)
            Section {
                if procedures.isEmpty {
                    Text("No guided scenarios in this vault — the assistant still answers from its reference files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(procedures) { proc in
                        Button {
                            let decision = FieldAssistScenarioStart.decide(
                                vaultId: current.id, vaultName: current.name,
                                vaultUnlocked: unlocked, openJob: openJob)
                            if case .blocked(let reason) = decision {
                                problem = reason
                            } else {
                                pendingScenario = proc
                            }
                        } label: {
                            scenarioRow(proc)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(scenarioSpoken(proc))
                        .accessibilityHint("Starts this scenario.")
                        .accessibilityAddTraits(.isButton)
                    }
                }
            } header: {
                Text("Scenarios")
            } footer: {
                Text(openJob == nil
                     ? "Tap a scenario to start a job on \(current.name) that runs it step by step."
                     : "Tap a scenario to run it in the open job.")
            }
            .confirmationDialog(
                "Run this scenario?",
                isPresented: Binding(get: { pendingScenario != nil },
                                     set: { if !$0 { pendingScenario = nil } }),
                titleVisibility: .visible,
                presenting: pendingScenario
            ) { proc in
                let decision = FieldAssistScenarioStart.decide(
                    vaultId: current.id, vaultName: current.name, vaultUnlocked: unlocked, openJob: openJob)
                if let button = decision.confirmButton(proc.title) {
                    Button(button) { run(proc, decision: decision) }
                }
                Button("Cancel", role: .cancel) { pendingScenario = nil }
            } message: { proc in
                Text(FieldAssistScenarioStart.decide(
                    vaultId: current.id, vaultName: current.name, vaultUnlocked: unlocked, openJob: openJob)
                    .message(proc.title, vaultName: current.name))
            }
        }
    }

    private func scenarioRow(_ proc: Procedure) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(proc.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                if let desc = proc.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(stepCount(proc))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(AccentColors.aiCoral)
                .accessibilityHidden(true)
        }
        .frame(minHeight: OGMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func stepCount(_ proc: Procedure) -> String {
        "\(proc.steps.count) step\(proc.steps.count == 1 ? "" : "s")"
    }

    private func scenarioSpoken(_ proc: Procedure) -> String {
        [proc.title, proc.description, stepCount(proc)].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// Start or run the scenario. A job is started through the job flow — the one chokepoint for a
    /// job's conversation — and an open job is never ended here.
    private func run(_ proc: Procedure, decision: FieldAssistScenarioStart) {
        pendingScenario = nil
        do {
            switch decision {
            case .startJob:
                _ = try JobTabModel(host: sessions, flow: appState.guidedJobFlow).startJob()
                // A vault id names the customer whose procedures are loaded, so it is fingerprinted;
                // the procedure, that customer's own document catalogue, is not logged at all.
                PrivacyLog.app(.fieldSessionStarted, item: PrivateIdentifier(faVaultId))
                _ = try sessions.startProcedure(id: proc.id)
            case .runInOpenJob:
                _ = try sessions.startProcedure(id: proc.id)
            case .blocked(let reason):
                problem = reason
                return
            }
            appState.openJobs(.currentJob)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Manuals

    @ViewBuilder
    private var manualsSection: some View {
        let all = manuals
        Section {
            if all.isEmpty {
                Text("No manuals yet. Add your manufacturers' manuals to a vault under Settings › Field Assist › Custom Vaults.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(all.prefix(FieldAssistManualShelf.homeLimit)) { manual in
                    ManualShelfRow(manual: manual,
                                   canAsk: FieldAssistManualShelf.canAsk(manual, openJobVaultId: openSession?.vaultId),
                                   onOpen: { open(manual) },
                                   onAsk: { askingManual = manual })
                }
                if all.count > FieldAssistManualShelf.homeLimit {
                    NavigationLink {
                        FieldAssistManualsView(appState: appState, shelf: shelf, activeVaultId: faVaultId,
                                               openJobVaultId: openSession?.vaultId)
                    } label: {
                        Text("All manuals (\(all.count))")
                            .frame(minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    }
                }
            }
        } header: {
            Text("Manuals")
        } footer: {
            if !all.isEmpty {
                Text(openSession == nil
                     ? "Tap a manual to open it. Ask a manual a question during a job on its vault."
                     : "Tap a manual to open it, or Ask to look something up in it for this job.")
            }
        }
    }

    private func open(_ manual: FieldAssistManualShelf.Manual) {
        guard let manifest = VaultRegistry.shared.manifest(id: manual.vaultId),
              let document = manifest.documents.first(where: { $0.file == manual.file }),
              let url = FieldAssistManualFiles.url(manifest: manifest, document: document) else {
            problem = "\(manual.title) can't be opened — its file is no longer on this phone."
            return
        }
        previewURL = url
    }

    private func ask(_ manual: FieldAssistManualShelf.Manual, _ question: String) {
        askingManual = nil
        guard let prompt = FieldAssistManualShelf.askPrompt(manual: manual, question: question) else { return }
        appState.requestedTab = .voice
        Task { await appState.sendTextMessage(prompt) }
    }

    private func reloadShelf() {
        shelf = FieldAssistManualFiles.shelf()
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section {
            Button {
                appState.openSettings(.fieldAssist)
            } label: {
                FieldAssistTabRow(symbol: "gearshape.fill", title: "Field Assist settings",
                                  subtitle: "Vaults, reports, licence and job options")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Field Assist in Settings.")
        }
    }

    // MARK: - Other modes

    @ViewBuilder
    private var otherModesSections: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { otherModesExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    FieldAssistTabRow(symbol: MainTab.modes.systemImage, title: "Other modes",
                                      subtitle: appState.activePersona.map { "Using \($0.name)" }
                                        ?? "Personas and their voices")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(otherModesExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Other modes. " + (appState.activePersona.map { "Using \($0.name)" } ?? ""))
            .accessibilityValue(otherModesExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(otherModesExpanded ? "Hides the other modes." : "Shows the other modes.")
            .accessibilityAddTraits(.isButton)
        } footer: {
            Text("Picking a mode changes the voice, model and prompt. Field Assist stays on.")
        }

        if otherModesExpanded {
            PersonaModeSections(appState: appState) { editingPersona = $0 }
        }
    }
}

/// One row of the Field Assist tab: a tinted symbol, a title and a quieter line.
struct FieldAssistTabRow: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(AccentColors.aiCoral)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    // Explicit rather than `.secondary`: inside a `Menu` label the hierarchical
                    // style picks up the tint, and the quieter line read as a link.
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: OGMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
