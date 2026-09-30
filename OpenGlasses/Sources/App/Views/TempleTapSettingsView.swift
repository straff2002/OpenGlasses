import SwiftUI

/// Settings → Hardware & Privacy → Temple Taps (Plan GJ P1): the on/off switch, what one, two and
/// three taps do, and a test mode that only announces each tap — which is also how the tap-to-command
/// mapping gets checked on a given pair of glasses.
struct TempleTapSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var taps: TempleGestureDispatcher

    @State private var enabled = Config.mediaTriggerEnabled
    @State private var map = Config.templeGestureMap
    @State private var quickActions = Config.quickActions
    @State private var agentModeEnabled = Config.agentModeEnabled

    private let calibration = TempleCalibration.current

    init(appState: AppState) {
        self.appState = appState
        self.taps = appState.templeTaps
    }

    var body: some View {
        Form {
            Section {
                InfoToggle(
                    title: String(localized: "Temple Taps (Experimental)"),
                    isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            enabled = newValue
                            Config.setMediaTriggerEnabled(newValue)
                            appState.mediaTrigger.refresh()
                        }
                    ),
                    info: String(localized: "Tap the temple of your glasses to control Avenkin without a wake word or touching your phone — it works with the phone locked in a pocket. Avenkin holds the phone's Now Playing slot while nothing else is playing, so it steps aside whenever your own music or podcasts play; with music playing, your taps control the music.")
                )
            } footer: {
                Text("Pauses while your own music plays. The long press and capture button stay with your glasses.")
            }

            Section {
                ForEach(TempleGesture.allCases) { gesture in
                    Picker(gesture.displayName, selection: binding(for: gesture)) {
                        ForEach(options(for: gesture), id: \.self) { action in
                            Text(label(for: action)).tag(action)
                        }
                    }
                }
            } header: {
                Text("What Each Tap Does")
            } footer: {
                Text(tapsFooter)
            }
            .disabled(!enabled)

            Section {
                Toggle("Test Taps", isOn: $taps.testMode)
                    .disabled(!enabled)
                if let detection = taps.lastDetection {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detection.gesture.displayName)
                            .font(.body)
                        Text(verbatim: detection.command.spokenName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Test")
            } footer: {
                Text("While testing, taps are only announced — nothing runs. Tap once, twice and three times to hear what your glasses send.")
            }
        }
        .navigationTitle("Temple Taps")
        .ogFormStyle()
        .onAppear {
            map = Config.templeGestureMap
            quickActions = Config.quickActions
            agentModeEnabled = Config.agentModeEnabled
        }
        .onDisappear { taps.testMode = false }
    }

    // MARK: - Pickers

    private func binding(for gesture: TempleGesture) -> Binding<TempleAction> {
        Binding(
            get: { map.action(for: gesture) },
            set: { newValue in
                map.set(newValue, for: gesture)
                Config.setTempleGestureMap(map)
            }
        )
    }

    /// Built-in actions, then saved Quick Actions. "Ask my agent" is offered only with Agent Mode
    /// on — but a tap already assigned to it keeps showing it, so the picker never loses its value.
    private func options(for gesture: TempleGesture) -> [TempleAction] {
        let current = map.action(for: gesture)
        var result = TempleAction.builtIns.filter { action in
            !action.requiresAgentMode || agentModeEnabled || action == current
        }
        result += quickActions.map { .quickAction($0.id) }
        if case .quickAction = current, !result.contains(current) {
            result.append(current)
        }
        return result
    }

    private func label(for action: TempleAction) -> String {
        switch action {
        case .quickAction(let id):
            if let saved = quickActions.first(where: { $0.id == id }) {
                return String(localized: "Quick Action: \(saved.label)")
            }
            return String(localized: "Quick Action (removed)")
        case .askAgent where !agentModeEnabled:
            return String(localized: "Ask my agent (Agent Mode is off)")
        default:
            return action.displayName
        }
    }

    private var usesSessionControl: Bool {
        TempleGesture.allCases.contains { gesture in
            let action = map.action(for: gesture)
            return action == .hangUp || action == .mute
        }
    }

    private var tapsFooter: String {
        if !calibration.sessionControlAvailable {
            return String(localized: "Hanging up and muting during a conversation aren't available on these glasses — taps don't reach Avenkin while it is talking. They still work between conversations.")
        }
        if usesSessionControl && !calibration.sessionControlConfirmed {
            return String(localized: "Hanging up and muting during a conversation depend on your glasses sending taps while Avenkin is talking, which hasn't been confirmed on glasses yet. Photos only use the glasses camera — never the phone's.")
        }
        return String(localized: "Photos only use the glasses camera — never the phone's.")
    }
}
