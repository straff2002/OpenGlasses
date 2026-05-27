import SwiftUI
import EventKit
import Contacts
import UserNotifications
import HealthKit

/// Lists all registered native tools with toggle, description, and parameter info.
/// Part of the open-source transparency — users can see and control what the AI can do.
struct ToolsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var disabledTools: Set<String> = Config.disabledTools
    @State private var offlineMode: Bool = Config.offlineModeEnabled
    @State private var searchText = ""
    @State private var permissionDeniedTool: String?

    /// Tools that require a system permission when enabled.
    private static let permissionTools: [String: String] = [
        "calendar": "Calendar access",
        "reminder": "Reminders access",
        "lookup_contact": "Contacts access",
        "set_alarm": "Notification permission",
        "fitness_coach": "HealthKit access",
    ]

    private var allTools: [(name: String, displayName: String, description: String, params: [String: Any])] {
        appState.nativeToolRouter.registry.allTools
            .map { (name: $0.name, displayName: Self.displayName(for: $0.name), description: $0.description, params: $0.parametersSchema) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Convert tool IDs like "get_weather" → "Weather", "convert_currency" → "Currency Conversion"
    private static func displayName(for toolName: String) -> String {
        let overrides: [String: String] = [
            "get_weather": "Weather",
            "get_datetime": "Date & Time",
            "daily_briefing": "Daily Briefing",
            "calculate": "Calculator",
            "convert_units": "Unit Conversion",
            "set_timer": "Timer",
            "pomodoro": "Pomodoro Timer",
            "save_note": "Save Note",
            "list_notes": "Notes",
            "web_search": "Web Search",
            "get_news": "News",
            "translate": "Translation",
            "define_word": "Dictionary",
            "find_nearby": "Nearby Places",
            "open_app": "Open App",
            "get_directions": "Directions",
            "identify_song": "Song Recognition",
            "music_control": "Music Control",
            "convert_currency": "Currency Conversion",
            "phone_call": "Phone Call",
            "send_message": "Send Message",
            "copy_to_clipboard": "Clipboard",
            "flashlight": "Flashlight",
            "device_info": "Device Info",
            "save_location": "Save Location",
            "list_saved_locations": "Saved Locations",
            "step_count": "Step Counter",
            "emergency_info": "Emergency Info",
            "calendar": "Calendar",
            "lookup_contact": "Contacts",
            "reminder": "Reminders",
            "set_alarm": "Alarm",
            "brightness": "Brightness",
            "smart_home": "Smart Home",
            "run_shortcut": "Siri Shortcuts",
            "summarize_conversation": "Summarize",
            "face_recognition": "Face Recognition",
            "memory_rewind": "Memory Rewind",
            "geofence": "Geofence Alerts",
            "send_via": "Multi-Channel Message",
            "meeting_summary": "Meeting Summary",
            "fitness_coach": "Fitness Coach",
            "openclaw_skills": "OpenClaw Skills",
            "voice_skills": "Voice Skills",
            "object_memory": "Object Memory",
            "contextual_note": "Contextual Notes",
            "social_context": "Social Context",
            "home_assistant": "Home Assistant",
            "scan_code": "QR & Barcode Scanner",
            "live_translate": "Live Translation",
        ]
        if let override = overrides[toolName] { return override }
        // Fallback: convert_currency → Convert Currency
        return toolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
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
                            if let properties = tool.params["properties"] as? [String: Any], !properties.isEmpty {
                                Text("Parameters")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(Array(properties.keys.sorted()), id: \.self) { key in
                                    if let paramInfo = properties[key] as? [String: Any] {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(key)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(Color(.label))
                                            Spacer()
                                            Text(paramInfo["type"] as? String ?? "any")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
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
                                        if Self.permissionTools[tool.name] != nil {
                                            Task {
                                                let granted = await requestPermission(for: tool.name)
                                                if granted {
                                                    disabledTools.remove(tool.name)
                                                    Config.setDisabledTools(disabledTools)
                                                } else {
                                                    permissionDeniedTool = Self.permissionTools[tool.name]
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
                                }
                            }
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
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("External Tools")
                } footer: {
                    Text("OpenClaw tools are managed on your Mac. The 'execute' tool is added to the prompt when the gateway is connected.")
                }
            }
        }
        .navigationTitle("Tools")
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
            Text("\(permissionDeniedTool ?? "Permission") was denied. You can grant it in Settings.")
        }
    }

    // MARK: - Permission Requests

    /// Request the appropriate system permission for a tool. Returns true if granted.
    private func requestPermission(for toolName: String) async -> Bool {
        switch toolName {
        case "calendar":
            let store = EKEventStore()
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        case "reminder":
            let store = EKEventStore()
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        case "lookup_contact":
            let store = CNContactStore()
            do {
                return try await store.requestAccess(for: .contacts)
            } catch {
                return false
            }
        case "set_alarm":
            let center = UNUserNotificationCenter.current()
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case "fitness_coach":
            let healthStore = HKHealthStore()
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            let readTypes: Set<HKObjectType> = [
                HKObjectType.quantityType(forIdentifier: .stepCount)!,
                HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            ]
            do {
                try await healthStore.requestAuthorization(toShare: [], read: readTypes)
                return true
            } catch {
                return false
            }
        default:
            return true
        }
    }
}
