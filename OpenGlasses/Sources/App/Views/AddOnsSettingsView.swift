import SwiftUI
import UniformTypeIdentifiers

/// Settings → Add-ons (Plan GF P2): the add-ons switch, each installed add-on with its own switch
/// and why it is not offered when it isn't, and adding one from a file. Thin over `AddOnStore`,
/// `AddOnAvailability` and `AddOnInstallService`; every decision is in those.
struct AddOnsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: AddOnStore
    @State private var addOnsEnabled = Config.addOnsEnabled
    @State private var importing = false

    var body: some View {
        List {
            Section {
                Toggle("Add-ons", isOn: Binding(
                    get: { addOnsEnabled },
                    set: { on in
                        addOnsEnabled = on
                        Config.addOnsEnabled = on
                        appState.refreshAddOnTools()
                    }))
            } footer: {
                Text("An add-on is a small file that teaches the assistant a new skill, such as looking something up on a website you approve. Turning this off stops every add-on at once; each keeps its own switch.")
            }

            if let ceiling = ceilingNote {
                Section { Label(ceiling, systemImage: "building.2") }
            }

            Section {
                if store.installed.isEmpty {
                    Text("No add-ons installed. Open an add-on link or file to install one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.installed) { record in
                    NavigationLink {
                        AddOnDetailView(store: store, id: record.id)
                            .environmentObject(appState)
                    } label: {
                        row(record)
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Every add-on shows what it can do before it installs, and nothing updates without asking you.")
            }

            AddOnDraftsSection(drafts: appState.addOnDrafts)

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Add from a File", systemImage: "doc.badge.plus")
                }
                .disabled(!store.isWritable)
            }
        }
        .navigationTitle("Add-ons")
        .ogFormStyle()
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(exportedAs: AddOnFileType.identifier), .json]) { result in
            if case .success(let url) = result { appState.addOnInstall.openFile(url) }
        }
    }

    private var ceilingNote: String? {
        switch Config.addOnCeiling {
        case .noCeiling: return nil
        case .signedOnly: return SettingKey.organizationForbidsCommunityAddOns.ceilingDescription
        case .organisationSignedOnly: return SettingKey.organizationAllowsOnlyOrganisationAddOns.ceilingDescription
        case .addOnsDisabled: return SettingKey.organizationForbidsAddOns.ceilingDescription
        }
    }

    @ViewBuilder private func row(_ record: AddOnStore.InstalledAddOn) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.icon ?? "puzzlepiece.extension")
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                Text(statusLine(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusLine(_ record: AddOnStore.InstalledAddOn) -> String {
        switch store.loaded(id: record.id) {
        case .failure:
            return String(localized: "Can't be used")
        case .success(let loaded):
            if let hidden = AddOnAvailability.hidden(loaded.manifest, trust: loaded.trust, enabled: record.enabled,
                                                     conditions: AddOnLiveContext.conditions()) {
                return AddOnAvailability.explanation(hidden)
            }
            return record.version
        }
    }
}

/// Add-ons the assistant built and tested that are waiting for the wearer: open the sheet again,
/// or delete one. Shown only when there is one.
struct AddOnDraftsSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var drafts: AddOnDraftStore

    var body: some View {
        if !drafts.drafts.isEmpty {
            Section {
                ForEach(drafts.drafts) { draft in
                    Button {
                        appState.addOnAuthoring?.review(draftID: draft.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name)
                            Text("Built for: \(draft.goal)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            appState.addOnAuthoring?.discard(draftID: draft.id)
                        }
                    }
                }
            } header: {
                Text("Built for You")
            } footer: {
                Text("Your assistant built and tested these. Tap one to review it; nothing is installed until you approve it. Each is deleted after a day.")
            }
            .onAppear { drafts.sweepExpired(now: Date()) }
        }
    }
}

/// The add-on file type (`.addon`), declared in Info.plist.
enum AddOnFileType {
    static let identifier = "com.openglasses.app.addon"
}

/// One installed add-on: its switch, what it can do, where it came from, its source, export and
/// removal.
struct AddOnDetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: AddOnStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemove = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            if let record = store.record(id: id) {
                content(record)
            }
        }
        .navigationTitle(store.record(id: id)?.name ?? String(localized: "Add-on"))
        .ogFormStyle()
        .confirmationDialog("Remove this add-on?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.remove(id: id)
                appState.refreshAddOnTools()
                dismiss()
            }
        } message: {
            Text("Its skills go at once. Anything it saved to your memory stays there.")
        }
    }

    @ViewBuilder private func content(_ record: AddOnStore.InstalledAddOn) -> some View {
        let loaded = store.loaded(id: id)
        Section {
            Toggle("On", isOn: Binding(
                get: { record.enabled },
                set: { on in
                    store.setEnabled(on, id: id)
                    appState.refreshAddOnTools()
                }))
            .disabled(!store.isWritable)
            if case .success(let addOn) = loaded,
               let hidden = AddOnAvailability.hidden(addOn.manifest, trust: addOn.trust, enabled: record.enabled,
                                                     conditions: AddOnLiveContext.conditions()),
               hidden != .turnedOff {
                Label(AddOnAvailability.explanation(hidden), systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(record.summary)
        }

        Section {
            LabeledContent("Version", value: record.version)
            ForEach(badges(record, loaded: loaded), id: \.self) { badge in
                Label(badge, systemImage: "checkmark.seal")
            }
            if let provenance = record.selfBuiltProvenance {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Built for: \(provenance.goal)")
                    Text(provenance.builtAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        switch loaded {
        case .failure(let damage):
            Section {
                Label(damageText(damage), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(OGTheme.warnLabel)
            } header: {
                Text("Can't be used")
            }
        case .success(let addOn):
            Section("Skills") {
                ForEach(addOn.manifest.skills, id: \.name) { skill in
                    Text(skill.description)
                }
            }
            Section("What it can do") {
                ForEach(AddOnPermissionSummary.lines(for: addOn.manifest.permissions), id: \.kind) { line in
                    Text(line.text)
                }
            }
        }

        Section {
            NavigationLink("Source") {
                AddOnSourceView(store: store, id: id)
                    .environmentObject(appState)
            }
            if let exportURL {
                ShareLink(item: exportURL) { Label("Share Add-on File", systemImage: "square.and.arrow.up") }
            } else {
                Button {
                    exportURL = writeExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            Button("Remove", role: .destructive) { confirmingRemove = true }
                .disabled(!store.isWritable)
        } footer: {
            if record.isBuiltByAssistant {
                Text("Exported as a plain add-on file. Whoever opens it is told an assistant built it.")
            }
        }
    }

    private func badges(_ record: AddOnStore.InstalledAddOn,
                        loaded: Result<AddOnStore.Loaded, AddOnStore.Damage>) -> [String] {
        var out: [String] = []
        if case .success(let addOn) = loaded {
            switch addOn.trust {
            case .vendorSigned: out.append(AddOnSheetModel.Badge.reviewed.text)
            case .organisationSigned: out.append(AddOnSheetModel.Badge.organisation.text)
            case .community: break
            }
        }
        if record.isBuiltByAssistant { out.append(AddOnSheetModel.Badge.builtByAssistant.text) }
        if record.editedOnPhone { out.append(AddOnSheetModel.Badge.editedOnPhone.text) }
        return out
    }

    private func damageText(_ damage: AddOnStore.Damage) -> String {
        switch damage {
        case .fileMissing: return String(localized: "Its file is missing. Remove it and install it again.")
        case .noLongerValid: return String(localized: "This version of the app no longer accepts it, or its signature no longer checks out. It won't run until it is fixed or updated.")
        }
    }

    /// A share copy in the temporary folder, named `<id>.addon`. The file is the add-on itself (or
    /// its signed envelope); the format has nowhere to hold a key or a token.
    private func writeExport() -> URL? {
        guard let data = store.exportData(id: id) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id).\(AddOnIngest.fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// The source, readable always; editable unless the organisation signed it. An edit is validated
/// as you type and saved as a community add-on: any signature goes. If the edit lets it do more
/// than before, the sheet is shown again first.
struct AddOnSourceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: AddOnStore
    let id: String
    @State private var text = ""
    @State private var editing = false
    @State private var loadedText = false

    var body: some View {
        Group {
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    statusView
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle("Source")
        .toolbar {
            if isEditable {
                if editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.disabled(!canSave)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            text = store.sourceText(id: id) ?? ""
                            editing = false
                        }
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editing = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !isEditable, case .organisationSigned = store.trust(id: id) {
                Text("Your organisation manages this add-on, so it can't be edited here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .onAppear {
            guard !loadedText else { return }
            text = store.sourceText(id: id) ?? ""
            loadedText = true
        }
    }

    private var isEditable: Bool {
        if case .organisationSigned = store.trust(id: id) { return false }
        return store.isWritable
    }

    private var review: AddOnSourceEdit.Outcome? {
        guard let bytes = store.fileBytes(id: id), case .success(let addOn) = store.loaded(id: id) else { return nil }
        return AddOnSourceEdit.review(text, installedBytes: bytes, installed: addOn.manifest,
                                      context: appState.addOnAdmissionContext())
    }

    private var canSave: Bool {
        if case .saveable = review { return true }
        return false
    }

    @ViewBuilder private var statusView: some View {
        switch review {
        case .none, .unchanged:
            Text("Signed add-ons lose their signature when edited.")
                .font(.caption).foregroundStyle(.secondary)
        case .invalid(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(OGTheme.warnLabel)
                }
            }
        case .saveable(_, _, let needsApproval):
            (needsApproval ? Text("Valid. It can now do more, so you'll be asked to approve it.") : Text("Valid."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard case .saveable(let candidate, let diff, let needsApproval) = review else { return }
        if needsApproval {
            appState.addOnInstall.reviewEdit(candidate, diff: diff)
        } else if case .success = store.saveEdit(candidate) {
            appState.refreshAddOnTools()
        }
        editing = false
    }
}

/// The add-on sheets and messages, attached at the app's root: invisible until a link, a file or
/// an edit raises one.
struct AddOnInstallOverlay: View {
    @ObservedObject var service: AddOnInstallService

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: reviewBinding) { review in
                NavigationStack {
                    AddOnReviewSheet(model: AddOnSheetModel(review: review),
                                     accept: { service.accept(review) },
                                     cancel: { service.dismiss() })
                }
            }
            .alert(item: alertBinding) { prompt in
                switch prompt {
                case .confirmFetch(let offer):
                    return Alert(
                        title: Text("Get an add-on?"),
                        message: Text("This link offers an add-on from \(offer.host). The file is downloaded and checked, then you see what it can do before anything installs."),
                        primaryButton: .default(Text("Get It")) {
                            Task { @MainActor in await service.approveFetch(offer) }
                        },
                        secondaryButton: .cancel { service.dismiss() })
                case .fetching(let host):
                    return Alert(title: Text("Getting the add-on…"), message: Text(host),
                                 dismissButton: .cancel { service.dismiss() })
                case .refused(let lines):
                    return Alert(title: Text("Add-on"), message: Text(lines.prefix(6).joined(separator: "\n")),
                                 dismissButton: .default(Text("OK")) { service.dismiss() })
                case .done(let message):
                    return Alert(title: Text("Add-on"), message: Text(message),
                                 dismissButton: .default(Text("OK")) { service.dismiss() })
                case .review:
                    return Alert(title: Text("Add-on"))
                }
            }
    }

    private var reviewBinding: Binding<AddOnInstallService.Review?> {
        Binding(
            get: { if case .review(let review) = service.prompt { return review } else { return nil } },
            set: { newValue in
                if newValue == nil, case .review = service.prompt { service.dismiss() }
            })
    }

    private var alertBinding: Binding<AddOnInstallService.Prompt?> {
        Binding(
            get: {
                if case .review = service.prompt { return nil }
                return service.prompt
            },
            set: { newValue in
                if newValue == nil, let current = service.prompt {
                    if case .review = current { return }
                    if case .fetching = current { return }
                    service.dismiss()
                }
            })
    }
}

/// The install, update and edit sheet itself.
struct AddOnReviewSheet: View {
    let model: AddOnSheetModel
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.icon ?? "puzzlepiece.extension")
                        .font(.title2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(.headline)
                        Text(model.byline).font(.caption).foregroundStyle(.secondary)
                        Text(model.version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(model.summary)
                ForEach(model.badges, id: \.text) { badge in
                    Label(badge.text, systemImage: "checkmark.seal")
                }
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OGTheme.warnLabel)
                }
            }
            if !model.changes.isEmpty {
                Section("What changes") {
                    ForEach(model.changes) { row(for: $0) }
                }
            }
            Section("Skills") {
                ForEach(model.skills) { row(for: $0) }
            }
            Section("What it can do") {
                ForEach(model.permissions) { row(for: $0) }
            }
            if let tested = model.tested {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Asked", value: tested.question)
                        LabeledContent("It answered", value: tested.answer)
                        LabeledContent("Contacted", value: tested.domains)
                        LabeledContent("Took", value: tested.time)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tested.accessibilityText)
                    NavigationLink("View Source") {
                        ScrollView {
                            Text(tested.source)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle("Source")
                    }
                } header: {
                    Text("Tested")
                } footer: {
                    if let note = model.cancelNote { Text(note) }
                }
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            ToolbarItem(placement: .confirmationAction) { Button(model.confirmTitle, action: accept) }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder private func row(for row: AddOnSheetModel.Row) -> some View {
        switch row.emphasis {
        case .normal:
            Text(row.text)
        case .added:
            Label(row.text, systemImage: "plus.circle.fill")
                .foregroundStyle(OGTheme.warnLabel)
                .fontWeight(.semibold)
        case .removed:
            Label(row.text, systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}
