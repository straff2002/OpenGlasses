import SwiftUI

/// The live-hints sheet (Plan MO P2), opened from the Home card: the session's setup while none
/// runs, the session screen once one does, and the one-time first-run sheet in between when it is
/// owed.
struct LiveHintsSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var service: LiveHintsService
    @ObservedObject var demo: LiveHintsService

    var body: some View {
        Group {
            if service.firstRunPending {
                LiveHintsFirstRunSheet(service: service)
            } else if service.isRunning {
                LiveHintsSessionScreen(service: service, list: appState.liveHintsList, isDemo: false)
            } else if demo.isRunning {
                LiveHintsSessionScreen(service: demo, list: appState.liveHintsDemoList, isDemo: true)
            } else {
                LiveHintsSetupView(service: service)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.isRunning)
        .animation(.easeInOut(duration: 0.2), value: demo.isRunning)
    }
}

// MARK: - Setup

/// The session sheet's controls (§1–§9): mode, keywords, documents, hint language, delivery, mic and
/// the talk note, with their defaults from `LiveHintsSessionChoices.defaults`. The glasses-only
/// controls (the lens, the glasses' mic) show only when the glasses are there.
struct LiveHintsSetupView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var service: LiveHintsService
    @Environment(\.dismiss) private var dismiss

    @State private var choices = LiveHintsSessionChoices()
    @State private var loaded = false
    @State private var newKeyword = ""
    @State private var startProblem: String?
    /// The feature's own switch (`AIFeature.liveHints`). Shown here only while it is off: the
    /// first-run sheet can turn it off, and this is where it comes back on.
    @AppStorage("liveHintsEnabled") private var featureOn = true

    private var displayConnected: Bool { appState.liveHintsDisplayConnected }
    private var glassesConnected: Bool { appState.isConnected }
    private var medicalCompliance: Bool { Config.hipaaMode }

    var body: some View {
        NavigationStack {
            Form {
                if !featureOn {
                    Section {
                        Toggle("Live hints", isOn: $featureOn)
                    } footer: {
                        Text("Live hints is switched off. Turn it on to start a session.")
                    }
                }
                Section {
                    OGNotice(text: "Put your phone on the table, not in a pocket, so it hears the other person.",
                             systemImage: "iphone")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                modeSection
                keywordsSection
                documentsSection
                languageSection
                deliverySection
                if glassesConnected { micSection }
                talkNoteSection

                Section {
                    Button {
                        start()
                    } label: {
                        Text("Start live hints").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ogProminent)
                    .disabled(choices.startBlocker != nil || !featureOn)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    if let startProblem {
                        Text(startProblem)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    Button("Try a demo") { startDemo() }
                        .buttonStyle(.ogQuiet)
                        .listRowBackground(Color.clear)
                        .accessibilityHint(Text("Plays a sample conversation inside the app. Nothing listens."))
                } footer: {
                    Text("The demo plays a sample conversation inside the app and answers from a sample document. Nothing listens.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Live hints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            choices = appState.liveHintsDefaultChoices()
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            ForEach(HintMode.allCases, id: \.self) { mode in
                OGSelectionRow(title: Self.modeTitle(mode), subtitle: Self.modeSubtitle(mode),
                               isSelected: choices.mode == mode) { choices.mode = mode }
            }
        } header: {
            Text("Mode")
        } footer: {
            switch HintVoiceNote.for(diarizationOn: appState.liveHintsTellsVoicesApart) {
            case .cantTellVoicesApart:
                Text("Can't tell voices apart; hints for every question.")
            case .tellsVoicesApart:
                Text("Once the session starts, tap your own voice and then That's me, so your own questions aren't hinted.")
            }
        }
    }

    static func modeTitle(_ mode: HintMode) -> String {
        switch mode {
        case .conversation: return String(localized: "Conversation", comment: "Live hints mode: hints for questions asked of the wearer.")
        case .lecture: return String(localized: "Lecture", comment: "Live hints mode: key points from a talk.")
        case .keyword: return String(localized: "On keyword", comment: "Live hints mode: a fact card when a keyword is said.")
        }
    }

    static func modeSubtitle(_ mode: HintMode) -> String {
        switch mode {
        case .conversation:
            return String(localized: "A hint when someone asks you a question.")
        case .lecture:
            return String(localized: "A key point about once a minute, and a hint when the speaker asks a question.")
        case .keyword:
            return String(localized: "When someone says one of your keywords, the passage it's in. Nothing goes to an AI model.")
        }
    }

    // MARK: Keywords

    private var keywordsSection: some View {
        Section {
            ForEach(choices.keywords, id: \.self) { keyword in
                Text(keyword)
            }
            .onDelete { offsets in choices.keywords.remove(atOffsets: offsets) }
            HStack {
                TextField("Add a keyword or name", text: $newKeyword)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    .frame(minWidth: OGMetrics.minTouchTarget, minHeight: OGMetrics.minTouchTarget)
            }
        } header: {
            Text("Keywords")
        } footer: {
            if choices.startBlocker == .noKeywords {
                Text("On keyword needs at least one keyword.")
            } else {
                Text("Keywords also help the captions catch names and terms.")
            }
        }
    }

    private func addKeyword() {
        choices.addKeyword(newKeyword)
        newKeyword = ""
    }

    // MARK: Documents

    private var documentsSection: some View {
        let summary = HintDocumentsSummary.of(choices, openJob: appState.liveHintsJobManuals)
        return Section {
            NavigationLink {
                LiveHintsDocumentPicker(chosen: $choices.documentIds, source: $choices.documentSource,
                                        openJob: appState.liveHintsJobManuals)
            } label: {
                LabeledContent("Documents", value: Self.documentsSummary(summary))
            }
        } footer: {
            if case .jobManuals = summary {
                Text("Hints come from the job's manuals, searched on this phone, as Field Assist searches them.")
            } else {
                Text("Hints come from these documents, searched on this phone.")
            }
        }
    }

    static func documentsSummary(_ summary: HintDocumentsSummary) -> String {
        switch summary {
        case .jobManuals(let vaultName):
            return vaultName.isEmpty ? LiveHintsCopy.jobManuals : vaultName
        case .picked(let count):
            return String(AttributedString(localized: "^[\(count) document](inflect: true)",
                                           comment: "Live hints sheet: how many documents were picked.").characters)
        case .activeProject:
            return ProjectContextService.shared.activeProjectName?()
                ?? String(localized: "Active project", comment: "Live hints sheet: the documents default.")
        }
    }

    // MARK: Hint language

    private var languageSection: some View {
        Section {
            Picker("Hint language", selection: $choices.hintLanguageCode) {
                Text("Same as the conversation").tag(String?.none)
                ForEach(HintLanguageOptions.codes, id: \.self) { code in
                    Text(verbatim: HintLanguageOptions.name(code)).tag(String?.some(code))
                }
            }
        } footer: {
            Text("For a conversation in a language you speak less well.")
        }
    }

    // MARK: Delivery

    @ViewBuilder
    private var deliverySection: some View {
        if displayConnected {
            Section {
                OGSelectionRow(title: String(localized: "On the lens"), isSelected: choices.delivery == .lens) {
                    choices.delivery = .lens
                }
                OGSelectionRow(title: String(localized: "In your ear"), isSelected: choices.delivery == .ear) {
                    choices.delivery = .ear
                }
            } header: {
                Text("Hints")
            } footer: {
                Text("Hints are never spoken through the phone's speaker.")
            }
        } else {
            Section {
                LabeledContent("Hints", value: String(localized: "In your ear"))
            } footer: {
                Text("With no headphones or glasses connected, hints show on this screen only.")
            }
        }
    }

    // MARK: Mic

    private var micSection: some View {
        Section {
            OGSelectionRow(title: String(localized: "Phone"),
                           subtitle: String(localized: "Recommended: it hears the other person."),
                           isSelected: choices.mic == .phone) { choices.mic = .phone }
            OGSelectionRow(title: String(localized: "Glasses"),
                           subtitle: String(localized: "Hears the other person poorly, and the glasses' sound drops to call quality. On glasses with a display it covers the lens."),
                           isSelected: choices.mic == .glasses) { choices.mic = .glasses }
        } header: {
            Text("Microphone")
        }
    }

    // MARK: Talk note

    private var talkNoteSection: some View {
        Section {
            Toggle("Save a note of the talk", isOn: $choices.talkNote)
                .disabled(medicalCompliance)
        } footer: {
            if medicalCompliance {
                Text("Not available in Medical Compliance mode.")
            } else {
                Text("When you stop, a short note of what was said is saved with your conversations. Hints are never saved.")
            }
        }
    }

    // MARK: Start

    private func start() {
        startProblem = nil
        switch appState.startLiveHints(choices: choices) {
        case .started, .needsFirstRun, .alreadyRunning:
            break
        case .disabled:
            startProblem = String(localized: "Live hints is switched off. Turn it on to start a session.")
        case .allowanceSpent:
            startProblem = String(localized: "There's no free time left today for live hints.")
        }
    }

    private func startDemo() {
        startProblem = nil
        if appState.startLiveHintsDemo() == .disabled {
            startProblem = String(localized: "Live hints is switched off. Turn it on to start a session.")
        }
    }
}

/// The documents a session searches: during a job with manuals, the job's manuals (the default);
/// otherwise, or by choice, the active project's documents, or the wearer's own documents picked
/// one by one.
struct LiveHintsDocumentPicker: View {
    @EnvironmentObject var appState: AppState
    @Binding var chosen: [String]?
    @Binding var source: HintSourcePreference
    /// The open job's manuals, or nil with no job.
    let openJob: HintJobManuals?

    private var documents: [DocumentStore.DocumentRef] { appState.documentStore.personalDocuments() }

    /// The job's manuals are what the session searches.
    private var jobManualsChosen: Bool { openJob != nil && source == .jobManualsWhenOpen && (chosen ?? []).isEmpty }

    var body: some View {
        Form {
            if let openJob {
                Section {
                    OGSelectionRow(title: LiveHintsCopy.jobManualsName(openJob),
                                   subtitle: String(localized: "The job's manuals, searched as Field Assist searches them."),
                                   isSelected: jobManualsChosen) {
                        source = .jobManualsWhenOpen
                        chosen = nil
                    }
                } footer: {
                    Text("While a job is open, hints come from its manuals unless you choose your own documents.")
                }
            }
            Section {
                OGSelectionRow(title: ProjectContextService.shared.activeProjectName?()
                                   ?? String(localized: "Active project"),
                               subtitle: String(localized: "The documents of the project you're in."),
                               isSelected: !jobManualsChosen && (chosen ?? []).isEmpty) {
                    chosen = nil
                    if openJob != nil { source = .myDocuments }
                }
            } header: {
                if openJob != nil { Text("My documents") }
            }
            Section {
                if documents.isEmpty {
                    Text("No documents yet. Add them in Settings › Documents.")
                        .foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    OGSelectionRow(title: document.name, isSelected: (chosen ?? []).contains(document.id)) {
                        toggle(document.id)
                    }
                }
            } header: {
                Text("Or choose documents")
            }
        }
        .ogFormStyle()
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: String) {
        var ids = chosen ?? []
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        chosen = ids.isEmpty ? nil : ids
        // A document of the wearer's own is a choice of their documents over the job's manuals.
        if openJob != nil { source = .myDocuments }
    }
}

// MARK: - The session screen

/// What a running session shows (§3, §6, §10): the Listening pill for the whole session, the
/// speaker chips with **That's me** when voices are told apart, the last ten hints with their
/// passages (a press opens the passage), Stop, and the model-call count.
struct LiveHintsSessionScreen: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var service: LiveHintsService
    @ObservedObject var list: LiveHintsPhoneList
    let isDemo: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSpeaker: Int?
    @State private var openPassage: LiveHint?
    @Environment(\.appAccent) private var accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let notice = service.notice {
                        OGNotice(text: notice, systemImage: "ear")
                    }
                    if appState.liveHintsTellsVoicesApart || isDemo || !service.heardSpeakers.isEmpty {
                        speakers
                    }
                    hints
                    if appState.liveHintsDisplayConnected, service.hasHint {
                        Button("Show the last hint on the lens") { service.showHintsAgain() }
                            .buttonStyle(.bordered)
                            .frame(minHeight: OGMetrics.minTouchTarget)
                    }
                    Button {
                        if isDemo { appState.stopLiveHintsDemo() } else { appState.stopLiveHints() }
                    } label: {
                        Text(isDemo ? "Stop the demo" : "Stop live hints").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ogProminent)
                    Text(AttributedString(localized: "^[\(service.modelCalls) hint](inflect: true)",
                                          comment: "Live hints session footer: how many answers the AI model was asked for this session."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(OGTheme.canvas.ignoresSafeArea())
            .navigationTitle(isDemo ? "Live hints demo" : "Live hints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $openPassage) { hint in
                LiveHintsPassageSheet(hint: hint)
            }
        }
        .diagnosticScreen()
    }

    private var header: some View {
        HStack(spacing: 8) {
            OGStatusPill(text: String(localized: "Listening",
                                      comment: "Live hints: the pill shown for the whole of a session."),
                         dot: OGTheme.ok)
            Text(verbatim: LiveHintsSetupView.modeTitle(service.mode))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Speakers

    private func label(_ speaker: Int) -> String {
        isDemo ? AppState.demoSpeakerLabel(speaker) : appState.ambientCaptions.speakerRegistry.displayLabel(for: speaker)
    }

    @ViewBuilder
    private var speakers: some View {
        OGSection(header: "Voices",
                  footer: "Your voice is kept for this session only, and your own questions aren't hinted.") {
            VStack(alignment: .leading, spacing: 10) {
                if service.heardSpeakers.isEmpty {
                    Text("Voices appear here as people speak.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    PillFlowLayout(spacing: 8) {
                        ForEach(service.heardSpeakers, id: \.self) { speaker in
                            speakerChip(speaker)
                        }
                    }
                }
                if let wearer = service.wearerSpeaker {
                    HStack {
                        Text("Your voice: \(label(wearer))")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Button("Not me") { service.markWearer(speaker: nil) }
                            .frame(minHeight: OGMetrics.minTouchTarget)
                    }
                } else {
                    Button("That's me") {
                        service.markWearer(speaker: selectedSpeaker)
                        selectedSpeaker = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedSpeaker == nil)
                    .frame(minHeight: OGMetrics.minTouchTarget)
                    .accessibilityHint(Text("Marks the chosen voice as yours for this session"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func speakerChip(_ speaker: Int) -> some View {
        let selected = selectedSpeaker == speaker || service.wearerSpeaker == speaker
        return Button {
            selectedSpeaker = selectedSpeaker == speaker ? nil : speaker
        } label: {
            Text(verbatim: label(speaker))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: OGMetrics.minTouchTarget)
                .background(selected ? accent.opacity(OGTheme.Opacity.accentFill) : Color(.quaternarySystemFill),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(service.wearerSpeaker != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Hints

    @ViewBuilder
    private var hints: some View {
        OGSection(header: "Last hints") {
            if list.hints.isEmpty {
                Text(service.mode == .keyword
                     ? "Hints appear here when someone says one of your keywords."
                     : "Hints appear here when someone asks you a question.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(list.hints.enumerated()), id: \.element.id) { index, hint in
                    if index > 0 { OGDivider() }
                    LiveHintRow(hint: hint) {
                        // A hint from the job's manuals opens its page as a citation does (§5a).
                        if isDemo || !appState.openLiveHintManualPage(hint) { openPassage = hint }
                    }
                }
            }
        }
    }
}

/// One hint on the session screen: the question it answers (dimmed), the hint, and where it came
/// from. A hint standing on a passage opens it.
struct LiveHintRow: View {
    let hint: LiveHint
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let caption = Self.caption(hint) {
                        Text(verbatim: caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: hint.line)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = hint.sourceLabel {
                        Text(verbatim: source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if hint.passage != nil {
                    Image(systemName: "doc.text")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: OGMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hint.passage == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint.passage == nil ? Text("")
                           : hint.manualCitation != nil ? Text("Opens the manual page") : Text("Opens the passage"))
    }

    /// The question in a few words, or the keyword that fired.
    static func caption(_ hint: LiveHint) -> String? {
        if let question = hint.question { return HintQuestionGlance.glance(question) }
        if let keyword = hint.keyword { return keyword }
        return nil
    }
}

/// A hint's passage, opened on the phone: the chunk the search found, by `documentId` and
/// `chunkIndex`, with the hint above it.
struct LiveHintsPassageSheet: View {
    @EnvironmentObject var appState: AppState
    let hint: LiveHint
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: hint.line)
                        .font(.headline)
                    if let passage = hint.passage {
                        Text(verbatim: appState.liveHintsPassageText(documentId: passage.documentId,
                                                                     chunkIndex: passage.chunkIndex) ?? passage.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OGTheme.canvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: hint.passage?.sourceName ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
