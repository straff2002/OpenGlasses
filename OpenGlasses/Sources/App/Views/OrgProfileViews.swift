import SwiftUI

/// Mounts the enrolment review over the root view (Plan CT PR 2). Its own `@ObservedObject`, so a
/// stage change repaints even though the service hangs off `AppState`.
struct OrgEnrolmentOverlay: View {
    @ObservedObject var service: OrgEnrolmentService

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { service.stage != .idle },
                set: { if !$0 { service.dismiss() } })) {
                OrgEnrolmentSheet(service: service)
            }
    }
}

/// The review an organisation profile gets before anything on the phone changes: the host, then
/// who it is from, what it locks, what it sets, and what this version of the app could not use.
struct OrgEnrolmentSheet: View {
    @ObservedObject var service: OrgEnrolmentService

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Organisation Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { service.dismiss() } label: {
                            if isFinished {
                                Text("Done")
                            } else if case .modelKey = service.stage {
                                Text("Later")
                            } else {
                                Text("Cancel")
                            }
                        }
                        .disabled(service.stage.isBusy)
                    }
                }
        }
        .interactiveDismissDisabled(service.stage.isBusy)
    }

    private var isFinished: Bool {
        switch service.stage {
        case .applied, .failed: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch service.stage {
        case .idle:
            EmptyView()

        case .offer(let host):
            List {
                Section {
                    Text(verbatim: host)
                        .font(.headline)
                } footer: {
                    Text("A link asked this phone to take an organisation's configuration profile from this site. Nothing changes until you have reviewed what it does.")
                }
                Section {
                    Button("Fetch the profile") {
                        Task { await service.approveFetch() }
                    }
                }
            }

        case .fetching(let host):
            VStack(spacing: 12) {
                ProgressView()
                if let licensee = service.settingUpFor {
                    // A licence key named its organisation's profile (Plan CT 3a): the vendor signed
                    // that address, so the organisation is what is worth showing, not the host.
                    Text("Setting up this phone for \(licensee)")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                Text(verbatim: host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Fetching the profile"))

        case .reviewing(let review):
            OrgProfileReviewList(review: review) { service.confirm() }

        case .modelKey(let model, let organization):
            OrgModelKeyPage(model: model, organization: organization,
                            submit: { service.submitModelKey($0) },
                            later: { service.deferModelKey() })

        case .applied(let name):
            List {
                Section {
                    Label {
                        Text(verbatim: name)
                    } icon: {
                        Image(systemName: "building.2")
                    }
                } footer: {
                    Text("This phone is now managed by this organisation. Settings it locks show its name, and the device owner can remove the profile from Settings.")
                }
            }

        case .failed(let message):
            List {
                Section {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
            }
        }
    }
}

/// The review itself, split out so the sheet body stays one switch.
private struct OrgProfileReviewList: View {
    let review: OrgProfileReview
    let apply: () -> Void

    var body: some View {
        List {
            Section {
                Text(verbatim: review.organizationName)
                    .font(.headline)
                if review.replacesCurrent {
                    Text("This renews the profile already in force.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("From")
            }

            if !review.lockLines.isEmpty {
                Section {
                    ForEach(review.lockLines, id: \.self) { line in
                        Label { Text(verbatim: line) } icon: { Image(systemName: "lock.fill") }
                    }
                } header: {
                    Text("Locks")
                } footer: {
                    Text("Nobody on this phone can change these while the profile is in force.")
                }
            }

            if !review.startingValueLines.isEmpty {
                Section {
                    ForEach(review.startingValueLines, id: \.self) { Text(verbatim: $0) }
                } header: {
                    Text("Sets as a starting point")
                } footer: {
                    Text("You can change these afterwards.")
                }
            }

            if !review.adminLines.isEmpty {
                Section {
                    ForEach(review.adminLines, id: \.self) { Text(verbatim: $0) }
                } header: {
                    Text("What this phone shows")
                } footer: {
                    Text("Hidden is not locked: the administrator can open everything else, but the locks above still apply to everyone.")
                }
            }

            if let packId = review.packId {
                Section {
                    Text(verbatim: packId)
                } header: {
                    Text("Installs")
                } footer: {
                    Text("A vault pack, downloaded from the signed catalog and checked before it is installed. Field Assist turns on once it is in.")
                }
            }

            if !review.organizationLines.isEmpty || review.carriesLicence || !review.aiModelLines.isEmpty {
                Section {
                    ForEach(review.organizationLines, id: \.self) { Text(verbatim: $0) }
                    if review.carriesLicence {
                        Text("A Field Assist licence")
                    }
                    ForEach(review.aiModelLines, id: \.self) { Text(verbatim: $0) }
                } header: {
                    Text("Supplies")
                } footer: {
                    if let model = review.result.aiModel, model.access != .onDevice {
                        Text("The AI model's key is not part of the profile. You enter it on this phone next, and it stays here.")
                    }
                }
            }

            if !review.dropLines.isEmpty {
                Section {
                    ForEach(review.dropLines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.footnote)
                    }
                } header: {
                    Text("Not applied")
                } footer: {
                    Text("This version of the app could not use these entries, so they are left out.")
                }
            }

            Section {
                Button("Apply the profile", action: apply)
            } footer: {
                Text("The device owner can remove the profile later from Settings, which lifts its locks and puts your own settings back.")
            }
        }
    }
}

/// The persistent "Managed by …" row on the Settings hub, with removal behind the device owner.
struct ManagedByOrganisationSection: View {
    @ObservedObject var manager: OrgProfileManager
    @State private var confirmingRemoval = false
    @State private var removalError: String?
    @State private var finishingModel = false
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var departures = OrgDepartureService.shared
    @EnvironmentObject private var appState: AppState
    /// Plan CT PR 4: the step before removal that offers the firm its records.
    @State private var leaving = false
    @State private var recordsShare: ShareItem?
    @State private var exportProblem: String?

    var body: some View {
        if let profile = manager.profile, let record = manager.record {
            OGSection(header: "Organisation") {
                OGRow(
                    "Managed by \(profile.organizationName)",
                    icon: "building.2",
                    subtitle: subtitle(profile: profile, record: record),
                    showsChevron: false
                ) { EmptyView() }
                if let notice = leaseNotice(profile: profile, record: record) {
                    OGDivider()
                    OGNotice(text: notice.text, systemImage: notice.icon)
                        .padding(12)
                }
                if let packId = record.pendingPackId {
                    OGDivider()
                    if let error = record.packInstallError {
                        OGNotice(text: "Couldn't install \(packId): \(error). It tries again each time the app opens.",
                                 systemImage: "exclamationmark.triangle")
                            .padding(12)
                    } else {
                        OGNotice(text: "Installing \(packId). Field Assist turns on once it is in.",
                                 systemImage: "arrow.down.circle")
                            .padding(12)
                    }
                }
                if manager.needsModelSetup, let model = manager.organizationModel {
                    OGDivider()
                    OGNotice(text: "Your administrator needs to finish setting up this phone: \(model.summary) still needs its key.",
                             systemImage: "key")
                        .padding(12)
                }
                // Under the Field Assist edition the key is the administrator's to enter (Plan CT 3b).
                if manager.needsModelSetup, let model = manager.organizationModel, !adminGate.isRestricted {
                    Button {
                        finishingModel = true
                    } label: {
                        OGRow("Finish Setup", icon: "key", showsChevron: false) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $finishingModel) {
                        NavigationStack {
                            OrgModelKeyPage(model: model, organization: profile.organizationName,
                                            submit: { finishModel(model, key: $0) },
                                            later: { finishingModel = false })
                                .navigationTitle("Organisation Profile")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
                if record.profileURL != nil, record.revoked != true, !(manager.lease?.isLiveAndQuiet ?? false) {
                    OGDivider()
                    Button {
                        Task { await manager.renewIfDue(force: true) }
                    } label: {
                        OGRow("Check for Renewal", icon: "arrow.clockwise", showsChevron: false) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
                OGDivider()
                if record.source.isLocallyRemovable, leaving {
                    leavingPanel(organization: profile.organizationName, record: record)
                } else if record.source.isLocallyRemovable {
                    Button(role: .destructive) {
                        // Plan CT PR 4: removal is leaving the firm. Offer it its records first.
                        if owedReports > 0 || !owedSessions(record).isEmpty {
                            leaving = true
                        } else {
                            confirmingRemoval = true
                        }
                    } label: {
                        OGRow("Remove Profile", icon: "xmark.circle", showsChevron: false) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                } else {
                    OGNotice(text: "Your organisation's device management applied this profile, so it can only be removed there.",
                             systemImage: "info.circle")
                        .padding(12)
                }
                if let removalError {
                    OGDivider()
                    OGStatusLabel(removalError, kind: .error)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .confirmationDialog(
                "Remove \(profile.organizationName)'s profile?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Profile", role: .destructive) { remove() }
            } message: {
                Text("Its locks lift, the settings it chose go back to yours, and a licence it brought is removed.")
            }
        } else if let problem = manager.loadProblem {
            OGSection(header: "Organisation") {
                OGNotice(text: problem, systemImage: "exclamationmark.triangle")
                    .padding(12)
            }
        } else if let departure = departures.departure, departure.isPending {
            // Plan CT PR 4: this phone has left the firm and still owes it its records.
            OGSection(header: "Organisation") {
                OGNotice(text: "This phone has left \(departure.organizationName). Its job records from that time go to \(departure.organizationName) when this phone can reach it, and are erased by \(departure.eraseBy.formatted(date: .abbreviated, time: .omitted)) either way.",
                         systemImage: "tray.and.arrow.up")
                    .padding(12)
            }
        }
    }

    /// What the lease means for the person holding the phone, or nil while it is simply in force.
    private func leaseNotice(profile: ConfigProfile, record: OrgEnrolmentRecord) -> (text: String, icon: String)? {
        let name = profile.organizationName
        let host = record.profileURL.map { OrgEnrolmentService.displayHost($0) }
        switch manager.lease {
        case .renewSoon(let renewBy)?:
            return ("Connect to the internet to renew by \(renewBy.formatted(date: .abbreviated, time: .omitted)). This phone renews on its own whenever it can reach \(host ?? "your organisation").",
                    "clock")
        case .lapsed(let since)?:
            if !manager.contentLocked {
                return ("Management expired on \(since.formatted(date: .abbreviated, time: .omitted)). \(name)'s content locks when this job closes.",
                        "exclamationmark.triangle")
            }
            let reach = host.map { " until this phone reaches \($0) again" } ?? " until your organisation re-issues its link"
            return ("Management expired on \(since.formatted(date: .abbreviated, time: .omitted)). \(name)'s settings still apply and its content is locked\(reach).",
                    "exclamationmark.triangle")
        case .clockWoundBack?:
            return ("This phone's clock is behind a time it has already seen, so \(name)'s content is locked. Set the date and time automatically, then check for renewal.",
                    "exclamationmark.triangle")
        case .revoked?:
            return ("\(name) has revoked this phone. Its settings no longer apply and its content is locked.",
                    "xmark.octagon")
        case .live?, nil:
            return nil
        }
    }

    private func subtitle(profile: ConfigProfile, record: OrgEnrolmentRecord) -> String {
        var parts = ["Since \(record.enrolledAt.formatted(date: .abbreviated, time: .omitted))"]
        if let expiry = profile.policyExpiry {
            parts.append("ends \(expiry.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("enrolment \(record.enrolmentId)")
        return parts.joined(separator: " · ")
    }

    // MARK: - Leaving the firm (Plan CT PR 4)

    private var owedReports: Int { appState.jobSends.stagedCount }

    private func owedSessions(_ record: OrgEnrolmentRecord) -> [String] {
        OrgDepartureService.managedSessionIds(FieldSessionService.shared.history, since: record.enrolledAt)
    }

    /// Before the profile goes: the reports still waiting to be sent, and the job records from the
    /// managed period, both the firm's. Offered, never forced — removing without sending leaves them
    /// to the endpoint if there is one, and to the erasure window if not.
    @ViewBuilder
    private func leavingPanel(organization: String, record: OrgEnrolmentRecord) -> some View {
        OGNotice(text: "Before you remove \(organization)'s profile, send it what is still its own. Anything you don't send goes to \(organization) automatically if it has a report endpoint, and is erased from this phone either way.",
                 systemImage: "tray.and.arrow.up")
            .padding(12)
        if owedReports > 0 {
            OGDivider()
            Button {
                _ = appState.jobSends.sendAll()
            } label: {
                OGRow("Send \(owedReports) Waiting Reports", icon: "paperplane", showsChevron: false) { EmptyView() }
            }
            .buttonStyle(.plain)
        }
        let sessions = owedSessions(record)
        if !sessions.isEmpty {
            OGDivider()
            Button {
                shareRecords(sessions)
            } label: {
                OGRow("Share Job Records for \(organization)", icon: "square.and.arrow.up", showsChevron: false) { EmptyView() }
            }
            .buttonStyle(.plain)
            .sheet(item: $recordsShare) { item in
                ShareSheet(items: item.items)
            }
        }
        if let exportProblem {
            OGDivider()
            OGStatusLabel(exportProblem, kind: .error)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        OGDivider()
        Button(role: .destructive) {
            confirmingRemoval = true
        } label: {
            OGRow("Remove Profile Now", icon: "xmark.circle", showsChevron: false) { EmptyView() }
        }
        .buttonStyle(.plain)
        OGDivider()
        Button {
            leaving = false
            exportProblem = nil
        } label: {
            OGRow("Not Now", icon: "arrow.uturn.backward", showsChevron: false) { EmptyView() }
        }
        .buttonStyle(.plain)
    }

    /// Each managed session's record, as the job export writes it, handed to the share sheet at once.
    private func shareRecords(_ sessionIds: [String]) {
        exportProblem = nil
        var files: [URL] = []
        for id in sessionIds {
            do {
                files += try FieldSessionService.shared.exportSession(id: id).map(\.fileURL)
            } catch {
                exportProblem = "Couldn't export every job record: \(error.localizedDescription)"
            }
        }
        if !files.isEmpty { recordsShare = ShareItem(items: files) }
    }

    private func finishModel(_ model: OrgAIModel, key: String) -> String? {
        if model.access == .key, let problem = model.keyProblem(key) { return problem }
        guard manager.completeModelSetup(apiKey: key) else { return "Couldn't save the key. Try again." }
        finishingModel = false
        return nil
    }

    private func remove() {
        removalError = nil
        leaving = false
        OwnerGateAuth.authenticate(reason: "Remove your organisation's profile from this phone") { granted in
            Task { @MainActor in
                guard granted else {
                    removalError = "Couldn't verify it's you — the profile stays."
                    return
                }
                if case .failure(let refusal) = manager.remove() {
                    removalError = refusal.errorDescription
                }
            }
        }
    }
}

/// A caption under a control the organisation profile has locked: the lock is never invisible.
struct ManagedSettingNote: View {
    let key: SettingKey

    var body: some View {
        if PolicyEnvelope.isLocked(key), let name = PolicyEnvelope.organizationName {
            Label {
                Text("Set by \(name)")
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private extension ProfileLease.Status {
    /// In force with no warning due — nothing for the person to do.
    var isLiveAndQuiet: Bool {
        if case .live = self { return true }
        return false
    }
}

/// The page after the review when the profile names an AI model (Plan CT 3a): the organisation's
/// provider key, typed here, or the provider's sign-in. The provider and model are the profile's; the
/// key is the only thing entered, and it goes to the Keychain with the phone's other model keys —
/// never to the profile's address.
struct OrgModelKeyPage: View {
    let model: OrgAIModel
    let organization: String
    /// Returns what is wrong with the key, or nil once it is saved.
    let submit: (String) -> String?
    let later: () -> Void

    @State private var key = ""
    @State private var problem: String?
    @ObservedObject private var google = GoogleOAuthService.shared
    @ObservedObject private var chatgpt = ChatGPTOAuthService.shared

    var body: some View {
        List {
            Section {
                Text(verbatim: model.summary)
                    .font(.headline)
                if let host = model.host {
                    Text("Prompts go to \(host)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(organization) uses")
            }

            switch (model.access, model.provider) {
            case (.signIn, .chatgpt):
                OnboardingAccountSignInSection(
                    service: ChatGPTOAuthService.shared,
                    signInLabel: "Sign in with ChatGPT",
                    caption: "Sign in with the ChatGPT account \(organization) gave you.",
                    connectedCaption: "Signed in. Conversation uses \(organization)'s ChatGPT plan.",
                    pasteInstructions: "Sign in in the browser. When it ends on a localhost page that can't connect, copy the full URL from the address bar and paste it here.",
                    onConnected: { problem = submit("") })
                if chatgpt.isConnected {
                    // Already signed in before this page opened: nothing will call onConnected.
                    Section {
                        Button("Continue") { problem = submit("") }
                    }
                }
            case (.signIn, _):
                Section {
                    GoogleSignInRows()
                    Button("Continue") { problem = submit("") }
                        .disabled(!google.isConnected)
                } header: {
                    Text("Sign in")
                }
            default:
                Section {
                    SecureField("\(model.provider.displayName) API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Save Key") { problem = submit(key) }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Enter the \(model.provider.displayName) API key from \(organization)")
                } footer: {
                    Text("The key stays on this phone, in the Keychain. It is never sent to \(organization)'s profile address.")
                }
            }

            if let problem {
                Section {
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                }
            }

            Section {
                Button("My administrator will add this", action: later)
            } footer: {
                Text("Field Assist will say the administrator needs to finish setting up this phone until the key is in.")
            }
        }
    }
}
