import SwiftUI

// Plan KA P1 — roles. One picker per job (Assistant, Vision, Voice, Live, Dictation), each listing
// every saved key's models of the job's kind plus the job's on-phone options, and the "this key
// can also…" card a newly added key shows. The decisions are `ModelRoleCatalog`'s; the writes are
// `ModelRoleWriter`'s. The voice engine, the live model and the recogniser are these pickers —
// the screens that held them link here rather than keep a second copy.

/// The Roles section of AI & Personality, under the assistant's models: one row per role, naming
/// what it is set to, opening that role's picker.
struct ModelRolesSection: View {
    @ObservedObject var appState: AppState
    /// Bumped by the screen when something it did may have changed a role.
    var revision: Int = 0
    /// Called after a picker wrote a role.
    var onChange: () -> Void = {}

    @State private var inputs = ModelRoleInputs(savedModels: [])
    @State private var state = ModelRoleState(assistantId: "")

    var body: some View {
        Section {
            ForEach(ModelRole.shown) { role in
                NavigationLink {
                    ModelRolePickerScreen(appState: appState, role: role) {
                        reload()
                        onChange()
                    }
                } label: {
                    LabeledContent {
                        Text(ModelRoleCatalog.summary(of: role, state: state, inputs: inputs))
                            .lineLimit(1)
                    } label: {
                        Label(role.title, systemImage: role.icon)
                    }
                }
            }
        } header: {
            Text("Roles")
        } footer: {
            Text("Each job can use its own model, from any key you've saved. A job that uses a cloud model sends that job's data to its provider, on that provider's key.")
        }
        .onAppear(perform: reload)
        .onChange(of: revision) { _, _ in reload() }
    }

    private func reload() {
        inputs = .live
        state = .live
    }
}

/// One role's picker: its options as selection rows, or why it can't be changed.
struct ModelRolePickerScreen: View {
    @ObservedObject var appState: AppState
    let role: ModelRole
    var onChange: () -> Void = {}

    @State private var inputs = ModelRoleInputs(savedModels: [])
    @State private var state = ModelRoleState(assistantId: "")
    @State private var errorMessage: String?

    var body: some View {
        Form {
            switch ModelRoleCatalog.availability(of: role, inputs: inputs) {
            case .offUnderLocalOnly:
                Section {
                    OGNotice(text: String(localized: "Medical local-only is on, and every choice for this job leaves the phone, so it is off."),
                             systemImage: "lock")
                }
            case .pinned(let organization):
                Section {
                    LabeledContent(role.title, value: ModelRoleCatalog.summary(of: role, state: state, inputs: inputs))
                    if let organization {
                        ManagedLockNote(organization: organization)
                    }
                } footer: {
                    Text(role.pickerFooter)
                }
            case .available:
                optionsSection
            }

            if let errorMessage {
                Section { OGStatusLabel(errorMessage, kind: .error) }
            }
        }
        .navigationTitle(role.title)
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private var optionsSection: some View {
        let selected = ModelRoleCatalog.effectiveSelection(role, state: state, inputs: inputs)
        let all = ModelRoleCatalog.options(for: role, inputs: inputs)
        let options = all.filter(\.isChoosable)
        let unavailable = all.filter { !$0.isChoosable }
        Section {
            if options.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
            ForEach(options) { option in
                let subtitle = [option.subtitle, option.note].compactMap { $0 }.joined(separator: " · ")
                OGSelectionRow(title: option.title, subtitle: subtitle.isEmpty ? nil : subtitle,
                               isSelected: option.choice == selected,
                               accessibilityText: [option.title, option.subtitle, option.note].compactMap { $0 }.joined(separator: ", ")) {
                    choose(option)
                }
            }
            if role == .dictation, inputs.restrictions.orgCloudOff.contains(.dictation) {
                ManagedSettingNote(key: .cloudDictationEnabled)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(role.pickerFooter)
                if inputs.restrictions.localOnly {
                    Text("Medical local-only is on, so only choices that stay on this phone are listed.")
                } else if role == .dictation, inputs.restrictions.hipaa {
                    Text("HIPAA mode is on, so dictation stays on this phone.")
                }
            }
        }
        // Saved models this job can't use: retired by their provider, or reached only by a
        // connection the app doesn't have. Dimmed and labelled, not offered.
        if !unavailable.isEmpty {
            Section {
                ForEach(unavailable) { option in
                    let label = option.unavailableLabel ?? ""
                    UnavailableModelRow(title: option.title, detail: option.subtitle, label: label,
                                        spokenText: String(localized: "\(option.title), \(label), can't be chosen"))
                }
            } header: {
                Text("Can't be chosen")
            }
        }
    }

    private var emptyText: String {
        switch role {
        case .live: return String(localized: "Add a key for a provider with a live model, such as OpenAI or Gemini, or add a live model under Realtime Models.")
        default: return String(localized: "Nothing to choose yet. Add a model under AI Models.")
        }
    }

    private func choose(_ option: ModelRoleOption) {
        errorMessage = nil
        switch ModelRoleWriter.apply(option.choice, role: role) {
        case .applied:
            break
        case .assistantChanged:
            appState.llmService.clearHistory()
            appState.llmService.refreshActiveModel()
        case .liveModelChanged(let id):
            // A conversation already in a live mode moves to the chosen model; one in Direct mode
            // stays there and uses it the next time Live starts.
            if appState.currentMode.isRealtime {
                appState.selectRealtimeModel(id)
            }
        case .failed(let message):
            errorMessage = message
        }
        reload()
        onChange()
    }

    private func reload() {
        inputs = .live
        state = .live
    }
}

/// The card a newly added key shows (Design 9): what else the key can do, one tap per role and
/// "Use all", each naming where the data goes and whose quota it spends. Nothing is switched on
/// until it is tapped.
struct ModelRoleSuggestionCard: View {
    let title: String
    let suggestions: [ModelRoleSuggestion]
    let onUse: ([ModelRoleSuggestion]) -> Void
    let onDismiss: () -> Void

    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 44

    var body: some View {
        Section {
            ForEach(suggestions) { suggestion in
                HStack(alignment: .center, spacing: OGMetrics.rowSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(suggestion.summary, systemImage: suggestion.role.icon)
                            .font(.body)
                        Text(suggestion.destination)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    Button("Use") { onUse([suggestion]) }
                        .buttonStyle(.ogProminentCompact)
                        .accessibilityLabel(String(localized: "Use for \(suggestion.summary)"))
                }
                .frame(minHeight: rowMinHeight)
            }
            if suggestions.count > 1 {
                Button("Use all") { onUse(suggestions) }
                    .buttonStyle(.ogProminent)
            }
            Button("Not now", action: onDismiss)
                .buttonStyle(.ogQuiet)
        } header: {
            Text(title)
        } footer: {
            Text("Nothing is switched on until you choose it. Each job can be changed later under Roles in AI & Personality.")
        }
    }
}

/// What a key card shows: its heading and its suggestions.
struct ModelRoleKeyCard: Equatable {
    let title: String
    var suggestions: [ModelRoleSuggestion]

    /// The card for a key just saved, or nil when it has nothing to offer.
    @MainActor
    static func forAdded(_ config: ModelConfig, listed: [ModelFetcher.RemoteModel]) -> ModelRoleKeyCard? {
        let suggestions = ModelRoleCatalog.suggestions(for: config, listed: listed, inputs: .live, state: .live)
        guard !suggestions.isEmpty else { return nil }
        return ModelRoleKeyCard(title: ModelRoleCatalog.cardTitle(for: config), suggestions: suggestions)
    }

    /// Apply `chosen` and return the card left over, or nil when nothing is left. A failure leaves
    /// that suggestion on the card.
    @MainActor
    func applying(_ chosen: [ModelRoleSuggestion], appState: AppState) -> (card: ModelRoleKeyCard?, error: String?) {
        var remaining = suggestions
        var error: String?
        for suggestion in chosen {
            switch ModelRoleWriter.apply(suggestion.choice, role: suggestion.role) {
            case .failed(let message):
                error = message
                continue
            case .liveModelChanged(let id):
                if appState.currentMode.isRealtime { appState.selectRealtimeModel(id) }
            case .assistantChanged:
                appState.llmService.refreshActiveModel()
            case .applied:
                break
            }
            remaining.removeAll { $0.id == suggestion.id }
        }
        return (remaining.isEmpty ? nil : ModelRoleKeyCard(title: title, suggestions: remaining), error)
    }
}
