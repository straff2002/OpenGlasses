import SwiftUI

struct WatchMainView: View {
    @ObservedObject var connectivity: WatchConnectivityService
    @State private var errorMessage: String?
    /// A quick action that came back with an error made no answer, so the last answer is not shown
    /// beside its error as if it were this one's (Plan LT §3). Cleared by the next action.
    @State private var answerSupersededByError = false
    @State private var feedbackTrigger: Int = 0
    @State private var errorFeedbackTrigger: Int = 0
    /// A dictated question is with the phone and has not been answered yet.
    @State private var isAsking = false
    /// Counts dictated answers as they arrive, so the list can bring each one into view.
    @State private var answerArrivals: Int = 0
    /// The More screen is open.
    @State private var showingMore = false
    /// The More items the wearer also keeps on the main screen (`WatchMorePins`), on this watch only.
    @AppStorage(WatchMorePins.storageKey) private var storedPins = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts taps per tile, so the tapped tile's glyph answers the press.
    @State private var tileTaps: [String: Int] = [:]
    /// One height for every tile, so a row of keys lines up whatever its captions; it grows with
    /// the text size.
    @ScaledMetric(relativeTo: .caption2) private var tileHeight: CGFloat = 64
    /// The capture row's height, below a tile's.
    @ScaledMetric(relativeTo: .footnote) private var captureHeight: CGFloat = 34

    private var accentColor: Color {
        Self.color(for: connectivity.accentColorName)
    }

    // MARK: - Toggle Bindings

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { connectivity.isListening },
            set: { _ in
                errorMessage = nil
                connectivity.sendCommand("toggleListen") { error in
                    if let error {
                        errorMessage = error
                        errorFeedbackTrigger += 1
                    } else {
                        feedbackTrigger += 1
                    }
                }
            }
        )
    }

    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { connectivity.isRecording },
            set: { _ in
                errorMessage = nil
                connectivity.sendCommand("toggleRecord") { error in
                    if let error {
                        errorMessage = error
                        errorFeedbackTrigger += 1
                    } else {
                        feedbackTrigger += 1
                    }
                }
            }
        )
    }

    private var videoBinding: Binding<Bool> {
        Binding(
            get: { connectivity.isVideoRecording },
            set: { _ in
                errorMessage = nil
                connectivity.sendCommand("toggleVideo") { error in
                    if let error {
                        errorMessage = error
                        errorFeedbackTrigger += 1
                    } else {
                        feedbackTrigger += 1
                    }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        statusBar

                        // While a private conversation is open (Plan LU): its badge and End, at the
                        // top, because it changes what everything below keeps.
                        if connectivity.isPrivate {
                            privateBadge
                        }

                        // A map card from the phone (Plan GM): "how far is that tower?", "where
                        // am I?", "find a pharmacy". Directly under the status, because a spatial
                        // answer is what the wearer raised the wrist for.
                        WatchNowShowingRow(connectivity: connectivity, accent: accentColor)

                        // Now Playing, today's calendar and the weather (Plan KS), one swipe apart.
                        WatchTodayRow(connectivity: connectivity)

                        // The job in hand (Plan FO P3a). Read-only, and directly under the status,
                        // because on a service visit it is the thing being glanced at.
                        if let job = connectivity.job {
                            jobSection(job)
                            Divider()
                        }

                        // Listen, and beside it asking by speaking to the watch itself
                        askRow

                        // The answer, straight under the question that asked for it
                        if !connectivity.shownReply.isEmpty,
                           !(answerSupersededByError && errorMessage != nil) {
                            responseSection
                                .id(Self.responseAnchor)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // The phone's first tiles, three across as the phone draws them
                        tileGrid
                            .id(Self.tilesAnchor)

                        // The glasses' camera and the transcript, one row
                        captureRow

                        // What the wearer keeps here from More, then More itself
                        ForEach(pinnedItems) { item in
                            moreItemButton(item)
                        }
                        moreButton
                            .id(Self.endAnchor)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .fontDesign(.rounded)
                }
                .onChange(of: answerArrivals) {
                    withAnimation { proxy.scrollTo(Self.responseAnchor, anchor: .top) }
                }
                #if DEBUG
                // Opens on the tiles, for a look in the simulator (Debug builds only).
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    try? await Task.sleep(for: .milliseconds(600))
                    if arguments.contains("-watchHomeDemoTiles") {
                        proxy.scrollTo(Self.tilesAnchor, anchor: .top)
                    } else if arguments.contains("-watchHomeDemoEnd") {
                        proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                    } else if arguments.contains("-watchHomeDemoMore") {
                        showingMore = true
                    }
                }
                #endif
            }
            .containerBackground(for: .navigation) { backgroundGlow }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ogLogo
                }
            }
            .navigationDestination(isPresented: $showingMore) {
                moreScreen
            }
        }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .sensoryFeedback(.error, trigger: errorFeedbackTrigger)
        // One tap for a map the wearer asked to see on the watch; automatic cards arrive silently.
        .sensoryFeedback(.impact, trigger: connectivity.surfaceTaps)
        // A tap on a complication lands here: it can only open the app, so the app does the work.
        .onOpenURL { url in
            guard let command = WatchComplicationLink.command(from: url) else { return }
            errorMessage = nil
            connectivity.runComplicationCommand(command) { error in
                if let error {
                    errorMessage = error
                    errorFeedbackTrigger += 1
                } else {
                    feedbackTrigger += 1
                }
            }
        }
    }

    // MARK: - Wordmark

    /// The Avenkin mark alone in the corner, tinted with the accent; it says its name to VoiceOver.
    private var ogLogo: some View {
        // The mark's artwork sits centred in its square with clear space all round (the glyph
        // spans about 65 % of the width and 52 % of the height). Lay it out by the glyph's own
        // bounds, so it sits flush in the toolbar corner rather than inset by that clear space.
        LogoIcon(size: Self.logoMarkSize)
            .frame(width: Self.logoMarkSize * 0.65, height: Self.logoMarkSize * 0.52)
            .foregroundStyle(accentColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Avenkin")
    }

    /// The square the mark is drawn in; its glyph comes out about 20 pt tall.
    private static let logoMarkSize: CGFloat = 38

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectivity.isReachable ? .green : .red)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(connectivity.isReachable
                 ? (connectivity.isConnected ? "Glasses Connected" : "iPhone Connected")
                 : "Not Reachable")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let battery = connectivity.batteryLevel, battery > 0 {
                Text("\(battery)%")
                    .font(.caption2)
                    .foregroundStyle(battery < 20 ? .red : .secondary)
                    .accessibilityLabel("Battery \(battery) percent")
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Ask

    /// **Listen** opens a microphone the phone can reach — the glasses, earbuds, or the phone
    /// itself — and is the screen's one filled button. The round button beside it asks with the
    /// watch's own microphone instead.
    private var askRow: some View {
        HStack(spacing: 6) {
            Button {
                listeningBinding.wrappedValue = !connectivity.isListening
            } label: {
                HStack(spacing: 6) {
                    if connectivity.isProcessing {
                        ProgressView()
                            .frame(width: 18, height: 18)
                    } else if connectivity.isListening {
                        // The one moving thing on the screen: it is listening.
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative.reversing,
                                          isActive: !reduceMotion)
                    } else {
                        Image(systemName: "mic.fill")
                    }
                    Text(connectivity.isListening ? "Listening" : "Listen")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .tint(accentColor)
            .disabled(!connectivity.isReachable)
            .accessibilityLabel(connectivity.isListening ? "Stop listening" : "Listen")
            .accessibilityIdentifier("watchListen")

            dictateButton
        }
    }

    // MARK: - Dictate

    /// Ask with the watch's own microphone. Listen opens a microphone the phone can reach — the
    /// glasses, earbuds, or the phone itself; this one needs none of them. The system's dictation
    /// turns what is said into text here on the wrist, and the text is what goes to the phone.
    private var dictateButton: some View {
        TextFieldLink(prompt: Text("Ask Avenkin")) {
            Group {
                if isAsking {
                    ProgressView()
                } else {
                    // The watch's own text input (speak, scribble or type), apart from Listen's
                    // waveform beside it.
                    Image(systemName: "text.bubble")
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 22, height: 22)
        } onSubmit: { question in
            errorMessage = nil
            isAsking = true
            connectivity.sendCommand(WatchDictationWire.command,
                                     extra: [WatchDictationWire.textKey: question]) { error in
                isAsking = false
                if let error {
                    errorMessage = error
                    errorFeedbackTrigger += 1
                } else {
                    feedbackTrigger += 1
                    // The answer is the point, and it is drawn under the question.
                    answerArrivals += 1
                }
            }
        }
        .frame(width: 48)
        .buttonStyle(.glass)
        .disabled(!connectivity.isReachable || connectivity.isProcessing)
        .accessibilityLabel("Dictate")
    }

    // MARK: - Private

    /// While a private conversation is open: the lock and Private, and **End**. Starting one is a
    /// More item (`moreItemButton(.privateConversation)`); the phone's refusal, when it can't start
    /// (a job, the organisation, the wearer's own switch, a live session), shows as any other error.
    private var privateBadge: some View {
        HStack(spacing: 6) {
            Label("Private", systemImage: "lock.fill")
                .font(.body.weight(.semibold))
                .accessibilityLabel("Private conversation. Nothing of it is kept.")
            Spacer(minLength: 4)
            Button("End") { sendPrivate(.end) }
                .buttonStyle(.bordered)
                .accessibilityLabel("End private conversation")
                .accessibilityIdentifier("watchPrivateEnd")
                .disabled(!connectivity.isReachable)
        }
        .accessibilityIdentifier("watchPrivateBadge")
    }

    private func sendPrivate(_ action: WatchPrivateWire.Action) {
        errorMessage = nil
        connectivity.sendPrivateRequest(action) { error in
            if let error {
                errorMessage = error
                errorFeedbackTrigger += 1
            } else {
                feedbackTrigger += 1
            }
        }
    }

    // MARK: - Tiles

    /// A tile as the wrist draws it: one of the phone grid's, or, from a phone too old to send
    /// those, one of its first four speed-dial actions, run by the command that phone knows.
    private struct ShownTile: Identifiable {
        let tile: WatchGridWire.Tile
        let isLegacy: Bool
        var id: String { tile.id }
    }

    private var shownTiles: [ShownTile] {
        if let tiles = connectivity.gridTiles {
            return tiles.map { ShownTile(tile: $0, isLegacy: false) }
        }
        return connectivity.quickActions.map { action in
            ShownTile(tile: WatchGridWire.Tile(id: action.id, label: action.label, icon: action.icon,
                                              takesPhoto: false, dimmed: false),
                      isLegacy: true)
        }
    }

    /// Three across, as the phone draws them; one at accessibility text sizes, as the phone does,
    /// because three cells cut every caption to a letter there.
    private var tileColumns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 1 : WatchGridWire.columns
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
    }

    @ViewBuilder
    private var tileGrid: some View {
        let tiles = shownTiles
        if !tiles.isEmpty {
            GlassEffectContainer(spacing: 4) {
                LazyVGrid(columns: tileColumns, spacing: 4) {
                    ForEach(tiles) { shown in
                        tileButton(shown)
                    }
                }
            }
        }
    }

    private func tileButton(_ shown: ShownTile) -> some View {
        let tile = shown.tile
        return Button {
            runTile(shown)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tile.icon)
                    .font(.title3)
                    .foregroundStyle(accentColor)
                    .frame(height: 22)
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : tileTaps[tile.id, default: 0])
                // A one-word caption shrinks a little rather than break mid-word ("Meet-ings");
                // a phrase may take two lines.
                Text(verbatim: tile.label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(tile.label.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // A glass key, as each tile on the phone is.
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // Dimmed where the phone dims it: a photo tile while the model in use cannot see.
        .opacity(tile.dimmed ? 0.4 : 1)
        .disabled(!connectivity.isReachable || connectivity.isProcessing || tile.dimmed)
        .accessibilityLabel(Text(verbatim: tile.label))
        .accessibilityHint(tile.takesPhoto
                           ? Text("Takes a photo with your glasses, then asks about it.")
                           : Text("Runs on your iPhone."))
    }

    private func runTile(_ shown: ShownTile) {
        tileTaps[shown.tile.id, default: 0] += 1
        errorMessage = nil
        answerSupersededByError = false
        let command = shown.isLegacy ? "quickAction" : WatchGridWire.command
        let extra: [String: Any] = shown.isLegacy
            ? ["action_id": shown.tile.id]
            : [WatchGridWire.entryIdKey: shown.tile.id]
        connectivity.sendCommand(command, extra: extra) { error in
            if let error {
                errorMessage = error
                // No answer was made, so the last one is not shown beside the error as this one's.
                answerSupersededByError = true
                errorFeedbackTrigger += 1
            } else {
                feedbackTrigger += 1
                answerArrivals += 1
            }
        }
    }

    // MARK: - Photo, Video, Transcribe

    /// The glasses' camera (a photo saved, or video) and a transcript, as one row of round
    /// buttons. Photo and Video need the glasses; Transcribe uses whatever microphone the phone has.
    private var captureRow: some View {
        GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
            roundButton(icon: "camera.fill", active: false,
                        enabled: connectivity.isConnected && !connectivity.isProcessing) {
                errorMessage = nil
                connectivity.sendCommand("capturePhoto") { error in
                    if let error {
                        errorMessage = error
                        errorFeedbackTrigger += 1
                    } else {
                        feedbackTrigger += 1
                    }
                }
            }
            .accessibilityLabel("Take a photo")
            .accessibilityHint("Saves a photo from your glasses.")

            roundButton(icon: connectivity.isVideoRecording ? "video.fill" : "video",
                        active: connectivity.isVideoRecording,
                        enabled: connectivity.isConnected) {
                videoBinding.wrappedValue = !connectivity.isVideoRecording
            }
            .accessibilityLabel(connectivity.isVideoRecording ? "Stop video" : "Record video")

            roundButton(icon: "waveform.and.mic",
                        active: connectivity.isRecording,
                        enabled: true) {
                recordingBinding.wrappedValue = !connectivity.isRecording
            }
            .accessibilityLabel(connectivity.isRecording ? "Stop transcribing" : "Transcribe")
        }
        }
    }

    /// Red while it records, as the toggles it replaces were.
    private func roundButton(icon: String, active: Bool, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(active ? .white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: captureHeight)
                .contentShape(Capsule())
                // Shorter than a tile, so the row reads as controls rather than three more tiles;
                // drawn here because a glass button keeps a taller minimum on the watch.
                .glassEffect(active ? .regular.tint(.red).interactive() : .regular.interactive(),
                             in: .capsule)
        }
        .buttonStyle(.plain)
        .opacity(connectivity.isReachable && enabled ? 1 : 0.4)
        .disabled(!connectivity.isReachable || !enabled)
    }

    // MARK: - More

    /// The pins the main screen can draw now: a persona the phone no longer offers waits.
    private var pinnedItems: [WatchMorePins.Item] {
        WatchMorePins.shown(storedPins, personaIds: connectivity.personas.map(\.id))
    }

    private var moreButton: some View {
        Button {
            showingMore = true
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watchMore")
    }

    /// Everything that used to fill the main screen and is used less: a private conversation,
    /// Connect or Sleep, personas and recent conversations. Each pinnable item can be kept on the
    /// main screen as well; it stays here either way.
    private var moreScreen: some View {
        List {
            Section {
                moreRow(.privateConversation)
                moreRow(.connection)
                ForEach(connectivity.personas) { persona in
                    moreRow(.persona(id: persona.id))
                }
            } footer: {
                Text("Tap the pin to keep an item on the main screen too.")
            }

            if !connectivity.recentThreads.isEmpty {
                Section("Recent") {
                    ForEach(connectivity.recentThreads) { thread in
                        threadButton(thread)
                    }
                }
            }
        }
        .navigationTitle("More")
    }

    private func moreRow(_ item: WatchMorePins.Item) -> some View {
        let pinned = WatchMorePins.decode(storedPins).contains(item)
        return HStack(spacing: 4) {
            // Two buttons in one list row: plain styles, so each takes only its own taps.
            moreItemButton(item, closesMore: true)
                .buttonStyle(.plain)
            Button {
                storedPins = WatchMorePins.toggling(item, in: storedPins)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "Remove from main screen" : "Keep on main screen")
        }
    }

    /// One More item, as both screens draw it. From More, running it goes back to the main screen,
    /// where its answer or its error is shown.
    @ViewBuilder
    private func moreItemButton(_ item: WatchMorePins.Item, closesMore: Bool = false) -> some View {
        switch item {
        case .privateConversation:
            Button {
                if closesMore { showingMore = false }
                sendPrivate(connectivity.isPrivate ? .end : .start)
            } label: {
                moreLabel(connectivity.isPrivate ? "End private" : "Private",
                          icon: connectivity.isPrivate ? "lock.open" : "lock")
            }
            .accessibilityLabel(connectivity.isPrivate ? "End private conversation"
                                                       : "Start a private conversation")
            .accessibilityIdentifier("watchPrivateStart")
            .disabled(!connectivity.isReachable)
        case .connection:
            Button {
                if closesMore { showingMore = false }
                runCommand(connectivity.isConnected ? "sleep" : "connect")
            } label: {
                if connectivity.isConnected {
                    moreLabel("Sleep", icon: "moon.fill")
                } else {
                    Label {
                        Text("Connect")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } icon: {
                        LogoIcon(size: 16)
                            .foregroundStyle(accentColor)
                    }
                }
            }
            .disabled(!connectivity.isReachable || connectivity.isProcessing)
        case .persona(let id):
            if let persona = connectivity.personas.first(where: { $0.id == id }) {
                Button {
                    if closesMore { showingMore = false }
                    runCommand("persona", extra: ["persona_id": persona.id])
                } label: {
                    Label {
                        Text(verbatim: persona.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } icon: {
                        Image(systemName: "person.fill")
                            .foregroundStyle(accentColor)
                    }
                }
                .disabled(!connectivity.isReachable || connectivity.isProcessing)
            }
        }
    }

    private func moreLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        Label {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(accentColor)
        }
    }

    private func runCommand(_ command: String, extra: [String: Any] = [:]) {
        errorMessage = nil
        connectivity.sendCommand(command, extra: extra) { error in
            if let error {
                errorMessage = error
                errorFeedbackTrigger += 1
            } else {
                feedbackTrigger += 1
            }
        }
    }

    // MARK: - Job (Plan FO P3a)

    /// What the wrist says about the open job. No buttons: every decision a job needs — the number,
    /// the unit question, closing it — is put where it can actually be answered.
    private func jobSection(_ job: WatchConnectivityService.JobInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(job.jobNumber)
                    .font(.caption)
                    .bold()
                Spacer()
                Text(job.state)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !job.unit.isEmpty {
                Text(job.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !job.nextAction.isEmpty {
                Text(job.nextAction)
                    .font(.caption2)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Conversations

    /// A recent conversation, resumed on the phone. From More, so it goes back to the main screen.
    private func threadButton(_ thread: WatchConnectivityService.ThreadInfo) -> some View {
        Button {
            showingMore = false
            runCommand("resumeThread", extra: ["thread_id": thread.id])
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.caption)
                    .lineLimit(1)
                if !thread.summary.isEmpty {
                    Text(thread.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .disabled(!connectivity.isReachable || connectivity.isProcessing)
    }

    // MARK: - Response

    private static let responseAnchor = "response"
    private static let tilesAnchor = "tiles"
    private static let endAnchor = "end"

    /// The answer on a pane of glass, signed with the mark rather than labelled.
    private var responseSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            LogoIcon(size: 18)
                .frame(width: 12, height: 10)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)
            // In full: for a question dictated with nothing else on, this is the whole answer.
            Text(connectivity.shownReply)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Avenkin: \(connectivity.shownReply)"))
    }

    /// The screen's ground: the accent, warm at the top and falling to black, the way watchOS
    /// tints an app's background. It glows brighter while Avenkin is listening.
    private var backgroundGlow: some View {
        LinearGradient(colors: [accentColor.opacity(connectivity.isListening ? 0.6 : 0.3), .black],
                       startPoint: .top, endPoint: .center)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: connectivity.isListening)
    }

    // MARK: - Accent Color

    /// Mirrors AppAccent presets from the iOS app.
    private static func color(for name: String) -> Color {
        switch name {
        case "green":   return Color(red: 0.3, green: 0.75, blue: 0.4)
        case "violet":  return AccentColors.aiCoral
        case "blue":    return Color(red: 0.25, green: 0.5, blue: 1.0)
        case "teal":    return Color(red: 0.2, green: 0.7, blue: 0.7)
        case "orange":  return Color(red: 1.0, green: 0.6, blue: 0.2)
        case "pink":    return Color(red: 0.95, green: 0.35, blue: 0.55)
        case "red":     return Color(red: 0.9, green: 0.25, blue: 0.3)
        case "white":   return .white
        default:        return Color(red: 0.3, green: 0.75, blue: 0.4)
        }
    }
}
