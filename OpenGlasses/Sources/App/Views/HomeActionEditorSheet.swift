import SwiftUI

/// The two writes a speed-dial edit makes, in one place because two editing surfaces make them.
///
/// Deleting is the one that matters: the action and its voice exposure go together, from a single
/// `SpeedDialEditor.deleting` result, so neither surface can revoke half of it.
@MainActor
enum SpeedDialWriter {
    static func save(_ draft: HomeActionDraft) {
        Config.setQuickActions(SpeedDialEditor.applying(draft, to: Config.quickActions))
        OpenGlassesShortcuts.updateAppShortcutParameters()
    }

    /// Already confirmed by the caller's modal — this is the write, not the decision.
    static func delete(_ id: String) {
        guard let deletion = SpeedDialEditor.deleting(id: id, from: Config.quickActions,
                                                      exposure: Config.siriExposure) else { return }
        Config.setQuickActions(deletion.actions)
        Config.setSiriExposure(deletion.exposure)
        OpenGlassesShortcuts.updateAppShortcutParameters()
    }
}

/// Make an action where the actions live — the sheet the grid's edit page opens.
///
/// Four fields and nothing else: a name, a glyph from a curated set, whether it takes a picture
/// first, and the sentence to send. That is the whole of what a grid action is, and it is
/// deliberately less than the advanced editor offers: everything here submits an ordinary turn,
/// so a tile the wearer makes can never do something they could not have asked for out loud.
struct HomeActionEditorSheet: View {
    /// The action being edited, or nil to create one.
    let existing: QuickAction?
    let onSave: (HomeActionDraft) -> Void
    let onDelete: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    /// Glyph tiles are drawn at 36×36; the tap target around them is a fingertip.
    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44

    @State private var draft = HomeActionDraft()
    @State private var issue: SpeedDialEditor.Issue?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    iconPicker
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("The name and glyph the tile draws — and, if you expose it for voice, the name you say.")
                }

                Section {
                    Picker("When it runs", selection: $draft.kind) {
                        Text("Just ask").tag(HomeGridAction.Kind.prompt)
                        Text("Take a photo first").tag(HomeGridAction.Kind.photoPrompt)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Kind")
                } footer: {
                    Text(draft.kind == .photoPrompt
                         ? "Captures a still through the glasses (or the phone) and sends it with the prompt."
                         : "Sends the prompt on its own, exactly as if you had typed it.")
                }

                Section {
                    TextEditor(text: $draft.prompt)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color(.label))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Prompt")
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("What to ask. The assistant answers it the same way it answers you.")
                }

                if let issue {
                    Section {
                        Text(Self.message(for: issue))
                            .font(.footnote)
                            .foregroundStyle(OGTheme.errorLabel)
                    }
                }

                if let existing, onDelete != nil {
                    Section {
                        Button("Delete Action", role: .destructive) { showDeleteConfirm = true }
                            .accessibilityHint("Removes \(existing.label) from your speed dial everywhere.")
                    }
                }
            }
            .navigationTitle(draft.isNew ? "New Action" : "Edit Action")
            .navigationBarTitleDisplayMode(.inline)
            .ogFormStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onAppear(perform: load)
            .alert("Delete this action?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let existing { onDelete?(existing.id) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
        }
    }

    private var deleteMessage: String {
        let name = existing?.label ?? "This action"
        var lines = ["\"\(name)\" is removed from the grid, the widget, the watch and the in-lens launcher."]
        if isExposedToVoice { lines.append("Running it by voice is turned off at the same time.") }
        lines.append("Your conversations and memories are untouched.")
        return lines.joined(separator: " ")
    }

    private var isExposedToVoice: Bool {
        guard let existing else { return false }
        return Config.siriExposure.enabledCapabilityIds
            .contains(SpeedDialEditor.exposureKey(forQuickActionId: existing.id))
    }

    private var iconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeActionIcons.curated, id: \.symbol) { symbol, name in
                    Button {
                        draft.icon = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.body)
                            .foregroundStyle(draft.icon == symbol ? Color.white : .secondary)
                            .frame(width: 36, height: 36)
                            .background(draft.icon == symbol ? accent : Color(.secondarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 8))
                            // Hit area only — the drawn tile stays 36×36 above.
                            .frame(minWidth: tapTarget, minHeight: tapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name) icon\(draft.icon == symbol ? ", selected" : "")")
                    .accessibilityAddTraits(draft.icon == symbol ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func load() {
        guard let existing, let loaded = HomeActionDraft(editing: existing) else { return }
        draft = loaded
    }

    private func save() {
        // Validated against the persisted list, not the resolved grid — the same list the save
        // writes back, so "that name is taken" is decided by what is actually stored.
        if let found = SpeedDialEditor.validate(draft, against: Config.quickActions) {
            issue = found
            return
        }
        issue = nil
        onSave(draft)
        dismiss()
    }

    private static func message(for issue: SpeedDialEditor.Issue) -> String {
        switch issue {
        case .emptyName:
            return "Give the action a name — it's what the tile says."
        case .duplicateName(let name):
            return "An action named \"\(name)\" already exists."
        case .emptyPrompt:
            return "Enter the prompt to send."
        case .notEditable:
            return "This is a built-in action, so it can't be changed."
        }
    }
}
