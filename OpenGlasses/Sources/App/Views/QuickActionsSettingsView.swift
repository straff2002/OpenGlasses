import SwiftUI

/// Settings view for managing quick action speed dial buttons.
struct QuickActionsSettingsView: View {
    @State private var actions: [QuickAction] = Config.quickActions
    @State private var editingAction: QuickAction?
    @State private var showAddSheet = false

    var body: some View {
        List {
            if actions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Quick Actions",
                        systemImage: "dial.high",
                        description: Text("Add actions to your speed dial — photo prompts, smart home controls, shortcuts, and more.")
                    )
                }
            } else {
                Section {
                    ForEach(actions) { action in
                        Button {
                            editingAction = action
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: action.icon)
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(action.label)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(action.type.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    Text(actionSummary(action))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
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
                    Text("Spin the dial with your thumb on the main screen, tap to invoke. Drag to reorder priority.")
                }
            }
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarLeading) {
                if !actions.isEmpty { EditButton() }
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

    private func actionSummary(_ action: QuickAction) -> String {
        switch action.type {
        case .prompt: return action.promptText ?? "Text prompt"
        case .photo: return "Capture and describe"
        case .photoThenPrompt: return action.promptText?.prefix(60).description ?? "Photo + prompt"
        case .homeAssistant: return [action.haService, action.haEntityId].compactMap { $0 }.joined(separator: " → ")
        case .siriShortcut: return action.shortcutName ?? "Shortcut"
        case .openApp: return action.urlScheme ?? "URL"
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

    // Composable options
    @State private var includePhoto = false
    @State private var promptText = ""

    // HA
    @State private var haService = ""
    @State private var haEntityId = ""
    @State private var haData = ""

    // Shortcut / App
    @State private var shortcutName = ""
    @State private var urlScheme = ""

    private let iconOptions: [(String, String)] = [
        ("star", "Star"), ("eye", "Describe"), ("camera", "Camera"),
        ("calendar", "Calendar"), ("checklist", "Checklist"), ("lightbulb", "Light On"),
        ("lightbulb.slash", "Light Off"), ("house", "Home"), ("lock", "Lock"),
        ("lock.open", "Unlock"), ("thermometer", "Climate"), ("fan", "Fan"),
        ("music.note", "Music"), ("phone", "Phone"), ("message", "Message"),
        ("envelope", "Email"), ("globe", "Web"), ("map", "Map"),
        ("location", "Location"), ("bell", "Alert"), ("alarm", "Alarm"),
        ("timer", "Timer"), ("brain", "AI"), ("wand.and.stars", "Magic"),
        ("fork.knife", "Food"), ("cart", "Shopping"), ("car", "Drive"),
        ("airplane", "Travel"), ("figure.walk", "Walk"), ("text.viewfinder", "Read"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - What it looks like
                Section {
                    TextField("Name", text: $label)

                    // Icon picker as a horizontal scroll
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(iconOptions, id: \.0) { name, _ in
                                Button {
                                    icon = name
                                } label: {
                                    Image(systemName: name)
                                        .font(.system(size: 18))
                                        .foregroundStyle(icon == name ? .white : .secondary)
                                        .frame(width: 36, height: 36)
                                        .background(icon == name ? Color.accentColor : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Appearance")
                }

                // MARK: - What it does
                Section {
                    Picker("Action", selection: $type) {
                        ForEach(QuickAction.ActionType.allCases) { t in
                            Label(t.displayName, systemImage: iconForType(t))
                                .tag(t)
                        }
                    }

                    // Photo toggle for prompt types
                    if type == .prompt || type == .photoThenPrompt {
                        Toggle("Include Photo", isOn: $includePhoto)
                            .onChange(of: includePhoto) { _, on in
                                type = on ? .photoThenPrompt : .prompt
                            }
                    }
                } header: {
                    Text("Action")
                } footer: {
                    Text(type.description)
                }

                // MARK: - Type-specific config
                switch type {
                case .prompt, .photoThenPrompt:
                    Section {
                        TextEditor(text: $promptText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } header: {
                        Text("Prompt")
                    } footer: {
                        Text("What to ask the AI. For photo actions, the photo is sent alongside this prompt.")
                    }

                case .homeAssistant:
                    Section {
                        TextField("Service (e.g., light.turn_off)", text: $haService)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Entity (e.g., light.living_room)", text: $haEntityId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Extra data JSON (optional)", text: $haData)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        Text("Home Assistant")
                    } footer: {
                        Text("Calls a HA service directly. Leave entity empty to target all. Data is optional JSON like {\"brightness\": 50}.")
                    }

                case .siriShortcut:
                    Section {
                        TextField("Shortcut name (exact)", text: $shortcutName)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Siri Shortcut")
                    } footer: {
                        Text("The exact name of your Shortcut as it appears in the Shortcuts app.")
                    }

                case .openApp:
                    Section {
                        TextField("URL scheme (e.g., weixin://)", text: $urlScheme)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    } header: {
                        Text("App URL")
                    } footer: {
                        Text("The URL scheme to open. Examples: weixin://, spotify://, shortcuts://")
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
            .onAppear { loadFromAction() }
            .onChange(of: type) { _, newType in
                // Sync photo toggle
                includePhoto = (newType == .photoThenPrompt)
            }
        }
    }

    private func iconForType(_ t: QuickAction.ActionType) -> String {
        switch t {
        case .prompt: return "text.bubble"
        case .photo: return "camera"
        case .photoThenPrompt: return "camera.viewfinder"
        case .homeAssistant: return "house"
        case .siriShortcut: return "shortcuts"
        case .openApp: return "arrow.up.forward.app"
        }
    }

    private func loadFromAction() {
        guard let a = action else { return }
        label = a.label
        icon = a.icon
        type = a.type
        includePhoto = (a.type == .photoThenPrompt || a.type == .photo)
        promptText = a.promptText ?? ""
        haService = a.haService ?? ""
        haEntityId = a.haEntityId ?? ""
        haData = a.haData ?? ""
        shortcutName = a.shortcutName ?? ""
        urlScheme = a.urlScheme ?? ""
    }

    private func save() {
        var qa = QuickAction(
            id: action?.id ?? UUID().uuidString,
            label: label.trimmingCharacters(in: .whitespaces),
            icon: icon,
            type: type
        )
        qa.promptText = promptText.isEmpty ? nil : promptText
        qa.haService = haService.isEmpty ? nil : haService
        qa.haEntityId = haEntityId.isEmpty ? nil : haEntityId
        qa.haData = haData.isEmpty ? nil : haData
        qa.shortcutName = shortcutName.isEmpty ? nil : shortcutName
        qa.urlScheme = urlScheme.isEmpty ? nil : urlScheme
        onSave(qa)
    }
}
