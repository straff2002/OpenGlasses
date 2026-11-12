import SwiftUI

/// Mounts the enrolment review over the root view (Plan CT PR 2). Its own `@ObservedObject`, so a
/// stage change repaints even though the service hangs off `AppState`.
struct OrgEnrolmentOverlay: View {
    @ObservedObject var service: OrgEnrolmentService
    /// A move's review offers the organisation being left its waiting reports and job records.
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { service.stage != .idle },
                set: { if !$0 { service.dismiss() } })) {
                OrgEnrolmentSheet(service: service)
                    .environmentObject(appState)
            }
    }
}

/// The review an organisation profile gets before anything on the phone changes: the host, then
/// who it is from, what it locks, what it sets, and what this version of the app could not use.
struct OrgEnrolmentSheet: View {
    @ObservedObject var service: OrgEnrolmentService
    /// Why a move did not go ahead (the device owner's check was not passed).
    @State private var moveProblem: String?

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

    /// Applying a move removes the current organisation's profile, so it asks for the device
    /// owner first, exactly as Remove Profile does; that one check is the move's only confirmation.
    private func apply(_ review: OrgProfileReview) {
        guard let move = review.move else {
            service.confirm()
            return
        }
        moveProblem = nil
        let from = move.organizationName
        let to = review.organizationName
        OwnerGateAuth.authenticate(reason: String(localized: "Move this phone from \(from) to \(to)")) { granted in
            Task { @MainActor in
                guard granted else {
                    moveProblem = String(localized: "Couldn't verify it's you — this phone stays with \(from).")
                    return
                }
                service.confirm()
            }
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
            OrgProfileReviewList(review: review, problem: moveProblem) { apply(review) }

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
                    Text("This phone is now managed by this organisation. Settings it locks aren't shown; Settings › Organisation lists what it sets, and that is also where the profile can be removed.")
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
struct OrgProfileReviewList: View {
    let review: OrgProfileReview
    /// Shown above the apply button, when applying did not go ahead.
    var problem: String? = nil
    let apply: () -> Void

    var body: some View {
        List {
            if let move = review.move {
                moveSections(move)
            }

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

            if let problem {
                Section {
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                }
            }

            Section {
                if review.move != nil {
                    Button("Move to \(review.organizationName)", role: .destructive, action: apply)
                } else {
                    Button("Apply the profile", action: apply)
                }
            } footer: {
                if let move = review.move {
                    Text("You'll confirm it's you, then \(move.organizationName)'s profile is removed and \(review.organizationName)'s is applied. The device owner can remove it later from Settings.")
                } else {
                    Text("The device owner can remove the profile later from Settings, which lifts its locks and puts your own settings back.")
                }
            }
        }
    }

    /// A move (another organisation's profile is in force): what leaving it does — Remove Profile's
    /// own consequences and the departure's — and its records, offered before anything is removed.
    @ViewBuilder
    private func moveSections(_ move: OrgProfileReview.Move) -> some View {
        let from = move.organizationName
        let to = review.organizationName
        Section {
            Text("Move this phone from \(from) to \(to)")
                .font(.headline)
        } footer: {
            Text("This phone is with \(from) now. Applying \(to)'s profile leaves \(from) first.")
        }
        Section {
            Label("\(from)'s profile is removed: its locks lift, the settings it chose go back to yours, and a licence it brought is removed.",
                  systemImage: "xmark.circle")
            if move.keepsPack {
                Label("\(from)'s content is erased from this phone, apart from the vault pack \(to) installs as well.",
                      systemImage: "trash")
            } else {
                Label("\(from)'s content is erased from this phone: its manuals, upcoming jobs and staged exports.",
                      systemImage: "trash")
            }
            Label("Job records and waiting reports from your time with \(from) go to it automatically if it has a report endpoint, and are erased from this phone either way.",
                  systemImage: "tray.and.arrow.up")
            OrgOwedRecordsRows(organization: from, enrolledAt: move.enrolledAt, style: .list)
        } header: {
            Text("Leaving \(from)")
        } footer: {
            Text(verbatim: OrgDepartureService.erasureLimits)
        }
    }
}

/// What a phone leaving an organisation still holds that is the organisation's (Plan CT PR 4): the
/// reports waiting to be sent and the job records of the managed period, each with the action
/// that sends it. Offered, never forced. The organisation's page shows these under Leave before
/// Remove Profile, and a move's review shows them before the move is applied; nothing is drawn when
/// nothing is owed.
struct OrgOwedRecordsRows: View {
    enum Style { case page, list }

    let organization: String
    let enrolledAt: Date
    let style: Style

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var fieldSessions = FieldSessionService.shared
    @State private var recordsShare: ShareItem?
    @State private var exportProblem: String?

    /// The job records from the managed period, as the departure will count them.
    static func owedSessions(since enrolledAt: Date) -> [String] {
        OrgDepartureService.managedSessionIds(FieldSessionService.shared.history, since: enrolledAt)
    }

    var body: some View {
        let reports = appState.jobSends.stagedCount
        let sessions = Self.owedSessions(since: enrolledAt)
        if reports > 0 {
            row("Send \(reports) Waiting Reports", icon: "paperplane") { _ = appState.jobSends.sendAll() }
        }
        if !sessions.isEmpty {
            row("Share Job Records for \(organization)", icon: "square.and.arrow.up") { shareRecords(sessions) }
                .sheet(item: $recordsShare) { item in
                    ShareSheet(items: item.items)
                }
        }
        if let exportProblem {
            switch style {
            case .page:
                OGDivider()
                OGStatusLabel(exportProblem, kind: .error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            case .list:
                Label { Text(verbatim: exportProblem) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(OGTheme.errorLabel)
            }
        }
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        switch style {
        case .page:
            OGDivider()
            Button(action: action) {
                OGRow(title, icon: icon, showsChevron: false) { EmptyView() }
            }
            .buttonStyle(.plain)
        case .list:
            Button(action: action) {
                Label(title, systemImage: icon)
            }
        }
    }

    /// Each managed session's record, as the job export writes it, handed to the share sheet at once.
    private func shareRecords(_ sessionIds: [String]) {
        exportProblem = nil
        var files: [URL] = []
        for id in sessionIds {
            do {
                files += try FieldSessionService.shared.exportSession(id: id).map(\.fileURL)
            } catch {
                exportProblem = String(localized: "Couldn't export every job record: \(error.localizedDescription)")
            }
        }
        if !files.isEmpty { recordsShare = ShareItem(items: files) }
    }
}

/// The persistent "Managed by …" section on the Settings hub (Plan CT PR 2). The row opens the
/// organisation's page, where what it sets is listed and — at the bottom, out of the way — the
/// profile can be removed (Plan HA C4).
struct ManagedByOrganisationSection: View {
    @ObservedObject var manager: OrgProfileManager
    @State private var finishingModel = false
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var departures = OrgDepartureService.shared
    @ObservedObject private var fieldSessions = FieldSessionService.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let profile = manager.profile, let record = manager.record {
            OGSection(header: "Organisation") {
                NavigationLink {
                    OrganisationProfilePage(manager: manager)
                } label: {
                    ManagedByOrganisationRow(organization: profile.organizationName,
                                             subtitle: Self.subtitle(profile: profile, record: record),
                                             showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows what \(profile.organizationName) sets on this phone."))
                // Plan HA C4: what the organisation locked is not drawn for the technician, and this
                // one line says so; the page above lists it.
                if SettingsVisibilityPolicy.hidesSettings(in: adminGate.settingsContext) {
                    OGDivider()
                    OGNotice(text: "Some settings are set by \(profile.organizationName) and aren't shown.",
                             systemImage: "eye.slash")
                        .padding(12)
                }
                if let notice = leaseNotice(profile: profile, record: record) {
                    OGDivider()
                    OGNotice(text: notice.text, systemImage: notice.icon)
                        .padding(12)
                }
                // The organisation's signed term has ended: say so, and where to remove the profile.
                // A notice only — nothing is removed (`OrgProfileEndPolicy`).
                if let ended = OrgProfileEndPolicy.decide(.current(profile: profile, record: record,
                                                                   appState: appState)).notice {
                    OGDivider()
                    NavigationLink {
                        OrganisationProfilePage(manager: manager)
                    } label: {
                        OGNotice(text: ended.settingsText, systemImage: ended.systemImage)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(ended.settingsHint))
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
                } else if let error = record.packInstallError, let packId = profile.vaultPack?.packId {
                    // Plan LR: an update to a pack already installed failed; the installed one stays.
                    OGDivider()
                    OGNotice(text: "Couldn't update \(packId): \(error). It tries again at the next check.",
                             systemImage: "exclamationmark.triangle")
                        .padding(12)
                }
                // Plan LR: the company's own vaults, and Check for Updates.
                if profile.companyVaults != nil, record.revoked != true {
                    CompanyVaultRowsView(manager: manager, organization: profile.organizationName)
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
                OGDivider()
                OGNotice(text: OrgDepartureService.erasureLimits, systemImage: "info.circle")
                    .padding(12)
            }
        }
    }

    /// What the lease means for the person holding the phone, or nil while it is simply in force.
    private func leaseNotice(profile: ConfigProfile, record: OrgEnrolmentRecord) -> (text: String, icon: String)? {
        let name = profile.organizationName
        let host = record.profileURL.map { OrgEnrolmentService.displayHost($0) }
        let hostOrOrganisation = host ?? String(localized: "your organisation")
        switch manager.lease {
        case .renewSoon(let renewBy)?:
            let renewDate = renewBy.formatted(date: .abbreviated, time: .omitted)
            return (String(localized: "Connect to the internet to renew by \(renewDate). This phone renews on its own whenever it can reach \(hostOrOrganisation)."),
                    "clock")
        case .lapsed(let since)?:
            let sinceDate = since.formatted(date: .abbreviated, time: .omitted)
            if !manager.contentLocked {
                return (String(localized: "Management expired on \(sinceDate). \(name)'s content locks when this job closes."),
                        "exclamationmark.triangle")
            }
            let reach = host.map { String(localized: " until this phone reaches \($0) again") }
                ?? String(localized: " until your organisation re-issues its link")
            if record.lapseErasedAt != nil {
                // Plan CT PR 4: the organisation's opt-in erasure after a lapse has run.
                let limits = OrgDepartureService.erasureLimits
                return (String(localized: "Management expired on \(sinceDate), and as \(name) asked, its content has been erased from this phone. Its vault pack is reinstalled when this phone reaches \(hostOrOrganisation) again. \(limits)"),
                        "exclamationmark.triangle")
            }
            if let days = profile.eraseAfterLapseDays, ConfigProfile.erasureDaysRange.contains(days) {
                let eraseOn = since.addingTimeInterval(TimeInterval(days) * 86_400)
                let eraseDate = eraseOn.formatted(date: .abbreviated, time: .omitted)
                return (String(localized: "Management expired on \(sinceDate). \(name)'s content is locked\(reach), and \(name) has asked for it to be erased on \(eraseDate) if it has not been renewed by then."),
                        "exclamationmark.triangle")
            }
            return (String(localized: "Management expired on \(sinceDate). \(name)'s settings still apply and its content is locked\(reach)."),
                    "exclamationmark.triangle")
        case .clockWoundBack?:
            return (String(localized: "This phone's clock is behind a time it has already seen, so \(name)'s content is locked. Set the date and time automatically, then check for renewal."),
                    "exclamationmark.triangle")
        case .revoked?:
            return (String(localized: "\(name) has revoked this phone. Its settings no longer apply and its content is locked."),
                    "xmark.octagon")
        case .live?, nil:
            return nil
        }
    }


    static func subtitle(profile: ConfigProfile, record: OrgEnrolmentRecord) -> String {
        let since = record.enrolledAt.formatted(date: .abbreviated, time: .omitted)
        var parts = [String(localized: "Since \(since)")]
        if let expiry = profile.policyExpiry {
            let ends = expiry.formatted(date: .abbreviated, time: .omitted)
            parts.append(String(localized: "ends \(ends)"))
        }
        let enrolmentId = record.enrolmentId
        parts.append(String(localized: "enrolment \(enrolmentId)"))
        return parts.joined(separator: " · ")
    }

    private func finishModel(_ model: OrgAIModel, key: String) -> String? {
        if model.access == .key, let problem = model.keyProblem(key) { return problem }
        guard manager.completeModelSetup(apiKey: key) else { return String(localized: "Couldn't save the key. Try again.") }
        finishingModel = false
        return nil
    }

}

/// The organisation's page (Plan HA C4): everything its profile does to this phone, in the words
/// the enrolment review used — so a setting hidden from the technician is never a secret — and, at
/// the bottom, leaving: the records panel, the confirmation and the device owner's gate, unchanged
/// from Plan CT PR 4.
struct OrganisationProfilePage: View {
    @ObservedObject var manager: OrgProfileManager
    @State private var confirmingRemoval = false
    @State private var removalError: String?
    @ObservedObject private var adminGate = AdminGate.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Plan CT PR 4: the step before removal that offers the firm its records.
    @State private var leaving = false
    /// Re-draws the ended notice when a job opens or closes.
    @ObservedObject private var fieldSessions = FieldSessionService.shared
    /// Where the ended notice scrolls to.
    private static let leaveSection = "leave"

    var body: some View {
        ScrollViewReader { proxy in
            OGScrollPage {
                if let profile = manager.profile, let record = manager.record {
                    content(profile: profile, record: record, proxy: proxy)
                }
            }
        }
        .navigationTitle(manager.profile?.organizationName ?? String(localized: "Organisation"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: manager.record == nil) { _, removed in
            if removed { dismiss() }
        }
    }

    @ViewBuilder
    private func content(profile: ConfigProfile, record: OrgEnrolmentRecord, proxy: ScrollViewProxy) -> some View {
        let organization = profile.organizationName
        // What is in force now, not what the review once said: a renewal may have changed it, and a
        // revocation lifts it.
        let review = OrgProfileReview(document: record.document, source: record.source, profile: profile,
                                      result: PolicyEnvelope.current, replacesCurrent: false,
                                      licenceToActivate: record.activatedLicenceCode)
        let hidden = SettingsVisibilityPolicy.hiddenSummary(in: adminGate.settingsContext)

        OGSection {
            ManagedByOrganisationRow(organization: organization,
                                     subtitle: ManagedByOrganisationSection.subtitle(profile: profile, record: record))
        }

        // The organisation's signed term has ended: a notice only (`OrgProfileEndPolicy`). It takes
        // the person to "Leave ⟨org⟩" below; nothing is removed until they choose to there.
        if let ended = OrgProfileEndPolicy.decide(.current(profile: profile, record: record,
                                                           appState: appState)).notice {
            Button {
                withAnimation { proxy.scrollTo(Self.leaveSection, anchor: .top) }
            } label: {
                OGNotice(text: ended.pageText, systemImage: ended.systemImage)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(ended.pageHint))
        }

        if !hidden.isEmpty {
            OGSection(header: "Not shown on this phone",
                      footer: "\(organization) sets these, so they are left out of Settings. An administrator can open them from Administrator Settings.") {
                lines(hidden)
            }
        }
        if !review.lockLines.isEmpty {
            OGSection(header: "Locks", footer: "Nobody on this phone can change these while the profile is in force.") {
                lines(review.lockLines)
            }
        }
        if !review.startingValueLines.isEmpty {
            OGSection(header: "Set as a starting point", footer: "These can be changed on this phone.") {
                lines(review.startingValueLines)
            }
        }
        if !review.adminLines.isEmpty {
            OGSection(header: "What this phone shows") {
                lines(review.adminLines)
            }
        }
        if let packId = review.packId {
            OGSection(header: "Installs") {
                lines([packId])
            }
        }
        let supplies = review.organizationLines + (review.carriesLicence ? ["A Field Assist licence"] : [])
            + review.aiModelLines
        if !supplies.isEmpty {
            OGSection(header: "Supplies") {
                lines(supplies)
            }
        }
        if !review.dropLines.isEmpty {
            OGSection(header: "Not applied", footer: "This version of the app could not use these entries, so they are left out.") {
                lines(review.dropLines)
            }
        }

        // Leaving the organisation: last on the page, never on the hub (Plan HA C4).
        OGSection(header: "Leave \(organization)") {
            if record.source.isLocallyRemovable, leaving {
                leavingPanel(organization: organization, record: record)
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
            "Remove \(organization)'s profile?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Profile", role: .destructive) { remove() }
        } message: {
            Text("Its locks lift, the settings it chose go back to yours, and a licence it brought is removed.")
        }
        .id(Self.leaveSection)
    }

    /// One plain line per entry, as the enrolment review listed them.
    @ViewBuilder
    private func lines(_ entries: [String]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { index, line in
            if index > 0 { OGDivider() }
            Text(verbatim: line)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: - Leaving the firm (Plan CT PR 4)

    private var owedReports: Int { appState.jobSends.stagedCount }

    private func owedSessions(_ record: OrgEnrolmentRecord) -> [String] {
        OrgOwedRecordsRows.owedSessions(since: record.enrolledAt)
    }

    /// Before the profile goes: the reports still waiting to be sent, and the job records from the
    /// managed period, both the firm's. Offered, never forced — removing without sending leaves them
    /// to the endpoint if there is one, and to the erasure window if not.
    @ViewBuilder
    private func leavingPanel(organization: String, record: OrgEnrolmentRecord) -> some View {
        OGNotice(text: "Before you remove \(organization)'s profile, send it what is still its own. Anything you don't send goes to \(organization) automatically if it has a report endpoint, and is erased from this phone either way.",
                 systemImage: "tray.and.arrow.up")
            .padding(12)
        OrgOwedRecordsRows(organization: organization, enrolledAt: record.enrolledAt, style: .page)
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
        } label: {
            OGRow("Not Now", icon: "arrow.uturn.backward", showsChevron: false) { EmptyView() }
        }
        .buttonStyle(.plain)
    }

    private func remove() {
        removalError = nil
        leaving = false
        OwnerGateAuth.authenticate(reason: String(localized: "Remove your organisation's profile from this phone")) { granted in
            Task { @MainActor in
                guard granted else {
                    removalError = String(localized: "Couldn't verify it's you — the profile stays.")
                    return
                }
                if case .failure(let refusal) = manager.remove() {
                    removalError = refusal.errorDescription
                }
            }
        }
    }
}

/// A caption under a control the organisation profile has locked, where it is still drawn — for an
/// administrator, or for a protection in `SettingsVisibilityPolicy.alwaysShown` (Plan HA C4).
struct ManagedSettingNote: View {
    let key: SettingKey

    var body: some View {
        if PolicyEnvelope.isLocked(key), let name = PolicyEnvelope.organizationName {
            ManagedLockNote(organization: name)
        }
    }
}

extension OrgProfileEndPolicy.Input {
    /// What this phone holds now. Reports and job records are counted as the leaving screen counts
    /// them (`OrganisationProfilePage.owedReports` / `owedSessions`), and the open job is the one the
    /// lease's mid-job grace waits on.
    @MainActor
    static func current(profile: ConfigProfile, record: OrgEnrolmentRecord, appState: AppState,
                        now: Date = Date()) -> Self {
        let sessions = FieldSessionService.shared
        return Self(organizationName: profile.organizationName,
                    policyExpiry: profile.policyExpiry,
                    now: now,
                    clockHighWater: record.clockHighWater,
                    jobOpen: sessions.activeSession != nil,
                    owedReports: appState.jobSends.stagedCount,
                    owedSessions: OrgDepartureService.managedSessionIds(sessions.history,
                                                                        since: record.enrolledAt).count,
                    source: record.source)
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
