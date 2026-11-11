import SwiftUI

/// Lists all registered native tools with toggle, description, and parameter info.
/// Transparency surface — users can see and control what the AI can do.
struct ToolsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var disabledTools: Set<String> = Config.disabledTools
    @State private var offlineMode: Bool = Config.offlineModeEnabled
    @State private var searchText = ""
    @State private var permissionDeniedTool: String?
    /// Plan HA C4: a tool the organisation closed is not listed for the technician — not in the
    /// list, the counts or the search.
    @ObservedObject private var adminGate = AdminGate.shared

    private var allTools: [(name: String, displayName: String, description: String, params: [String: Any])] {
        appState.nativeToolRouter.registry.allTools
            // Plan IU: `lookup_tools` is infrastructure for on-demand definitions, not a tool to
            // switch off — turning it off would leave the model unable to reach the rest.
            .filter { $0.name != ToolLookupTool.toolName }
            .filter { adminGate.presentation(.tool($0.name)).isShown }
            .map { (name: $0.name, displayName: Self.displayName(for: $0.name), description: $0.description, params: $0.parametersSchema) }
            // Name breaks a tie: two tools with one display name would otherwise swap places by
            // dictionary order between redraws, which a `List` reads as a move.
            .sorted { $0.displayName != $1.displayName ? $0.displayName < $1.displayName : $0.name < $1.name }
    }

    /// Convert tool IDs like "get_weather" → "Weather", "convert_currency" → "Currency Conversion"
    private static func displayName(for toolName: String) -> String {
        let overrides: [String: String] = [
            "get_weather": String(localized: "Weather"),
            "get_datetime": String(localized: "Date & Time"),
            "daily_briefing": String(localized: "Daily Briefing"),
            "calculate": String(localized: "Calculator"),
            "convert_units": String(localized: "Unit Conversion"),
            "set_timer": String(localized: "Timer"),
            "pomodoro": String(localized: "Pomodoro Timer"),
            "save_note": String(localized: "Save Note"),
            "list_notes": String(localized: "Notes"),
            "web_search": String(localized: "Web Search"),
            "get_news": String(localized: "News"),
            "translate": String(localized: "Translation"),
            "define_word": String(localized: "Dictionary"),
            "find_nearby": String(localized: "Nearby Places"),
            "open_app": String(localized: "Open App"),
            "get_directions": String(localized: "Directions"),
            "identify_song": String(localized: "Song Recognition"),
            "music_control": String(localized: "Music Control"),
            "play_podcast": String(localized: "Podcasts"),
            "convert_currency": String(localized: "Currency Conversion"),
            "phone_call": String(localized: "Phone Call"),
            "send_message": String(localized: "Send Message"),
            "copy_to_clipboard": String(localized: "Clipboard"),
            "flashlight": String(localized: "Flashlight"),
            "device_info": String(localized: "Device Info"),
            "save_location": String(localized: "Save Location"),
            "list_saved_locations": String(localized: "Saved Locations"),
            "parking": String(localized: "Parking"),
            "step_count": String(localized: "Step Counter"),
            "health_summary": String(localized: "Health Summary"),
            "emergency_info": String(localized: "Emergency Info"),
            "calendar": String(localized: "Calendar"),
            "lookup_contact": String(localized: "Contacts"),
            "reminder": String(localized: "Reminders"),
            "set_alarm": String(localized: "Alarm"),
            "brightness": String(localized: "Brightness"),
            "smart_home": String(localized: "Smart Home"),
            "run_shortcut": String(localized: "Siri Shortcuts"),
            "summarize_conversation": String(localized: "Summarize"),
            "face_recognition": String(localized: "Face Recognition"),
            "memory_rewind": String(localized: "Memory Rewind"),
            "geofence": String(localized: "Geofence Alerts"),
            "send_via": String(localized: "Multi-Channel Message"),
            "meeting_summary": String(localized: "Meeting Summary"),
            "fitness_coach": String(localized: "Fitness Coach"),
            "goals": String(localized: "Goals"),
            "activity": String(localized: "Activity"),
            "openclaw_skills": String(localized: "OpenClaw Skills"),
            "voice_skills": String(localized: "Voice Skills"),
            "object_memory": String(localized: "Object Memory"),
            "contextual_note": String(localized: "Contextual Notes"),
            "social_context": String(localized: "Social Context"),
            "home_assistant": "Home Assistant",
            "scan_code": String(localized: "QR & Barcode Scanner"),
            "live_translate": String(localized: "Live Translation"),
        ]
        if let override = overrides[toolName] { return override }
        // Fallback: convert_currency → Convert Currency
        return toolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// JSON-schema type names → words a reader recognises.
    static func friendlyType(_ type: String?) -> String {
        switch type {
        case "string": return String(localized: "text")
        case "integer", "number": return String(localized: "number")
        case "boolean": return String(localized: "yes / no")
        case "array": return String(localized: "list")
        case "object": return String(localized: "details")
        default: return type ?? ""
        }
    }

    private var filteredTools: [(name: String, displayName: String, description: String, params: [String: Any])] {
        if searchText.isEmpty { return allTools }
        let query = searchText.lowercased()
        return allTools.filter {
            $0.name.lowercased().contains(query) ||
            $0.displayName.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    private var enabledCount: Int {
        allTools.filter { !disabledTools.contains($0.name) }.count
    }

    var body: some View {
        List {
            Section {
                InfoToggle(
                    title: "Offline Mode",
                    isOn: $offlineMode,
                    info: "Disables all tools that require an internet connection — weather, web search, news, currency conversion, Shazam, translation, and more. The LLM connection itself is unaffected. Useful on planes or in areas with poor connectivity."
                )
                .onChange(of: offlineMode) { _, enabled in
                    Config.setOfflineModeEnabled(enabled)
                    disabledTools = Config.disabledTools
                }
            } header: {
                Text("Connectivity")
            } footer: {
                Text("Offline Mode hides every tool that needs the internet — handy on planes or in poor coverage. The AI itself still works if you can reach it.")
            }

            Section {
                LabeledContent("Total tools", value: "\(allTools.count)")
                LabeledContent("Enabled", value: "\(enabledCount) of \(allTools.count)")
            } header: {
                Text("Overview")
            } footer: {
                Text("Disabled tools are stripped from the AI's prompt entirely — it won't even know they exist. Use this to narrow the AI's reach or save tokens.")
            }

            Section {
                ForEach(filteredTools, id: \.name) { tool in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            // What the tool does, in the words the AI itself is given —
                            // the schema below is meaningless without it.
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(Color(.label))
                                .fixedSize(horizontal: false, vertical: true)

                            if let properties = tool.params["properties"] as? [String: Any], !properties.isEmpty {
                                Text("Parameters")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                let requiredParams = (tool.params["required"] as? [String]) ?? []
                                ForEach(Array(properties.keys.sorted()), id: \.self) { key in
                                    if let paramInfo = properties[key] as? [String: Any] {
                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                Text(key)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundStyle(Color(.label))
                                                if !requiredParams.contains(key) {
                                                    Text("optional")
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                }
                                                Spacer()
                                                Text(Self.friendlyType(paramInfo["type"] as? String))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            // The schema's own description — the same text that
                                            // tells the AI what to pass — beats a bare type name.
                                            if let description = paramInfo["description"] as? String, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            if let choices = paramInfo["enum"] as? [String], !choices.isEmpty {
                                                Text("One of: \(choices.joined(separator: ", "))")
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { !disabledTools.contains(tool.name) },
                                set: { enabled in
                                    if enabled {
                                        // Request permission if this tool needs one
                                        if let permission = ToolPermissionGate.permissionName(for: tool.name) {
                                            Task {
                                                let granted = await ToolPermissionGate.requestPermission(for: tool.name)
                                                if granted {
                                                    disabledTools.remove(tool.name)
                                                    Config.setDisabledTools(disabledTools)
                                                } else {
                                                    permissionDeniedTool = permission
                                                }
                                            }
                                        } else {
                                            disabledTools.remove(tool.name)
                                            Config.setDisabledTools(disabledTools)
                                        }
                                    } else {
                                        disabledTools.insert(tool.name)
                                        Config.setDisabledTools(disabledTools)
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.displayName)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(tool.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    // Plan HA C4: only an administrator still sees a closed tool —
                                    // off, read-only, with the organisation named.
                                    if adminGate.presentation(.tool(tool.name)) == .readOnly {
                                        ManagedLockNote(organization: ManagedLockReason.organization)
                                    }
                                }
                            }
                            .disabled(!adminGate.presentation(.tool(tool.name)).isEditable)
                        }
                    }
                }
            } header: {
                Text("Native Tools")
            } footer: {
                Text("Built-in capabilities that run on your phone. Tap a row to see what arguments the AI passes when it calls a tool. Some tools (Calendar, Contacts, Reminders, Health, Notifications) need iOS permission the first time you enable them.")
            }

            if Config.isOpenClawConfigured {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenClaw Gateway")
                            Text("56+ tools via your Mac — messaging, web search, smart home, and more.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network")
                            .foregroundStyle(OGTheme.okLabel)
                    }
                } header: {
                    Text("External Tools")
                } footer: {
                    Text("OpenClaw tools are managed on your Mac. The 'execute' tool is added to the prompt when the gateway is connected.")
                }
            }
        }
        .navigationTitle("Tools")
        .ogFormStyle()
        .searchable(text: $searchText, prompt: "Search tools")
        .alert("Permission Denied", isPresented: Binding(
            get: { permissionDeniedTool != nil },
            set: { if !$0 { permissionDeniedTool = nil } }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                permissionDeniedTool = nil
            }
            Button("Cancel", role: .cancel) { permissionDeniedTool = nil }
        } message: {
            Text("\(permissionDeniedTool ?? "Permission") was denied. You can grant it in iPhone Settings → Apps → Avenkin.")
        }
    }
}
