import SwiftUI

/// Settings › Field Assist › Stock system (Plan MM §3, P2): the connection to the business's own
/// stock system, in JR's steps — paste a key, test the connection, choose which stock is here, and
/// what goes back — and Remove connection. One view for every system: the system's name, hosts,
/// permissions and reasons come from its adapter through `StockSystemAdapterRegistry`, so this
/// file names no vendor.
struct StockSystemSettingsView: View {
    @ObservedObject var service: StockSystemService
    @ObservedObject private var gate = AdminGate.shared
    @State private var key = ""
    @State private var environment: StockSystemEnvironment = .production
    @State private var problem: String?
    @State private var unlocking = false

    private var connection: StockSystemConnectionStore { service.connection }
    private var administrator: Bool { gate.isSessionLive || gate.isAdministratorPhone }
    private var canEditKey: Bool { !PolicyEnvelope.isManaged || administrator }
    private var registration: StockSystemRegistration? { service.registration }
    private var system: String { service.displayName }

    var body: some View {
        Form {
            if connection.officeRoute {
                Section { Text("Your office connects your stock system for you.") }
            } else if !connection.enabled {
                Section { Text("Your organisation has turned off the stock system connection on this phone.") }
            } else if let registration {
                systemSection
                keySection(registration)
                if connection.record != nil {
                    locationsSection
                    goesBackSection(registration)
                    statusSection
                    removeSection
                }
            }
        }
        .ogFormStyle()
        .navigationTitle("Stock system")
        .onAppear { environment = connection.record?.environment ?? .production }
        .onReceive(NotificationCenter.default.publisher(for: .orgPolicyDidChange)) { _ in
            key = ""
            service.enforceRoute()
        }
        .onDisappear { key = "" }
    }

    // MARK: - The system

    @ViewBuilder
    private var systemSection: some View {
        let locked = PolicyEnvelope.isLocked(.stockSystemConnector)
        Section {
            Picker("System", selection: Binding(get: { connection.selectedConnectorID },
                                                set: { id in
                                                    guard id != connection.selectedConnectorID else { return }
                                                    try? connection.select(id)
                                                    environment = connection.record?.environment ?? .production
                                                })) {
                ForEach(StockSystemAdapterRegistry.all, id: \.connectorID) { entry in
                    Text(entry.displayName).tag(entry.connectorID)
                }
            }
            .disabled(locked)
            .accessibilityIdentifier("stockSystem.system")
            if locked { ManagedLockNote(organization: ManagedLockReason.organization) }
        } footer: {
            Text("The system where the business already keeps its stock count. This phone reads that count instead of keeping its own.")
        }
    }

    // MARK: - Step 1 and 2: the key, and Test connection

    @ViewBuilder
    private func keySection(_ registration: StockSystemRegistration) -> some View {
        Section {
            if let record = connection.record {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "key.fill").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key stored on this phone").fixedSize(horizontal: false, vertical: true)
                        (record.environment == .production ? Text("The business's account") : Text("A sandbox for testing"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if administrator, let ending = connection.keyEnding {
                            Text("Ends in …\(ending)").font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("stockSystem.keyEnding")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if registration.sandboxName != nil {
                Picker("Account", selection: $environment) {
                    Text("The business's account").tag(StockSystemEnvironment.production)
                    Text("A sandbox for testing").tag(StockSystemEnvironment.sandbox)
                }
                .disabled(!canEditKey)
                .accessibilityIdentifier("stockSystem.environment")
            }
            SecureField(registration.keyName.capitalizedFirst, text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!canEditKey)
                .accessibilityIdentifier("stockSystem.key")
            Button("Save key") { save(registration) }
                .disabled(key.isEmpty || !canEditKey)
                .accessibilityIdentifier("stockSystem.save")
            if !canEditKey {
                if let policy = gate.policy, gate.offersUnlock {
                    Button("Unlock Administrator Settings") { unlocking = true }
                        .sheet(isPresented: $unlocking) { AdminUnlockSheet(gate: gate, policy: policy) }
                } else {
                    Text("Your administrator must open an administrator session to change this key.")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await service.testConnection() }
            } label: {
                Text(service.testing ? "Testing…" : "Test connection").fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!service.isRunning || service.testing)
            .accessibilityIdentifier("stockSystem.test")
            if service.isBlockedByMedical {
                Text(MedicalEgressRefusal.userMessage).font(.footnote)
            }
            if let line = problem ?? connection.problem ?? service.connectionLine {
                Text(line).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("stockSystem.message")
            }
        } header: {
            Text("\(system) key")
        } footer: {
            keyHelp(registration)
        }
    }

    private func keyHelp(_ registration: StockSystemRegistration) -> some View {
        let reading = StockSystemKeyPermissions.reading(registration.adapter)
        let sending = StockSystemKeyPermissions.sendingBack(registration.adapter)
        return VStack(alignment: .leading, spacing: 6) {
            Text("How to make a key").font(.footnote.weight(.semibold))
            ForEach(Array(registration.keySteps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
            }
            Text("To read stock, this phone uses only: \(reading.joined(separator: ", ")).")
            if !sending.isEmpty {
                Text("Sending parts used back also uses: \(sending.joined(separator: ", ")). That is only used once sending back is on.")
            }
        }
    }

    private func save(_ registration: StockSystemRegistration) {
        do {
            try connection.pasteKey(key, environment: environment, administrator: canEditKey,
                                    hasSandbox: registration.adapter.hosts.sandbox != nil)
            service.keyChanged()
            key = ""
            problem = nil
            Task { await service.testConnection() }
        } catch StockSystemConnectionError.badKey {
            key = ""
            problem = String(localized: "That doesn't look like a key. Copy it again, without spaces, and paste it here.")
        } catch {
            key = ""
            problem = String(localized: "The key could not be saved. Check administrator access and unlock this phone.")
        }
    }

    // MARK: - Step 3: which stock is here

    @ViewBuilder
    private var locationsSection: some View {
        let chosen = Set(connection.record?.locationIDs ?? [])
        let shown = service.availableLocations.isEmpty ? (connection.record?.locations ?? []) : service.availableLocations
        Section {
            if shown.isEmpty {
                Text("Test the connection to list the business's locations.").foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.id) { location in
                Button {
                    toggle(location, chosen: chosen, shown: shown)
                } label: {
                    HStack {
                        Text(location.name.isEmpty ? location.id : location.name)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if chosen.contains(location.id) {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(chosen.contains(location.id) ? .isSelected : [])
                .accessibilityIdentifier("stockSystem.location." + location.id)
            }
            Button {
                Task { await service.loadLocations() }
            } label: {
                Text(service.loadingLocations ? "Loading locations…" : "Load the locations again")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!service.isRunning || service.loadingLocations)
        } header: {
            Text("Which stock is here?")
        } footer: {
            Text("Choose the \(system) locations whose stock is this place's. The choice is kept with this connection, on this phone only.")
        }
    }

    private func toggle(_ location: StockSystemLocation, chosen: Set<String>, shown: [StockSystemLocation]) {
        var ids = chosen
        if ids.contains(location.id) { ids.remove(location.id) } else { ids.insert(location.id) }
        let known = shown + (connection.record?.locations ?? [])
        var seen = Set<String>()
        let next = known.filter { ids.contains($0.id) && seen.insert($0.id).inserted }
        Task {
            do { try await service.chooseLocations(next) }
            catch { problem = String(localized: "The choice could not be saved. Unlock this phone and try again.") }
        }
    }

    // MARK: - Step 5: what goes back

    @ViewBuilder
    private func goesBackSection(_ registration: StockSystemRegistration) -> some View {
        let sendLocked = PolicyEnvelope.isLocked(.stockSystemSendBack)
        let reasonLocked = PolicyEnvelope.isLocked(.stockSystemAdjustmentReason)
        let kept = registration.adapter.capabilities(chosenReason: nil).adjustmentReasons
        let reasons = StockAdjustmentReason.ordered(kept)
        // What is shown is what is sent with (`StockAdjustmentReason.effective`), never a default
        // the store does not hold.
        let effective = connection.effectiveReason(kept: kept)
        Section {
            Toggle("Send parts used back to \(system)", isOn: Binding(get: { connection.sendingBack },
                                                                     set: { try? connection.setSendingBack($0, kept: kept) }))
                .disabled(sendLocked)
                .accessibilityIdentifier("stockSystem.sendBack")
            if !reasons.isEmpty {
                Picker("Recorded as", selection: Binding(get: { effective },
                                                         set: { if let reason = $0 { try? connection.setReason(reason) } })) {
                    if effective == nil {
                        Text("Not chosen").tag(StockAdjustmentReason?.none)
                    }
                    ForEach(reasons, id: \.self) { reason in
                        Text(Self.words(reason)).tag(StockAdjustmentReason?.some(reason))
                    }
                }
                .disabled(reasonLocked || !connection.sendingBack)
                .accessibilityIdentifier("stockSystem.reason")
                if connection.sendingBack, effective == nil {
                    (reasonLocked
                        ? Text("Your organisation chose a reason \(system) doesn't keep, so parts used are not sent.")
                        : Text("Choose what parts used are recorded as. Until then nothing is sent."))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("stockSystem.reasonMissing")
                }
            }
            if sendLocked || reasonLocked { ManagedLockNote(organization: ManagedLockReason.organization) }
        } header: {
            Text("What goes back")
        } footer: {
            Text("Off until someone turns it on. Parts used go to \(system) only after a person confirms them at the end of a job, and \(system)'s count is never set from this phone. What goes to \(system): part numbers and quantities used, and the locations you choose. It is the business's own account.")
        }
    }

    /// A reason in plain words.
    static func words(_ reason: StockAdjustmentReason) -> String {
        switch reason {
        case .waste: return String(localized: "Written off as waste")
        case .internalUse: return String(localized: "Used in the business")
        case .damage: return String(localized: "Written off as damaged")
        }
    }

    // MARK: - Status and Remove connection

    @ViewBuilder
    private var statusSection: some View {
        if service.statusLine != nil || service.pullMessage != nil || service.pulling {
            Section {
                if service.pulling { Text("Reading the figures…").foregroundStyle(.secondary) }
                if let line = service.statusLine { Text(line).accessibilityIdentifier("stockSystem.status") }
                if let message = service.pullMessage { Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true) }
            } header: {
                Text("Figures on this phone")
            }
        }
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                service.remove()
                key = ""
                problem = nil
            } label: {
                Text("Remove connection").fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(OGTheme.errorLabel)
            .disabled(!canEditKey)
            .accessibilityIdentifier("stockSystem.remove")
        } footer: {
            Text("Erases the key, the choices above and the figures this phone read.")
        }
    }
}

private extension String {
    /// "Personal access token".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
