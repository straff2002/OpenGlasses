import SwiftUI

/// Settings view for managing quick action speed dial buttons.
struct QuickActionsSettingsView: View {
    @State private var actions: [QuickAction] = Config.quickActions
    @State private var editingAction: QuickAction?
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section {
                ForEach(actions) { action in
                    Button {
                        editingAction = action
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.icon)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.label)
                                    .foregroundStyle(.primary)
                                Text(action.type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    actions.remove(atOffsets: indexSet)
                    Config.setQuickActions(actions)
                }
                .onMove { from, to in
                    actions.move(fromOffsets: from, toOffset: to)
                    Config.setQuickActions(actions)
                }
            } header: {
                Text("Speed Dial")
            } footer: {
                Text("Swipe the dial on the main screen to rotate through actions. Tap Go to execute. Drag to reorder.")
            }
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            QuickActionEditorView(action: nil) { newAction in
                actions.append(newAction)
                Config.setQuickActions(actions)
            }
        }
        .sheet(item: $editingAction) { action in
            QuickActionEditorView(action: action) { updated in
                if let idx = actions.firstIndex(where: { $0.id == updated.id }) {
                    actions[idx] = updated
                    Config.setQuickActions(actions)
                }
            }
        }
    }
}

// MARK: - Editor

struct QuickActionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let action: QuickAction?
    let onSave: (QuickAction) -> Void

    @State private var label = ""
    @State private var icon = "star"
    @State private var type: QuickAction.ActionType = .prompt
    @State private var promptText = ""
    @State private var haService = ""
    @State private var haEntityId = ""
    @State private var haData = ""
    @State private var shortcutName = ""
    @State private var urlScheme = ""

    private let iconOptions = [
        "star", "eye", "camera", "calendar", "checklist", "lightbulb", "lightbulb.slash",
        "house", "lock", "lock.open", "thermometer", "fan", "music.note",
        "phone", "message", "envelope", "globe", "map", "location",
        "bell", "alarm", "timer", "brain", "wand.and.stars",
        "fork.knife", "cart", "car", "airplane", "figure.walk",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Label", text: $label)
                    Picker("Icon", selection: $icon) {
                        ForEach(iconOptions, id: \.self) { name in
                            Label(name, systemImage: name).tag(name)
                        }
                    }
                }

                Section("Action Type") {
                    Picker("Type", selection: $type) {
                        ForEach(QuickAction.ActionType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Text(type.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch type {
                case .prompt, .photoThenPrompt:
                    Section("Prompt") {
                        TextEditor(text: $promptText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                case .homeAssistant:
                    Section("Home Assistant") {
                        TextField("Service (e.g., light.turn_off)", text: $haService)
                        TextField("Entity ID (e.g., light.living_room)", text: $haEntityId)
                        TextField("Extra data JSON (optional)", text: $haData)
                    }
                case .siriShortcut:
                    Section("Siri Shortcut") {
                        TextField("Shortcut name", text: $shortcutName)
                    }
                case .openApp:
                    Section("URL Scheme") {
                        TextField("URL (e.g., weixin://)", text: $urlScheme)
                    }
                case .photo:
                    EmptyView()
                }
            }
            .navigationTitle(action == nil ? "New Action" : "Edit Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let a = action {
                    label = a.label
                    icon = a.icon
                    type = a.type
                    promptText = a.promptText ?? ""
                    haService = a.haService ?? ""
                    haEntityId = a.haEntityId ?? ""
                    haData = a.haData ?? ""
                    shortcutName = a.shortcutName ?? ""
                    urlScheme = a.urlScheme ?? ""
                }
            }
        }
    }

    private func save() {
        let id = action?.id ?? UUID().uuidString
        var qa = QuickAction(id: id, label: label.trimmingCharacters(in: .whitespaces), icon: icon, type: type)
        qa.promptText = promptText.isEmpty ? nil : promptText
        qa.haService = haService.isEmpty ? nil : haService
        qa.haEntityId = haEntityId.isEmpty ? nil : haEntityId
        qa.haData = haData.isEmpty ? nil : haData
        qa.shortcutName = shortcutName.isEmpty ? nil : shortcutName
        qa.urlScheme = urlScheme.isEmpty ? nil : urlScheme
        onSave(qa)
    }
}
