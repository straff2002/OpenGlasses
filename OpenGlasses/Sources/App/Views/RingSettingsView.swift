#if !AVENKIN_PHONE_ONLY
import SwiftUI

/// Devices & Privacy › Smart Ring (Plan MZ P2): pair a ring, its status, what reaches Apple Health,
/// automatic heart rate, the clench trigger, Find Ring, Sync Now, deleting its readings and
/// forgetting it. Its own row in Devices & Privacy, beside Apple Watch.
struct RingSettingsView: View {
    @ObservedObject var ring: RingService

    @State private var heartRate = RingHeartRateSetting(minutes: Config.ringHeartRateMinutes)
    @State private var triggerEnabled = Config.ringTriggerEnabled
    @State private var triggerAction = TempleAction(rawValue: Config.ringTriggerActionRaw)
    @State private var quickActions = Config.quickActions
    @State private var agentModeEnabled = Config.agentModeEnabled
    @State private var confirmDelete = false
    @State private var confirmForget = false
    @State private var actionNote: String?
    @State private var working = false

    var body: some View {
        Form {
            if ring.isPaired {
                statusSection
                if let notice = ring.otherAppNotice { otherAppSection(notice) }
                healthSection
                heartRateSection
                triggerSection
                actionsSection
                removalSection
            } else {
                pairingSection
            }

            Section {
                EmptyView()
            } footer: {
                Text("Readings are estimates from a consumer ring, not medical measurements.")
            }
        }
        .navigationTitle("Smart Ring")
        .ogFormStyle()
        .onAppear {
            quickActions = Config.quickActions
            agentModeEnabled = Config.agentModeEnabled
        }
        .onDisappear { ring.stopScan() }
        .confirmationDialog("Delete ring readings from Apple Health?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete Ring Readings", role: .destructive) { deleteReadings() }
        } message: {
            Text("Removes the heart rate, blood oxygen, sleep and steps Avenkin saved from a ring. Nothing else in Apple Health is touched. This can't be undone.")
        }
        .confirmationDialog("Forget this ring?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Ring", role: .destructive) {
                Task { await ring.forget() }
            }
        } message: {
            Text("Avenkin stops talking to the ring. Its readings stay in Apple Health. Also forget the ring in iOS Settings › Bluetooth.")
        }
    }

    // MARK: - Not paired

    private var pairingSection: some View {
        Section {
            if ring.scanning {
                Button("Stop Looking") { ring.stopScan() }
                ForEach(ring.candidates) { candidate in
                    Button {
                        pair(candidate)
                    } label: {
                        HStack {
                            Label(candidate.displayName, systemImage: "circle.circle")
                            Spacer()
                            if candidate.heldByAnotherApp {
                                Text("In use by another app")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(working)
                }
                if ring.candidates.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for your ring…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let notice = ring.otherAppNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Pair a Ring") {
                    if !ring.isRunning { ring.start() }
                    ring.startScan()
                }
            }
        } header: {
            Text("Pair")
        } footer: {
            Text("Keep the ring close to your iPhone and pick it here. iOS may ask to pair it; allow that. Avenkin then asks to save the ring's readings to Apple Health.")
        }
    }

    // MARK: - Paired

    private var statusSection: some View {
        Section {
            LabeledContent("Connection", value: linkText)
            if let battery = ring.battery {
                LabeledContent("Battery", value: "\(battery)%")
            }
            LabeledContent("Last sync", value: lastSyncText)
            if ring.syncing {
                HStack {
                    ProgressView()
                    Text("Syncing…")
                        .foregroundStyle(.secondary)
                }
            }
            if ring.lastWriteRefusal == .notAuthorized {
                Text("Apple Health isn't allowing Avenkin to save ring readings. Allow it below, or in the Health app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Ring")
        }
    }

    private func otherAppSection(_ notice: String) -> some View {
        Section {
            Text(notice)
            Button("OK") { ring.dismissOtherAppNotice() }
        }
    }

    private var healthSection: some View {
        Section {
            Button("Allow Apple Health Access") {
                Task { _ = await ToolPermissionGate.requestPermission(for: RingTool.toolName) }
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("The ring's heart rate, blood oxygen, sleep and steps are saved to Apple Health with Avenkin as the source, and health summaries read them back from there. When your iPhone or Apple Watch also counts steps, Health's own source order decides which count is used.")
        }
    }

    private var heartRateSection: some View {
        Section {
            Picker("Automatic heart rate", selection: $heartRate) {
                ForEach(RingHeartRateSetting.allCases) { setting in
                    Text(verbatim: setting.label).tag(setting)
                }
            }
            .onChange(of: heartRate) { _, newValue in
                Config.ringHeartRateMinutes = newValue.rawValue
                ring.heartRateScheduleChanged(newValue.schedule)
            }
        } footer: {
            Text("How often the ring measures your heart rate on its own. More often uses more of the ring's battery.")
        }
    }

    private var triggerSection: some View {
        Section {
            Toggle("Clench to trigger", isOn: $triggerEnabled)
                .onChange(of: triggerEnabled) { _, newValue in
                    Config.ringTriggerEnabled = newValue
                    ring.triggerEnabledChanged(newValue)
                }
            if triggerEnabled {
                Picker("A clench", selection: $triggerAction) {
                    ForEach(actionOptions, id: \.self) { action in
                        Text(verbatim: label(for: action)).tag(action)
                    }
                }
                .onChange(of: triggerAction) { _, newValue in
                    Config.ringTriggerActionRaw = newValue.rawValue
                }
            }
        } header: {
            Text("Ring Trigger")
        } footer: {
            Text("Clench or flick the hand wearing the ring to do this, with the same tone as a temple tap. An ordinary hand movement can set it off, so photo and recording actions need two clenches in quick succession. Nothing happens while the assistant is listening or speaking.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Find Ring") {
                Task {
                    working = true
                    let lit = await ring.findRing()
                    working = false
                    actionNote = lit ? String(localized: "The ring is lit up.") : String(localized: "The ring didn't answer.")
                }
            }
            .disabled(!ring.isConnected || working)
            Button("Sync Now") { ring.syncNow() }
                .disabled(!ring.isConnected || ring.syncing)
            if let actionNote {
                Text(verbatim: actionNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var removalSection: some View {
        Section {
            Button("Delete Ring Readings from Apple Health", role: .destructive) { confirmDelete = true }
            Button("Forget Ring", role: .destructive) { confirmForget = true }
        } footer: {
            Text("Forgetting the ring keeps its readings in Apple Health. To let another phone or app use the ring, also forget it in iOS Settings › Bluetooth.")
        }
    }

    // MARK: - Pieces

    private func pair(_ candidate: RingCandidate) {
        working = true
        Task {
            // The writer's share types, asked for when the ring is paired (Plan MZ §1).
            _ = await ToolPermissionGate.requestPermission(for: RingTool.toolName)
            ring.pair(candidate)
            working = false
        }
    }

    private func deleteReadings() {
        Task {
            do {
                let count = try await ring.deleteRingReadings()
                actionNote = String(localized: "Deleted \(count) ring readings from Apple Health.")
            } catch {
                actionNote = String(localized: "Apple Health didn't allow the deletion. Unlock your iPhone and try again.")
            }
        }
    }

    private var linkText: String {
        switch ring.link {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Looking for your ring…")
        case .bluetoothOff: return String(localized: "Bluetooth is off")
        case .bluetoothDenied: return String(localized: "Bluetooth access is off")
        case .notPaired: return String(localized: "Not paired")
        case .stopped: return String(localized: "Off")
        }
    }

    private var lastSyncText: String {
        guard let last = ring.lastSync else { return String(localized: "Not yet") }
        return last.formatted(.relative(presentation: .named))
    }

    /// Built-in actions, then saved Quick Actions, as the temple taps offer them.
    private var actionOptions: [TempleAction] {
        var result = TempleAction.builtIns.filter { action in
            !action.requiresAgentMode || agentModeEnabled || action == triggerAction
        }
        result += quickActions.map { .quickAction($0.id) }
        if case .quickAction = triggerAction, !result.contains(triggerAction) { result.append(triggerAction) }
        return result
    }

    private func label(for action: TempleAction) -> String {
        let base: String
        switch action {
        case .quickAction(let id):
            if let saved = quickActions.first(where: { $0.id == id }) {
                base = String(localized: "Quick Action: \(saved.label)")
            } else {
                base = String(localized: "Quick Action (removed)")
            }
        default:
            base = action.displayName
        }
        return RingTriggerSetting.needsDoubleClench(action)
            ? String(localized: "\(base) (two clenches)") : base
    }
}

/// Developer panel › Ring packets (Plan MZ P2): the opcodes the driver doesn't read and how often
/// each came, and the last twenty packets. On this screen only: the log lives in memory and is
/// never saved, logged or put in a support report.
struct RingPacketLogView: View {
    @ObservedObject var log: RingPacketLog

    var body: some View {
        Form {
            Section {
                if log.unknownOpcodes.isEmpty {
                    Text("None yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(log.unknownOpcodes.keys.sorted(), id: \.self) { opcode in
                    LabeledContent(String(format: "0x%02x", opcode), value: "\(log.unknownOpcodes[opcode] ?? 0)")
                }
                if log.malformedCount > 0 {
                    LabeledContent("Wrong length", value: "\(log.malformedCount)")
                }
            } header: {
                Text("Unknown Packets")
            }

            Section {
                ForEach(log.recent.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.direction == .sent ? "Sent" : "Received")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(verbatim: entry.hex)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Last Twenty Packets")
            } footer: {
                Text("Shown here only, newest first. Never saved, logged or added to a support report.")
            }

            Section {
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
        .navigationTitle("Ring Packets")
        .ogFormStyle()
    }
}
#endif
