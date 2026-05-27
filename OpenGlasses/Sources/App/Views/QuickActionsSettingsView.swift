import SwiftUI
import Intents

/// Settings view for managing quick action speed dial buttons.
struct QuickActionsSettingsView: View {
    @State private var actions: [QuickAction] = Config.quickActions
    @State private var editingAction: QuickAction?
    @State private var showAddSheet = false
    @State private var previewingTemplate: QuickAction?
    @State private var showAllQuickActions = Config.showAllQuickActions

    /// Pre-built quick action templates users can add.
    static let templates: [QuickAction] = [
        QuickAction(id: "skin-analysis", label: "Skin Check", icon: "cross.circle", type: .photoThenPrompt,
                    promptText: "Analyze this skin lesion. Describe the morphology: lesion type (macule, papule, plaque, nodule, vesicle), color, border characteristics, estimated size, distribution, and any secondary changes (scale, crust, erosion). Evaluate ABCDEs for pigmented lesions. Suggest a ranked differential diagnosis. Note: this is for clinical documentation support only."),
        QuickAction(id: "nutrition-scan", label: "Nutrition", icon: "leaf.circle", type: .photoThenPrompt,
                    promptText: "Identify the food in this image. Estimate calories, protein, carbs, fat, and fiber. Give a health score from 1 to 10. If a nutrition label is visible, read it. Keep it brief."),
        QuickAction(id: "clinical-note", label: "SOAP Note", icon: "stethoscope", type: .prompt,
                    promptText: "Summarize the current conversation as a structured SOAP note: Subjective (chief complaint, HPI, ROS), Objective (exam findings, vitals), Assessment (diagnosis and differential), Plan (orders, prescriptions, follow-up). Use standard medical terminology."),
        QuickAction(id: "golf-club", label: "Club?", icon: "figure.golf", type: .prompt,
                    promptText: "Based on the current situation, what club should I use? Consider distance, wind, elevation, and lie. Give a confident recommendation."),
        QuickAction(id: "translate-sign", label: "Translate", icon: "globe", type: .photoThenPrompt,
                    promptText: "Read and translate all visible text in this image. Show the original text first, then the English translation."),
        QuickAction(id: "summarize-page", label: "Summarize", icon: "text.viewfinder", type: .photoThenPrompt,
                    promptText: "Read the text in this image and provide a concise summary of the key points."),
        QuickAction(id: "identify-plant", label: "Plant ID", icon: "leaf", type: .photoThenPrompt,
                    promptText: "Identify this plant. Include common name, scientific name, whether it's edible or toxic, and any interesting facts. Keep it brief."),
        QuickAction(id: "price-check", label: "Price Check", icon: "tag", type: .photoThenPrompt,
                    promptText: "Read the price tag or label. Tell me the product name, price, and any deal/discount information visible."),
    ]

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
            }

            // MARK: - User's actions (shown first)
            if !actions.isEmpty {
                Section {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        Button {
                            editingAction = action
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: action.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(action.label)
                                            .foregroundStyle(Color(.label))
                                            .lineLimit(1)
                                        Text(action.type.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                    Text(actionSummary(action))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if index < 4 && !showAllQuickActions {
                                    Text("visible")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(action.label), \(action.type.displayName)\(index < 4 && !showAllQuickActions ? ", visible on main screen" : "")")
                        .accessibilityHint("Double-tap to edit")
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
                    if showAllQuickActions {
                        Text("All actions shown on the Voice tab, wrapped in rows of 4. Drag to reorder.")
                    } else {
                        Text("Only the top 4 actions are shown on the Voice tab. Drag to reorder priority.")
                    }
                }
            }

            // MARK: - Display Mode
            Section {
                InfoToggle(
                    title: "Show All Actions",
                    isOn: $showAllQuickActions,
                    info: "When off, only the top 4 quick actions are shown on the Voice tab. When on, all actions are displayed in a grid that wraps every 4 buttons. Reorder actions above to control which appear in the top 4."
                )
                .onChange(of: showAllQuickActions) { _, newValue in
                    Config.setShowAllQuickActions(newValue)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Whether the Voice tab shows just the top four actions or every action in a wrapping grid.")
            }

            // MARK: - Templates (below user actions)
            let addedIds = Set(actions.map(\.id))
            let available = Self.templates.filter { !addedIds.contains($0.id) }
            if !available.isEmpty {
                Section {
                    ForEach(available) { template in
                        Button {
                            previewingTemplate = template
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: template.icon)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.label)
                                        .foregroundStyle(Color(.label))
                                    Text(actionSummary(template))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(template.label). \(actionSummary(template))")
                        .accessibilityHint("Double-tap to preview")
                    }
                } header: {
                    Text("Templates")
                } footer: {
                    Text("Tap to preview a template before adding it to your speed dial.")
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
        .sheet(item: $previewingTemplate) { template in
            QuickActionTemplatePreview(template: template) {
                actions.append(template)
                Config.setQuickActions(actions)
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

// MARK: - Template Preview

/// Shows template details before adding — user must explicitly tap "Add to Speed Dial".
struct QuickActionTemplatePreview: View {
    let template: QuickAction
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(template.type.displayName)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(template.label, systemImage: template.icon)
                            .font(.body.weight(.medium))
                    }
                }

                if let prompt = template.promptText, !prompt.isEmpty {
                    Section {
                        Text(prompt)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Prompt")
                    }
                }

                Section {
                    Button {
                        onAdd()
                        dismiss()
                    } label: {
                        Text("Add to Speed Dial")
                    }
                }
            }
            .navigationTitle("Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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

    // HA entity picker state
    @State private var haEntities: [HAPickerEntity] = []
    @State private var haSelectedDomain: String = "all"
    @State private var haSearchText = ""
    @State private var haIsLoading = false

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

    /// Common HA services grouped by domain
    private static let commonServices: [(domain: String, services: [(id: String, label: String)])] = [
        ("light", [
            ("light.turn_on", "Turn On"),
            ("light.turn_off", "Turn Off"),
            ("light.toggle", "Toggle"),
        ]),
        ("switch", [
            ("switch.turn_on", "Turn On"),
            ("switch.turn_off", "Turn Off"),
            ("switch.toggle", "Toggle"),
        ]),
        ("cover", [
            ("cover.open_cover", "Open"),
            ("cover.close_cover", "Close"),
            ("cover.toggle", "Toggle"),
        ]),
        ("lock", [
            ("lock.lock", "Lock"),
            ("lock.unlock", "Unlock"),
        ]),
        ("climate", [
            ("climate.set_temperature", "Set Temperature"),
            ("climate.turn_on", "Turn On"),
            ("climate.turn_off", "Turn Off"),
        ]),
        ("fan", [
            ("fan.turn_on", "Turn On"),
            ("fan.turn_off", "Turn Off"),
            ("fan.toggle", "Toggle"),
        ]),
        ("media_player", [
            ("media_player.media_play", "Play"),
            ("media_player.media_pause", "Pause"),
            ("media_player.media_play_pause", "Play/Pause"),
            ("media_player.volume_up", "Volume Up"),
            ("media_player.volume_down", "Volume Down"),
            ("media_player.volume_mute", "Mute"),
        ]),
        ("scene", [
            ("scene.turn_on", "Activate Scene"),
        ]),
        ("automation", [
            ("automation.trigger", "Trigger"),
            ("automation.turn_on", "Enable"),
            ("automation.turn_off", "Disable"),
        ]),
        ("script", [
            ("script.turn_on", "Run Script"),
        ]),
        ("vacuum", [
            ("vacuum.start", "Start"),
            ("vacuum.stop", "Stop"),
            ("vacuum.return_to_base", "Return to Base"),
        ]),
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
                            ForEach(iconOptions, id: \.0) { name, label in
                                Button {
                                    icon = name
                                } label: {
                                    Image(systemName: name)
                                        .font(.system(size: 18))
                                        .foregroundStyle(icon == name ? .white : .secondary)
                                        .frame(width: 36, height: 36)
                                        .background(icon == name ? Color.accentColor : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(label) icon\(icon == name ? ", selected" : "")")
                                .accessibilityAddTraits(icon == name ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Pick an SF Symbol that hints at what the action does. This is what shows up on the widget and Voice tab.")
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
                            .foregroundStyle(Color(.label))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } header: {
                        Text("Prompt")
                    } footer: {
                        Text("What to ask the AI. For photo actions, the photo is sent alongside this prompt.")
                    }

                case .homeAssistant:
                    haServiceSection
                    haEntitySection
                    haDataSection

                case .siriShortcut:
                    ShortcutPickerSection(shortcutName: $shortcutName)

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
                includePhoto = (newType == .photoThenPrompt)
                if newType == .homeAssistant && haEntities.isEmpty {
                    loadHAEntities()
                }
            }
        }
    }

    // MARK: - HA Service Picker

    private var haServiceSection: some View {
        Section {
            // Quick-pick common services
            let serviceDomain = haService.split(separator: ".").first.map(String.init) ?? ""
            Picker("Domain", selection: Binding(
                get: { serviceDomain.isEmpty ? "light" : serviceDomain },
                set: { domain in
                    // Pick the first service for that domain
                    if let group = Self.commonServices.first(where: { $0.domain == domain }),
                       let first = group.services.first {
                        haService = first.id
                    }
                    haSelectedDomain = domain
                }
            )) {
                ForEach(Self.commonServices, id: \.domain) { group in
                    Label(group.domain.capitalized, systemImage: iconForDomain(group.domain))
                        .tag(group.domain)
                }
            }

            // Service picker within the domain
            let currentDomain = serviceDomain.isEmpty ? "light" : serviceDomain
            if let group = Self.commonServices.first(where: { $0.domain == currentDomain }) {
                Picker("Service", selection: $haService) {
                    ForEach(group.services, id: \.id) { svc in
                        Text(svc.label).tag(svc.id)
                    }
                }
            }

            // Manual override
            DisclosureGroup("Manual Entry") {
                TextField("Service ID", text: $haService)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Service")
        } footer: {
            Text("The Home Assistant service to call.")
        }
    }

    // MARK: - HA Entity Picker

    private var haEntitySection: some View {
        Section {
            if haIsLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading entities…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if haEntities.isEmpty {
                Button {
                    loadHAEntities()
                } label: {
                    Label("Load Entities", systemImage: "arrow.clockwise")
                }

                // Always show manual entry
                TextField("Entity ID", text: $haEntityId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            } else {
                // "All" option
                Button {
                    haEntityId = "all"
                    autoFillLabel()
                } label: {
                    HStack {
                        Label("All Entities", systemImage: "square.stack.3d.up")
                            .foregroundStyle(Color(.label))
                        Spacer()
                        if haEntityId == "all" {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                // Domain filter
                let domains = availableDomains
                if domains.count > 1 {
                    Picker("Filter", selection: $haSelectedDomain) {
                        Text("All Domains").tag("all")
                        ForEach(domains, id: \.self) { domain in
                            Label(domain.capitalized, systemImage: iconForDomain(domain))
                                .tag(domain)
                        }
                    }
                }

                // Search
                if filteredHAEntities.count > 8 {
                    TextField("Search entities…", text: $haSearchText)
                        .autocorrectionDisabled()
                }

                // Entity list
                ForEach(filteredHAEntities.prefix(50)) { entity in
                    Button {
                        haEntityId = entity.entityId
                        autoFillLabel()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.friendlyName)
                                    .foregroundStyle(Color(.label))
                                    .lineLimit(1)
                                Text(entity.entityId)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(entity.state)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                            if haEntityId == entity.entityId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if filteredHAEntities.count > 50 {
                    Text("\(filteredHAEntities.count - 50) more — use search to narrow down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Manual override always available
                DisclosureGroup("Manual Entry") {
                    TextField("Entity ID", text: $haEntityId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }
            }
        } header: {
            HStack {
                Text("Entity")
                Spacer()
                if !haEntities.isEmpty {
                    Text("\(filteredHAEntities.count) available")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("Select a device, automation, scene, or script. Choose \"All\" to target every entity of the service domain.")
        }
    }

    // MARK: - HA Data Section

    private var haDataSection: some View {
        Section {
            // Smart data presets based on service
            if haService.contains("brightness") || haService == "light.turn_on" {
                Picker("Brightness", selection: Binding(
                    get: { brightnessFromData() },
                    set: { haData = "{\"brightness\": \($0)}" }
                )) {
                    Text("Default").tag(0)
                    Text("25%").tag(64)
                    Text("50%").tag(128)
                    Text("75%").tag(191)
                    Text("100%").tag(255)
                }
            }

            if haService.contains("temperature") || haService == "climate.set_temperature" {
                Stepper("Temperature: \(temperatureFromData())°",
                        value: Binding(
                            get: { temperatureFromData() },
                            set: { haData = "{\"temperature\": \($0)}" }
                        ), in: 60...85)
            }

            // Manual JSON entry
            DisclosureGroup("Custom Data (JSON)") {
                TextField("{\"key\": \"value\"}", text: $haData)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Optional parameters for the service call. Most actions work without extra data.")
        }
    }

    // MARK: - HA Helpers

    private var availableDomains: [String] {
        let domains = Set(haEntities.map(\.domain))
        return domains.sorted()
    }

    private var filteredHAEntities: [HAPickerEntity] {
        var result = haEntities

        // Filter by domain
        if haSelectedDomain != "all" {
            result = result.filter { $0.domain == haSelectedDomain }
        } else {
            // If a service is selected, prefer matching domain
            let svcDomain = haService.split(separator: ".").first.map(String.init) ?? ""
            if !svcDomain.isEmpty {
                result = result.filter { $0.domain == svcDomain }
            }
        }

        // Search filter
        if !haSearchText.isEmpty {
            let q = haSearchText.lowercased()
            result = result.filter {
                $0.friendlyName.lowercased().contains(q) ||
                $0.entityId.lowercased().contains(q)
            }
        }

        return result.sorted { $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending }
    }

    private func loadHAEntities() {
        haIsLoading = true
        Task {
            await HomeAssistantEntityCache.shared.refreshIfNeeded(force: true)
            let cached = await HomeAssistantEntityCache.shared.allEntities()
            await MainActor.run {
                haEntities = cached.map {
                    HAPickerEntity(entityId: $0.entityId, friendlyName: $0.friendlyName, domain: $0.domain, state: $0.state)
                }
                haIsLoading = false
            }
        }
    }

    private func autoFillLabel() {
        // Auto-fill label if empty
        guard label.isEmpty || label == "star" else { return }
        let svcParts = haService.split(separator: ".")
        let action = svcParts.count > 1 ? String(svcParts[1]).replacingOccurrences(of: "_", with: " ").capitalized : ""
        if haEntityId == "all" {
            label = "\(action) All"
        } else if let entity = haEntities.first(where: { $0.entityId == haEntityId }) {
            label = "\(action) \(entity.friendlyName)"
        }
    }

    private func brightnessFromData() -> Int {
        guard let data = haData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let brightness = json["brightness"] as? Int else { return 0 }
        return brightness
    }

    private func temperatureFromData() -> Int {
        guard let data = haData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let temp = json["temperature"] as? Int else { return 72 }
        return temp
    }

    // MARK: - Shared Helpers

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

    private func iconForDomain(_ domain: String) -> String {
        switch domain {
        case "light": return "lightbulb"
        case "switch": return "power"
        case "cover": return "blinds.vertical.open"
        case "lock": return "lock"
        case "climate": return "thermometer"
        case "fan": return "fan"
        case "media_player": return "play.rectangle"
        case "scene": return "theatermasks"
        case "automation": return "gearshape.2"
        case "script": return "scroll"
        case "vacuum": return "figure.walk"
        default: return "square.grid.2x2"
        }
    }

    private func loadFromAction() {
        guard let a = action else {
            // New action — preload entities if HA type
            if type == .homeAssistant { loadHAEntities() }
            return
        }
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

        if type == .homeAssistant {
            loadHAEntities()
        }
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

// MARK: - HA Picker Entity Model

private struct HAPickerEntity: Identifiable {
    var id: String { entityId }
    let entityId: String
    let friendlyName: String
    let domain: String
    let state: String
}

// MARK: - Siri Shortcut Picker

/// Shows discovered Siri Shortcuts in a picker, with a manual text field fallback.
struct ShortcutPickerSection: View {
    @Binding var shortcutName: String
    @State private var shortcuts: [DiscoveredShortcut] = []
    @State private var isLoading = true
    @State private var showManualEntry = false

    struct DiscoveredShortcut: Identifiable {
        let id: String
        let phrase: String
        let title: String
    }

    var body: some View {
        Section {
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading shortcuts…")
                        .foregroundStyle(.secondary)
                }
            } else if shortcuts.isEmpty {
                // No shortcuts found — manual entry only
                TextField("Shortcut name (exact)", text: $shortcutName)
                    .autocorrectionDisabled()

                Text("No Siri Shortcuts found on this device. Type the exact name manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Shortcut list
                ForEach(shortcuts) { sc in
                    Button {
                        shortcutName = sc.phrase
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sc.phrase)
                                    .foregroundStyle(Color(.label))
                                if sc.title != sc.phrase {
                                    Text(sc.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if shortcutName.lowercased() == sc.phrase.lowercased() {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .foregroundStyle(Color(.label))
                }

                // Manual entry toggle
                if showManualEntry {
                    TextField("Or type a name manually", text: $shortcutName)
                        .autocorrectionDisabled()
                } else {
                    Button("Enter name manually") {
                        showManualEntry = true
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("Siri Shortcut")
        } footer: {
            if !shortcuts.isEmpty {
                Text("Select a shortcut from your device, or enter a name manually.")
            }
        }
        .task {
            await loadShortcuts()
        }
    }

    private func loadShortcuts() async {
        do {
            let voiceShortcuts = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[INVoiceShortcut], Error>) in
                INVoiceShortcutCenter.shared.getAllVoiceShortcuts { shortcuts, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: shortcuts ?? []) }
                }
            }

            shortcuts = voiceShortcuts.map { vs in
                let title = vs.shortcut.intent?.description
                    ?? vs.shortcut.userActivity?.title
                    ?? vs.invocationPhrase
                return DiscoveredShortcut(
                    id: vs.identifier.uuidString,
                    phrase: vs.invocationPhrase,
                    title: title
                )
            }.sorted { $0.phrase.lowercased() < $1.phrase.lowercased() }
        } catch {
            shortcuts = []
        }
        isLoading = false
    }
}
