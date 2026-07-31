import SwiftUI

/// Plan BX P2 — Settings → Skill Packs: installed packs (kill switch, settings, uninstall) and
/// the signed catalog (browse + one-tap install, hardware-gated).
struct SkillPacksSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ViewModel()

    var body: some View {
        List {
            installedSection
            catalogSection
            developerSection
        }
        .navigationTitle("Skill Packs")
        .task { await viewModel.bind(appState: appState) }
    }

    // MARK: Installed

    @ViewBuilder private var installedSection: some View {
        Section {
            if appState.skillPackStore.installedPacks.isEmpty {
                Text("No skill packs installed yet. Install one from the catalog below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(appState.skillPackStore.installedPacks) { pack in
                installedRow(pack)
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("A pack's actions become voice commands the assistant can use. Turning a pack off removes its actions immediately; its settings are kept.")
        }
    }

    @ViewBuilder private func installedRow(_ pack: SkillPackStore.InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { pack.enabled },
                    set: { enabled in
                        appState.skillPackStore.setEnabled(enabled, id: pack.id)
                        appState.refreshSkillPackTools()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.name)
                        Text("v\(pack.activeVersion) · \(pack.actionCount) action\(pack.actionCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !pack.signatureVerified {
                Label("Unsigned — developer install", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if pack.decodeSummary != "clean" {
                Label(pack.decodeSummary, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let manifest = manifest(for: pack), !manifest.settings.isEmpty {
                NavigationLink {
                    SkillPackSettingsSheet(packId: pack.id, packName: pack.name,
                                           declarations: manifest.settings)
                } label: {
                    Text("Pack Settings")
                        .font(.caption)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let manifest = manifest(for: pack) {
                    SkillPackSettings.removeAll(packId: pack.id, declarations: manifest.settings)
                }
                appState.skillPackStore.remove(id: pack.id)
                appState.refreshSkillPackTools()
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }
    }

    private func manifest(for pack: SkillPackStore.InstalledPack) -> SkillPackManifest? {
        appState.skillPackStore.activeManifests().first { $0.id == pack.id }
    }

    // MARK: Catalog

    @ViewBuilder private var catalogSection: some View {
        Section {
            switch viewModel.catalogState {
            case .idle, .loading:
                HStack { ProgressView(); Text("Loading catalog…").foregroundStyle(.secondary) }
            case .failed(let reason):
                Label(reason, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await viewModel.reload() } }
            case .loaded(let entries):
                if entries.isEmpty {
                    Text("The catalog is empty right now.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    catalogRow(entry)
                }
            }
        } header: {
            Text("Catalog")
        } footer: {
            Text("Packs are signed and verified before anything installs. The catalog itself is signed — an unverifiable index is refused outright.")
        }
    }

    @ViewBuilder private func catalogRow(_ entry: SkillPackCatalogEntry) -> some View {
        let availability = SkillPackHardwareGate.availability(
            requirements: entry.hardware,
            hasCamera: appState.isConnected,
            hasDisplay: appState.glassesDisplay.hasDisplayCapability)
        let installedVersion = appState.skillPackStore.installedPacks
            .first { $0.id == entry.id }?.activeVersion

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                installControl(entry: entry, availability: availability,
                               installedVersion: installedVersion)
            }
            if case .blocked(let missing) = availability {
                Label("Needs \(missing.joined(separator: ", ")) — connect glasses first",
                      systemImage: "eyeglasses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .degraded(let missing) = availability {
                Label("Works best with \(missing.joined(separator: ", "))", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let reason)? = viewModel.installStates[entry.id] {
                Label(reason, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func installControl(
        entry: SkillPackCatalogEntry,
        availability: SkillPackHardwareGate.Availability,
        installedVersion: String?
    ) -> some View {
        switch viewModel.installStates[entry.id] {
        case .downloading?, .installing?:
            ProgressView()
        default:
            if installedVersion == entry.version {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(installedVersion == nil ? "Install" : "Update") {
                    Task { await viewModel.install(entry) }
                }
                .buttonStyle(.bordered)
                .disabled({ if case .blocked = availability { return true }; return false }())
            }
        }
    }

    // MARK: Developer

    @ViewBuilder private var developerSection: some View {
        Section {
            Toggle("Developer Mode", isOn: Binding(
                get: { Config.skillPackDevModeEnabled },
                set: { Config.setSkillPackDevModeEnabled($0) }
            ))
        } header: {
            Text("Developer")
        } footer: {
            Text("Allows installing unsigned packs while building your own. Unsigned packs are labeled on their row. The catalog's own signature is always enforced.")
        }
    }

    // MARK: - View model

    @MainActor
    final class ViewModel: ObservableObject {
        @Published var catalogState: SkillPackCatalogService.CatalogState = .idle
        @Published var installStates: [String: SkillPackCatalogService.InstallState] = [:]

        private var service: SkillPackCatalogService?
        private var mirrors: [Task<Void, Never>] = []

        func bind(appState: AppState) async {
            guard service == nil else { return }
            let service = SkillPackCatalogService(
                store: appState.skillPackStore,
                onInstalled: { [weak appState] in appState?.refreshSkillPackTools() })
            self.service = service
            // Mirror the service's published state into this view model.
            mirrors.append(Task { [weak self] in
                for await value in service.$catalogState.values { self?.catalogState = value }
            })
            mirrors.append(Task { [weak self] in
                for await value in service.$installStates.values { self?.installStates = value }
            })
            await service.loadCatalog()
        }

        func reload() async { await service?.loadCatalog() }
        func install(_ entry: SkillPackCatalogEntry) async { await service?.install(entry) }

        deinit { for task in mirrors { task.cancel() } }
    }
}

/// Renders a pack's typed setting declarations — settings-as-schema, no per-pack UI code.
struct SkillPackSettingsSheet: View {
    let packId: String
    let packName: String
    let declarations: [SkillPackManifest.SettingDeclaration]

    var body: some View {
        Form {
            ForEach(declarations, id: \.key) { declaration in
                control(for: declaration)
            }
        }
        .navigationTitle(packName)
    }

    @ViewBuilder private func control(for declaration: SkillPackManifest.SettingDeclaration) -> some View {
        let label = declaration.label ?? declaration.key
        switch declaration.type {
        case "toggle":
            Toggle(label, isOn: Binding(
                get: { SkillPackSettings.value(packId: packId, key: declaration.key) == "true" },
                set: { SkillPackSettings.setValue($0 ? "true" : "false", packId: packId, key: declaration.key) }
            ))
        case "select":
            Picker(label, selection: Binding(
                get: { SkillPackSettings.value(packId: packId, key: declaration.key) ?? declaration.options?.first ?? "" },
                set: { SkillPackSettings.setValue($0, packId: packId, key: declaration.key) }
            )) {
                ForEach(declaration.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        case "number":
            TextField(label, text: valueBinding(declaration))
                .keyboardType(.decimalPad)
        default:   // "text" and anything unrecognized renders as free text — degrade, don't hide
            TextField(label, text: valueBinding(declaration))
        }
    }

    private func valueBinding(_ declaration: SkillPackManifest.SettingDeclaration) -> Binding<String> {
        Binding(
            get: { SkillPackSettings.value(packId: packId, key: declaration.key) ?? "" },
            set: { SkillPackSettings.setValue($0.isEmpty ? nil : $0, packId: packId, key: declaration.key) }
        )
    }
}
