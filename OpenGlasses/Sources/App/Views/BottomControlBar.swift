import SwiftUI
import PhotosUI

/// The control dock, floating over the bottom of the Voice tab's conversation:
///
///   Control row (bottom): the mic — one round, thumb-sized button that carries every state the old
///                         full-width capsule did (talk, stop, cancel, start or stop a live
///                         session, the mute badge and its long press) — with the buttons button
///                         beside it at the trailing edge. On the grid, the cog takes the leading
///                         corner.
///   Grid panel (above):   the tiles, cut into as many pages as they need and swiped like a home
///                         screen. It rises over the conversation when the buttons button asks for
///                         it and gives the screen back when a turn starts.
///
/// The conversation is not a page of this panel any more: it is the tab's own scroll, so it runs as
/// long as it is and the tab bar shrinks to the mark as it scrolls. `DockPagerPolicy` still decides
/// when the grid steps aside — `.conversation` is the grid lowered, `.actions` the grid up — and
/// still holds the promise that the wearer's own choice is never argued with.
///
/// The grid's tiles are glass keys of their own — three across, each one a pressable lens — drawn
/// inside a single `GlassEffectContainer`, so the keys share one sampling pass rather than each
/// blurring the animating ambience separately.
struct BottomControlBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject private var assistive = AssistiveModeService.shared
    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize

    @Binding var showSettings: Bool
    @Binding var showModelPicker: Bool
    @Binding var showPreview: Bool
    var showChatInput: Binding<Bool>? = nil
    /// Whether the content tiles belong in the grid at all. A mode gate, not a yielding rule — the
    /// tiles submit ordinary Direct-mode turns, and the realtime modes run their own spine.
    var showsActions: Bool = true
    /// The turn state, which the pager reads for its auto-flip. The dock takes the derived state
    /// rather than deriving its own, so the panel and the ambience can never disagree about what
    /// the session is doing.
    var voiceState: VoiceVisualState = .idle
    /// The tab's usable height. The risen grid takes at most a share of it, so the conversation
    /// behind it always keeps a readable window.
    var availableHeight: CGFloat = 0
    /// Set when the row is drawn inside the tab view's bottom accessory (`VoiceDockAccessory`):
    /// smaller controls on the system's own glass, laid out for where the strip currently sits.
    var accessoryPlacement: TabViewBottomAccessoryPlacement? = nil
    /// Set, this bar draws only the grid's pages, filling an area of this height in the
    /// conversation's place. Unset, it draws only the control row. The Voice tab uses one of each.
    var gridAreaHeight: CGFloat? = nil
    /// A reply arrived while the grid was up: the conversation button carries a dot until the
    /// conversation is shown again.
    var unseenReply: Bool = false

    @State private var runningActionId: String?
    @Binding var pager: DockPagerState
    /// The home screen's editor, presented from the cog (or the long press on the grid's gaps).
    @State private var showEditor = false

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    /// FD P0 — the one camera state this bar shows, rather than three booleans read in three
    /// places. Published, so the bar re-renders when the phase changes; the phase is all this
    /// view needs, and none of its copy depends on the freshness clock.
    private var cameraReadiness: CameraReadiness { appState.cameraService.readiness }
    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode.usesOpenAIRealtimeTransport }

    private var realtimeSessionActive: Bool {
        isGemini ? session.isActive : (isOpenAI ? openAISession.isActive : false)
    }

    /// Observes the same UserDefaults key `Config.silentMode` writes, so the push-to-talk
    /// BarButton re-renders on toggle AND stays live-synced with the Settings switch.
    @AppStorage("silentMode") private var pushToTalk = false
    /// The legacy control-only order. Nothing writes it any more — the unified editor writes
    /// `homeGridArrangement` — but it is still read, so a bar a user arranged before the two grids
    /// merged keeps its order without a migration step.
    @AppStorage("dockItemOrder") private var dockOrder = ""
    /// The one arrangement: controls and content actions, order and hidden set.
    @AppStorage("homeGridArrangement") private var storedArrangement = ""
    /// Not read for its value — `Config.quickActions` owns that. This is the republish, so an
    /// action made on the edit page appears on the grid the moment the sheet closes.
    @AppStorage("quickActions") private var quickActionsBeacon = Data()
    /// The same republish for the technician's trades, whose tiles `Config.quickActions` injects.
    @AppStorage(FieldTradeSetting.key) private var tradesBeacon: String?
    /// Plan CT 3b: the Field Assist edition hides the model picker — the organisation chose it.
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var orgProfile = OrgProfileManager.shared

    private var photoDisabledForLocalModel: Bool {
        if isRealtime { return !appState.realtimeSupportsVision }
        return HomeGridPhotoPolicy.blocksPhoto(activeModel: Config.activeModel)
    }

    private var slots: [DockSlot] {
        let controlOrder = DockLayout.decode(dockOrder)
        let quickActions = Config.quickActions
        let available = DockGridCatalog.available(controlOrder: controlOrder,
                                                  quickActions: quickActions).map(\.id)
        let arrangement = HomeGridStore.decode(storedArrangement, available: available).arrangement
        let restricted = adminGate.isRestricted
        return DockGridCatalog.slots(arrangement: arrangement,
                                     controlOrder: controlOrder,
                                     quickActions: quickActions,
                                     showsActions: showsActions)
            .filter { !EditionPresentation.hidesDockSlot($0, restricted: restricted) }
    }

    /// Three glass keys across at every standard text size — see `DockGridMetrics.columns`. At
    /// accessibility sizes a tile lays its glyph beside its label and needs the width of a phrase,
    /// and even two across cut every caption to a letter and an ellipsis by AX4, so it is one
    /// column there — the grid simply runs to more pages. The accessibility audit reports each of
    /// those cuts as clipped text.
    private var columnCount: Int {
        typeSize.isAccessibilitySize ? 1 : DockGridMetrics.columns
    }

    /// The two scaled parts a tile is made of, so the panel snaps to the height the tile actually
    /// draws rather than to a constant that happens to match at one text size. `BarButton` composes
    /// its glyph box and its single caption line from exactly these.
    @ScaledMetric(relativeTo: .title2) private var tileGlyphBox: CGFloat
        = DockGridMetrics.tileGlyphBox
    @ScaledMetric(relativeTo: .footnote) private var tileCaptionLine: CGFloat
        = DockGridMetrics.tileCaptionLine

    /// What a tile's *content* — glyph and caption, without the key's padding — actually measured,
    /// once one has been laid out. The content, not the key: a key is drawn at the height the page
    /// gives it, so measuring the key would feed the page's choice back into itself.
    @State private var measuredTileContent: CGFloat?

    /// The tile's content height. The composed estimate is only the first frame's answer: a
    /// prediction of a tile is a prediction of a font's line height, and being a point or two short
    /// of it is how a row ends up sliced. Once a real tile has reported, the grid works from *that*.
    private var tileContentHeight: CGFloat {
        if let measuredTileContent, measuredTileContent > 0 { return measuredTileContent }
        return typeSize.isAccessibilitySize
            ? max(tileGlyphBox, tileCaptionLine)
            : tileGlyphBox + DockGridMetrics.tileStackSpacing + tileCaptionLine
    }

    /// A tile with its full padding — what it draws when the page has room.
    private var naturalTileHeight: CGFloat {
        HomeGridPaging.naturalTileHeight(contentHeight: tileContentHeight)
    }

    /// The smallest a tile is squeezed to fit another row: its content at this text size, with
    /// only the minimum padding. Rows are counted in these.
    private var minimumTileHeight: CGFloat {
        HomeGridPaging.minimumTileHeight(contentHeight: tileContentHeight)
    }

    /// The grid's page body — the room above its dots — when it takes the conversation's place:
    /// the whole area it is given, less the panel's inset and the dots. The rows then fill it
    /// (`HomeGridPaging.fit`).
    private var pageBodyHeight: CGFloat {
        DockGridMetrics.gridPageBodyHeight(areaHeight: gridAreaHeight ?? 0,
                                           minimumTileHeight: minimumTileHeight)
    }

    /// What gates a control's tile right now — applied before paging, so every page holds exactly
    /// the tiles it draws.
    private var tilePresence: HomeGridTilePresence {
        var presence = appState.homeGridTilePresence
        presence.canType = presence.canType && showChatInput != nil
        return presence
    }

    /// The tiles the grid draws, in the one arranged order.
    private var gridTiles: [HomeGridTile] { tilePresence.tiles(for: slots) }

    /// Rows per grid page and the height every tile on it is drawn at: as many rows of minimum
    /// tiles as fit the page above the dots, one to four, then the tiles stretched to fill it
    /// (`HomeGridPaging.fit`). The content is the measured one, so larger text fits fewer rows
    /// rather than smaller type; and the page body is what the surface above left, so a card
    /// expanding drops a row and the rest share its room.
    private var gridFit: HomeGridPaging.TileFit {
        HomeGridPaging.fit(height: pageBodyHeight, minimumTileHeight: minimumTileHeight,
                           naturalTileHeight: naturalTileHeight)
    }

    /// The grid is up when the pager is on it; on the conversation it is lowered out of the way.
    private var showsGrid: Bool { pager.page == .actions }

    var body: some View {
        Group {
            if gridAreaHeight != nil {
                panel
            } else if let accessoryPlacement {
                accessoryRow(accessoryPlacement)
            } else {
                controlRow
                    .padding(.top, 8)
                    .padding(.bottom, DockGridMetrics.dockBottomPadding)
            }
        }
        .sheet(isPresented: $showEditor) { editorSheet }
    }

    // MARK: - Control row

    /// The cog at the leading edge while the grid is up, then the mic and, at the trailing edge,
    /// the buttons button — the two controls a thumb reaches most, side by side in its corner.
    private var controlRow: some View {
        HStack(spacing: 12) {
            if showsGrid {
                RoundDockButton(icon: "gearshape.fill", size: DockGridMetrics.secondaryButtonSize,
                                label: DockPanelActionName.editHomeScreen,
                                hint: "Add, remove and reorder the tiles, and choose the cards on the home screen.") {
                    showEditor = true
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            micButton
            RoundDockButton(icon: showsGrid ? "text.bubble" : "square.grid.2x2",
                            size: DockGridMetrics.secondaryButtonSize,
                            label: showsGrid ? DockPage.conversation.showActionName
                                             : DockPage.actions.showActionName,
                            hint: "Switch between your buttons and the conversation.",
                            isActive: showsGrid, badge: showsGrid && unseenReply) {
                move { DockPagerPolicy.userMoved(pager, to: showsGrid ? .conversation : .actions) }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Accessory row

    /// The row in the tab view's bottom accessory. Full width above the tab bar, its free width is
    /// the way in to typing (or the cog while the buttons are up) with the two controls at the
    /// trailing edge; shrunk beside the Avenkin mark, it is just the two controls, still trailing.
    @ViewBuilder
    private func accessoryRow(_ placement: TabViewBottomAccessoryPlacement) -> some View {
        HStack(spacing: 10) {
            if placement == .expanded {
                if showsGrid {
                    RoundDockButton(icon: "gearshape.fill", size: DockGridMetrics.accessoryButtonSize,
                                    label: DockPanelActionName.editHomeScreen,
                                    hint: "Add, remove and reorder the tiles, and choose the cards on the home screen.",
                                    onSystemGlass: true) {
                        showEditor = true
                    }
                    Spacer(minLength: 0)
                } else if let showChatInput, !isRealtime {
                    // The strip's free width is the way in to typing: it reads as an empty field and
                    // opens the typed bar, keyboard up — never words that look tappable and are not.
                    Button {
                        showChatInput.wrappedValue = true
                    } label: {
                        Text("Type a request")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                                   alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Type a request")
                    .accessibilityHint("Opens the keyboard to type instead of speaking.")
                } else {
                    // A live session has no typed turn, so the two controls simply keep right.
                    Spacer(minLength: 0)
                }
            }
            MicButton(control: micControl, mutedBadge: micControl.showsMuteBadge, activity: voiceState,
                      onSystemGlass: true)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in appState.micMuted.toggle() }
                )
                .accessibilityHint(appState.micMuted
                                   ? "Double-tap and hold to unmute the microphone."
                                   : "Double-tap and hold to mute the microphone.")
                .accessibilityAction(named: appState.micMuted ? "Unmute microphone"
                                                              : "Mute microphone") {
                    appState.micMuted.toggle()
                }
            RoundDockButton(icon: showsGrid ? "text.bubble" : "square.grid.2x2",
                            size: DockGridMetrics.accessoryButtonSize,
                            label: showsGrid ? DockPage.conversation.showActionName
                                             : DockPage.actions.showActionName,
                            hint: "Switch between your buttons and the conversation.",
                            isActive: showsGrid, badge: showsGrid && unseenReply,
                            onSystemGlass: true) {
                move { DockPagerPolicy.userMoved(pager, to: showsGrid ? .conversation : .actions) }
            }
        }
        .padding(.horizontal, placement == .expanded ? 14 : 6)
        // Shrunk beside the mark, the two controls keep to the strip's trailing end — where the
        // thumb finds them in both placements.
        .frame(maxWidth: .infinity, alignment: placement == .expanded ? .leading : .trailing)
    }

    // MARK: - Panel

    /// The grid's pages, in the conversation's place: the buttons button swaps one for the other,
    /// as the pages of the old panel did. Every page is the same height, so the panel never
    /// resizes under a swipe.
    private var panel: some View {
        let tiles = gridTiles
        let tileIDs = tiles.map(\.id)
        let fit = gridFit
        let paging = HomeGridPaging(tileCount: tiles.count, columns: columnCount, rows: fit.rows)
        let currentGridPage = paging.gridPage(forPanelIndex: paging.panelIndex(for: pager, tileIDs: tileIDs))
        // The conversation counts as a page in the swipe order, so there are always dots to show.
        let pagesDots = true
        let dots = DockGridMetrics.pageIndicatorHeight

        return TabView(selection: pageSelection(paging: paging, tileIDs: tileIDs)) {
            // The conversation's place in the swipe order, as on the old panel: swiping back from
            // the first page of buttons lands here, and the selection binding hands the area back
            // to the conversation.
            Color.clear
                .accessibilityHidden(true)
                .tag(HomeGridPaging.conversationIndex)
            ForEach(Array(0..<paging.pageCount), id: \.self) { gridPage in
                gridPageView(gridPage, tiles: tiles, paging: paging, tileHeight: fit.tileHeight)
                    .padding(.bottom, dots)
                    // Off-screen pages stay in the hierarchy under a paging TabView, so VoiceOver
                    // would otherwise walk pages the user cannot see.
                    .accessibilityHidden(currentGridPage != gridPage)
                    .tag(paging.panelIndex(forGridPage: gridPage))
            }
        }
        // One whole page per swipe, snapping: a short or slow drag springs back, a flick or a drag
        // past half commits.
        .tabViewStyle(.page(indexDisplayMode: pagesDots ? .always : .never))
        // The dots sit on a translucent panel over an animating ambience, where a bare dot has no
        // reliable ground. `.always` gives them their own, in both themes.
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .frame(height: pageBodyHeight + dots)
        .frame(maxHeight: .infinity, alignment: .top)
        // The page control is an adjustable element, which is a poor way to reach a named
        // destination. Every destination is also one named action from wherever focus happens to be.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
        .accessibilityValue(spokenPosition(gridPage: currentGridPage, paging: paging))
        .accessibilityActions {
            Button(DockPage.conversation.showActionName) {
                move { DockPagerPolicy.userMoved(pager, to: .conversation) }
            }
            if let page = currentGridPage, page + 1 < paging.pageCount {
                Button(DockPanelActionName.nextGridPage) {
                    move { DockPagerPolicy.userMoved(
                        pager, toGridPageStartingWith: paging.anchor(forGridPage: page + 1,
                                                                     in: tileIDs)) }
                }
            }
            if let page = currentGridPage, page > 0 {
                Button(DockPanelActionName.previousGridPage) {
                    move { DockPagerPolicy.userMoved(
                        pager, toGridPageStartingWith: paging.anchor(forGridPage: page - 1,
                                                                     in: tileIDs)) }
                }
            }
            Button(DockPanelActionName.editHomeScreen) { showEditor = true }
        }
        .padding(DockGridMetrics.panelInset)
        .glassEffect(in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
    }

    /// The home screen's editor, on a sheet with room to work at any panel height.
    private var editorSheet: some View {
        NavigationStack {
            DockLayoutEditPage()
                .padding(.horizontal, 16)
                .navigationTitle("Edit Home Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showEditor = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .environment(\.appAccent, accent)
        .environmentObject(appState)
    }

    /// "Conversation", or "Actions" with the page when there is more than one.
    private func spokenPosition(gridPage: Int?, paging: HomeGridPaging) -> String {
        guard let gridPage else { return DockPage.conversation.spokenName }
        guard paging.pageCount > 1 else { return DockPage.actions.spokenName }
        let name = DockPage.actions.spokenName
        let page = gridPage + 1
        return String(localized: "\(name), page \(page) of \(paging.pageCount)")
    }

    /// The selection binding. The index shown is *derived* from the pager state under today's
    /// paging, so a reflow needs no handler of its own. A write equal to it is the pager echoing
    /// us; anything else came from a finger (a swipe or the dots), and a finger's choice stands for
    /// the rest of the turn.
    private func pageSelection(paging: HomeGridPaging, tileIDs: [String]) -> Binding<Int> {
        Binding(
            get: { paging.panelIndex(for: pager, tileIDs: tileIDs) },
            set: { newValue in
                guard newValue != paging.panelIndex(for: pager, tileIDs: tileIDs) else { return }
                if let gridPage = paging.gridPage(forPanelIndex: newValue) {
                    pager = DockPagerPolicy.userMoved(
                        pager, toGridPageStartingWith: paging.anchor(forGridPage: gridPage,
                                                                     in: tileIDs))
                } else {
                    pager = DockPagerPolicy.userMoved(pager, to: .conversation)
                }
            }
        )
    }

    /// A deliberate move — the buttons button, or a named accessibility action — so it takes the
    /// same "do not argue with me afterwards" promise a swipe does.
    private func move(_ next: () -> DockPagerState) {
        withAnimation(.easeInOut(duration: 0.25)) { pager = next() }
    }

    // MARK: - Pages

    /// One page of the grid: its slice of the one order, as explicit rows of `columns` keys.
    ///
    /// Rows are drawn rather than left to a lazy grid so the page draws exactly what
    /// `HomeGridPaging` says it holds — row-major, a short last row keeping its column widths with
    /// empty cells, and nothing past the last row. The page is top-aligned and the glass under the
    /// last row is the panel's remainder: calm space, never a sliced tile.
    private func gridPageView(_ page: Int, tiles: [HomeGridTile],
                              paging: HomeGridPaging, tileHeight: CGFloat) -> some View {
        let range = paging.tileRange(onPage: page)
        let rows = paging.rowsDrawn(onPage: page)
        let columns = paging.columns

        return VStack(spacing: 0) {
            // One container for every key on the page, so their glass is sampled in one pass and a
            // press reads as the same material as its neighbours. The spacing is the merge
            // distance: keys further apart than the row gap stay separate shapes.
            GlassEffectContainer(spacing: DockGridMetrics.rowSpacing) {
                VStack(spacing: DockGridMetrics.rowSpacing) {
                    ForEach(Array(0..<rows), id: \.self) { row in
                        let start = range.lowerBound + row * columns
                        let end = min(range.upperBound, start + columns)
                        let rowTiles = Array(tiles[start..<end])
                        HStack(spacing: DockGridMetrics.rowSpacing) {
                            ForEach(rowTiles) { tile in
                                tileView(tile)
                            }
                            // A short last row keeps the column widths of the rows above it.
                            ForEach(Array(0..<(columns - rowTiles.count)), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: 0)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                // Room at the sides for a pressed key: interactive glass swells a little under
                // the finger, and the outer column would otherwise clip on the page edge.
                .padding(.horizontal, 4)
                // Every key on the page at the one height the page chose — squeezed into its
                // padding to fit another row, or stretched to fill the page.
                .environment(\.dockTileHeight, tileHeight)
            }

            // The sub-row remainder, and the rows a short page does not need. Calm empty glass
            // under the tiles — which is where a leftover belongs, rather than between two cards.
            Spacer(minLength: 0)
        }
        // Every key reports its content and the tallest wins — a caption that wraps at an
        // accessibility size is the one the rows have to fit.
        .onPreferenceChange(DockTileContentHeightKey.self) { height in
            guard let height, height > 0, height != measuredTileContent else { return }
            // The opening guess giving way to a real tile: a height change with no motion of its
            // own, so it settles here rather than being chased by the frame.
            withAnimation(DockGridMetrics.heightSettle) { measuredTileContent = height }
        }
        // A text-size change starts the measurement again, so a smaller size is not held to the
        // tallest content a larger one drew.
        .onChange(of: typeSize) { _, _ in measuredTileContent = nil }
        // The sighted shortcut to the editor, on the page's *background* — behind the tiles, so it
        // answers a press on the gaps and never fires alongside a tile's action. The same sheet
        // the cog opens; it is not a page, so no swipe reaches it.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) { showEditor = true }
        )
    }

    @ViewBuilder
    private func tileView(_ tile: HomeGridTile) -> some View {
        switch tile {
        case .slot(let slot):
            dockView(for: slot)
        case .localModel:
            if let local = appState.llmService.localLLMService, let active = Config.activeModel {
                LocalModelTile(service: local, modelConfig: active)
            }
        }
    }

    // MARK: - Mic

    /// The primary control, round and thumb-sized, beside the buttons button.
    private var micButton: some View {
        MicButton(control: micControl, mutedBadge: micControl.showsMuteBadge, activity: voiceState)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        appState.micMuted.toggle()
                    }
            )
            // Mute lives *only* on this long press. A sighted user finds it by accident; a
            // VoiceOver user finds it never, because a gesture leaves no mark in the
            // accessibility tree. The hint is the only place it is discoverable — and the
            // custom action is the only way to reach it, since VoiceOver swallows the
            // long press for its own element-inspection gesture.
            .accessibilityHint(appState.micMuted
                               ? "Double-tap and hold to unmute the microphone."
                               : "Double-tap and hold to mute the microphone.")
            .accessibilityAction(named: appState.micMuted ? "Unmute microphone"
                                                          : "Mute microphone") {
                appState.micMuted.toggle()
            }
    }

    // MARK: - Slots

    @ViewBuilder
    private func dockView(for slot: DockSlot) -> some View {
        switch slot {
        case .control(let item): dockView(for: item)
        case .action(let entry): actionTile(entry)
        }
    }

    /// A content tile — the same `BarButton` every control uses, because they now share a grid and
    /// anything less than identical reads as two grids again.
    @ViewBuilder
    private func actionTile(_ entry: HomeGridEntry) -> some View {
        if case .quickAction(let action) = entry, action.type == .toggleRecording {
            // Live tile: reflects recording state and duration, unlike the fire-and-forget tiles.
            RecordingQuickActionTile(
                action: action,
                controller: appState.sessionRecorder,
                audioRecorder: appState.audioRecorder
            )
        } else {
            let blocked = entry.capturesPhoto && photoDisabledForLocalModel
            BarButton(
                icon: entry.icon,
                label: entry.label,
                isDisabled: blocked,
                isBusy: runningActionId == entry.id,
                truncateLabel: true
            ) {
                guard runningActionId == nil else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                runningActionId = entry.id
                Task {
                    await HomeGridDispatcher.run(entry, on: appState)
                    runningActionId = nil
                }
            }
            .accessibilityHint(
                blocked ? String(localized: "The on-device model cannot see images. Choose a vision model.")
                : runningActionId == entry.id ? String(localized: "Running.") : entry.spokenHint)
        }
    }

    // MARK: - Dock items

    /// One arrangeable slot of the grid. Contextual gating is `HomeGridTilePresence`'s, applied
    /// before paging so a page never grows a hole; moving a slot never changes WHEN it appears —
    /// only where.
    @ViewBuilder
    private func dockView(for item: DockItem) -> some View {
        switch item {
        case .model:
            // The on-device model's load key rides just before the picker as a tile of its own
            // (`HomeGridTile.localModel`), so the two model controls read as one group.
            let isCompatible = appState.currentMode == .openaiCompatibleRealtime
            let provider: LLMProvider = isCompatible ? .custom : (Config.activeModel?.llmProvider ?? .custom)
            let modelName = isCompatible ? Config.compatibleRealtimeConfiguration.model
                : appState.llmService.activeModelName
            BarButton(
                icon: DockLayout.modelTileGlyph(for: provider),
                label: String(localized: "Model"),
                assetIcon: ProviderMark.bundledAsset(for: provider)
            ) {
                showModelPicker = true
            }
            .accessibilityLabel("Model: \(modelName). Opens the model picker.")

        case .camera:
            cameraButton

        case .preview:
            BarButton(
                icon: "eye",
                label: String(localized: "Preview"),
                isActive: appState.videoRecorder.isRecording
            ) {
                showPreview = true
            }

        case .type:
            BarButton(icon: "keyboard", label: String(localized: "Type")) {
                showChatInput?.wrappedValue = true
            }

        case .micMode:
            // Push-to-talk toggle — same switch as Settings (one owner: AppState.setPushToTalk).
            // Labelled with the mode a tap switches TO, not the current one: showing the
            // current mode read as a state badge, and people hunting for push-to-talk
            // couldn't tell this button was where to change it.
            BarButton(
                icon: pushToTalk ? "waveform" : "hand.tap.fill",
                label: pushToTalk ? String(localized: "Wake Word") : String(localized: "Push-Talk"),
                isActive: false
            ) {
                appState.setPushToTalk(!pushToTalk)
            }
            .accessibilityLabel(pushToTalk ? "Switch to wake word listening" : "Switch to push to talk")

        case .assistive:
            BarButton(
                icon: assistive.isActive ? "eye.fill" : "eye",
                label: assistive.isActive ? String(localized: "Assistive On") : String(localized: "Assistive"),
                isActive: assistive.isActive
            ) {
                appState.toggleAssistiveMode()
            }

        case .disconnect:
            // "Sleep" undersold what this does — it disconnects the glasses
            // session outright (stops speech, wake word, camera, live sessions).
            BarButton(icon: "moon.fill", label: String(localized: "Disconnect")) {
                appState.disconnectGlasses()
            }
        }
    }

    // MARK: - Mic states

    /// What the mic does right now — the states the full-width capsule used to carry, one by one.
    private var micControl: MicControl {
        if isGemini {
            return MicControl(
                icon: session.isActive ? "stop.fill" : "play.fill",
                label: session.isActive ? String(localized: "Stop Session") : String(localized: "Start Gemini Live"),
                isActive: session.isActive,
                color: session.isActive ? .red : accent
            ) {
                Task {
                    // Plan FF P1/PR3: the wearer's own Stop, so it latches — nothing ambient puts
                    // back a session that was taken down here.
                    if session.isActive { appState.stopLiveSession(.geminiLive, source: .appUI) }
                    else { await appState.requestLiveSession(.geminiLive, source: .appUI) }
                }
            }
        } else if isOpenAI {
            return MicControl(
                icon: openAISession.isActive ? "stop.fill" : "play.fill",
                label: openAISession.isActive ? String(localized: "Stop Session") : String(localized: "Start \(appState.currentMode.displayName)"),
                isActive: openAISession.isActive,
                color: openAISession.isActive ? .red : accent
            ) {
                Task {
                    if openAISession.isActive {
                        appState.stopLiveSession(appState.currentMode, source: .appUI)
                    } else {
                        await appState.requestLiveSession(appState.currentMode, source: .appUI)
                    }
                }
            }
        } else if appState.isProcessing || appState.speechService.isSpeaking {
            return MicControl(
                icon: "stop.fill",
                label: appState.speechService.isSpeaking ? String(localized: "Stop speaking") : String(localized: "Cancel"),
                isActive: true,
                color: OGTheme.warn
            ) {
                appState.cancelCurrentResponse()
            }
        } else if appState.isListening {
            // Active voice session — explicit End. Shown regardless of glasses connection so
            // Push-to-Talk / phone-only sessions can always be stopped.
            return MicControl(
                icon: "stop.circle.fill",
                label: String(localized: "End voice session"),
                isActive: true,
                color: OGTheme.warn,
                showsMuteBadge: appState.micMuted
            ) {
                appState.endListeningSession()
            }
        } else {
            // Idle — phone-first (`TalkEntryPolicy`). With glasses away or never added this talks
            // on the phone at once; connecting glasses is the glasses pill's job.
            let entry = TalkEntryPolicy.decide(link: appState.glassesPhase,
                                               stoodDown: appState.glassesStoodDown)
            return MicControl(
                icon: "mic.fill",
                label: entry.action == .resumeGlassesThenTalk ? String(localized: "Resume glasses and start talking")
                                                              : String(localized: "Start talking"),
                color: accent,
                showsMuteBadge: appState.micMuted
            ) {
                Task { await appState.connectAndListen() }
            }
        }
    }

    // MARK: - Secondary Buttons

    @ViewBuilder
    private var cameraButton: some View {
        // No "Connect" tile: the app is not glasses-first any more, and a tile that only means
        // something to a wearer was the first thing a phone-only user met on the grid. Without
        // glasses this is the phone's camera; connecting stays on the mic and in Settings.
        if isRealtime && appState.isConnected {
            // FD P0: the label is the readiness phase, not the stream flag. `isStreaming` stayed
            // true across a doff-induced pause and across a decoder that had stopped producing
            // pictures, so this button said **Streaming** over a frozen preview — the one state
            // the wearer could act on, shown as the state where everything is fine.
            //
            // `isActive` still covers every not-stopped phase: the button is a toggle, and a
            // camera that is paused or stalled is a camera that is on.
            BarButton(
                icon: "video.fill",
                label: cameraReadiness.controlLabel,
                isActive: cameraReadiness.phase != .stopped,
                // Disabled while starting: the cold start takes seconds, and a second tap during it
                // did nothing visible, which read as the first tap having failed.
                isDisabled: !appState.realtimeSupportsVision || !realtimeSessionActive || appState.cameraService.isStartingStream
            ) {
                // Plan HY P1: a touch on a live control is the wearer being there.
                appState.noteLiveSessionActivity()
                // Start is an intent decision and reads intent only — never frames. A camera that
                // is up but delivering nothing must not be started a second time, and a camera
                // that is stopped must be startable with no pictures anywhere in sight.
                if appState.realtimeSupportsVision && realtimeSessionActive && !appState.cameraService.isStreaming
                    && !appState.cameraService.isStartingStream {
                    Task {
                        do { try await appState.cameraService.startStreaming() }
                        catch {
                            PrivacyLog.camera(.glasses, .sessionAttemptFailed,
                                              error: SafeErrorSummary(error))
                            appState.errorMessage = String(localized: "Camera: \(error.localizedDescription)")
                            NoticeCenter.shared.post(String(localized: "Camera: \(error.localizedDescription)"),
                                                     severity: .error, source: .camera)
                        }
                    }
                }
            }
            // Dimmed-and-unexplained is the sighted version of this problem too, but a VoiceOver
            // user gets only "dimmed" — the reason has to be said. The cold start is seconds long,
            // so "starting" is its own answer rather than a silent dead button. "The camera is
            // already streaming" was the same untruth as the label, said over a paused stream, so
            // the phase supplies this line too.
            .accessibilityHint(
                !realtimeSessionActive && !appState.cameraService.isStartingStream
                    ? String(localized: "Start the live session first.")
                    : (cameraReadiness.controlHint ?? ""))
        } else {
            BarButton(
                icon: "camera.fill",
                label: String(localized: "Photo"),
                isActive: appState.cameraService.isCaptureInProgress,
                isDisabled: appState.cameraService.isCaptureInProgress || photoDisabledForLocalModel
            ) {
                guard !photoDisabledForLocalModel else { return }
                Task {
                    // Connected, or a link coming up (which `captureAndAnalyzePhoto` waits briefly
                    // for). Glasses that are away or were never added go straight to the phone.
                    if appState.isConnected || appState.glassesPhase.isConnecting {
                        await appState.captureAndAnalyzePhoto()
                    } else {
                        // Straight to the phone camera. `captureAndAnalyzePhoto` first spends up
                        // to five seconds trying to reconnect glasses, which is right for a wearer
                        // whose link dropped and a dead pause for someone who has none.
                        await appState.capturePhotoAndSend(prompt: "Describe what you see in this image.")
                    }
                }
            }
            .accessibilityHint(
                photoDisabledForLocalModel ? "The selected model cannot see images. Choose a vision model."
                : appState.cameraService.isCaptureInProgress ? "Taking a photo."
                : "Double-tap to take a photo and describe it.")
        }
    }

}

// MARK: - Mic button (primary touch target)

/// One state of the mic: what it shows, what it is called, and what a tap does.
private struct MicControl {
    let icon: String
    /// The control's name. Spoken, not drawn: the button is a glyph, and the old capsule's visible
    /// copy ("Tap to talk") was an instruction to a finger anyway.
    let label: String
    var isActive: Bool = false
    var color: Color = .primary
    var showsMuteBadge: Bool = false
    let action: () -> Void
}

/// The mic — a round glass button tinted with its state's hue, large enough to hit without looking.
private struct MicButton: View {
    let control: MicControl
    let mutedBadge: Bool
    /// What the session is doing, shown as a ring around the mic now that the button carries no
    /// words: a pulse while it listens, a turning arc while it thinks, a breath while it speaks.
    var activity: VoiceVisualState = .idle
    /// Drawn on the tab view's accessory strip, which is already glass: a smaller, solid circle
    /// rather than glass on glass.
    var onSystemGlass: Bool = false

    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1
    /// Grows with the text size, but not past half again its size: the mic shares one row with the
    /// buttons beside it, and an AX5 mic would push them off the screen.
    private var diameter: CGFloat {
        let base = onSystemGlass ? DockGridMetrics.accessoryMicSize : DockGridMetrics.micButtonSize
        return base * min(scale, DockGridMetrics.dockButtonMaxScale)
    }
    @ScaledMetric(relativeTo: .caption2) private var badgeOffset: CGFloat = 16

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            control.action()
        } label: {
            ZStack {
                Image(systemName: control.icon)
                    .font(onSystemGlass ? .body.weight(.semibold) : .title.weight(.semibold))
                    .foregroundStyle(OGTheme.onAccentLabel(control.color))
                if mutedBadge {
                    Image(systemName: "mic.slash.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OGTheme.mediaErrorLabel)
                        .padding(4)
                        // Opaque: a translucent badge composites the glyph through itself and the
                        // failure hue stops clearing 3:1 against it.
                        .background(OGTheme.media, in: Circle())
                        .offset(x: badgeOffset, y: -badgeOffset)
                }
            }
            .frame(width: diameter, height: diameter)
            .modifier(MicSurface(color: control.color, onSystemGlass: onSystemGlass))
            .contentShape(.circle)
            .background(
                MicActivityRing(state: activity, color: control.color, diameter: diameter)
                    // A fresh ring per state, so one state's endless animation never leaks into
                    // the next.
                    .id(activity)
            )
        }
        .buttonStyle(.plain)
        // Exactly one button, the size of the circle, by its spoken name.
        .accessibilityRepresentation {
            Button(control.label, action: control.action)
                // The mute badge is the only thing distinguishing a muted session from a live one,
                // so it has to be spoken. As a *value*, so it is re-read when it changes under focus.
                .accessibilityValue(spokenState)
        }
    }

    private var spokenState: String {
        if mutedBadge { return String(localized: "Microphone muted") }
        switch activity {
        case .idle: return ""
        case .listening: return String(localized: "Listening")
        case .thinking: return String(localized: "Thinking")
        case .speaking: return String(localized: "Speaking")
        }
    }
}

/// The mic's own surface: tinted glass floating over the page, or a solid circle on the
/// accessory's glass.
private struct MicSurface: ViewModifier {
    let color: Color
    let onSystemGlass: Bool

    func body(content: Content) -> some View {
        if onSystemGlass {
            content.background(color, in: Circle())
        } else {
            content.glassEffect(.regular.tint(color).interactive(), in: .circle)
        }
    }
}

/// The ring around the mic that says what the session is doing. Decorative — the state is spoken
/// as the mic's value — and still under Reduce Motion, where it is drawn without moving.
private struct MicActivityRing: View {
    let state: VoiceVisualState
    let color: Color
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                EmptyView()
            case .listening:
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 3)
                    .scaleEffect(reduceMotion ? 1.1 : (animating ? 1.32 : 1.04))
                    .opacity(reduceMotion ? 1 : (animating ? 0 : 0.9))
            case .thinking:
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(animating ? 360 : 0))
                    .scaleEffect(1.12)
            case .speaking:
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 3)
                    .scaleEffect(reduceMotion ? 1.1 : (animating ? 1.18 : 1.06))
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, state != .idle else { return }
            let animation: Animation = switch state {
            case .thinking: .linear(duration: 1).repeatForever(autoreverses: false)
            case .listening: .easeOut(duration: 1.4).repeatForever(autoreverses: false)
            default: .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
            }
            withAnimation(animation) { animating = true }
        }
    }
}

/// A round glass button for the dock's control row: the buttons button and the cog.
private struct RoundDockButton: View {
    let icon: String
    let size: CGFloat
    let label: String
    let hint: LocalizedStringKey
    var isActive: Bool = false
    /// A small dot at the top corner — something new behind this button.
    var badge: Bool = false
    /// On the accessory's glass: no glass of its own, just the glyph in its tap target.
    var onSystemGlass: Bool = false
    let action: () -> Void

    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    /// Grows with the text size, capped like the mic so the row always fits across the screen.
    private var side: CGFloat {
        max(OGMetrics.minTouchTarget, size * min(scale, DockGridMetrics.dockButtonMaxScale))
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(onSystemGlass ? .body.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(isActive ? OGTheme.tintedAccentLabel(accent) : .primary)
                .frame(width: side, height: side)
                .modifier(RoundDockSurface(isActive: isActive, accent: accent, onSystemGlass: onSystemGlass))
                .contentShape(.circle)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(accent)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(OGTheme.canvas, lineWidth: 2))
                            .offset(x: -2, y: 2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(badge ? String(localized: "New reply") : "")
        .accessibilityHint(hint)
    }
}

// MARK: - Bar Button (the dock's single tile idiom)

/// The dock tile — every control in the grid uses this one idiom: a glass key, three across, with
/// the glyph over a one-line caption. Interactive glass, so a press answers under the finger the
/// way a system control does; the active state tints the key's own glass rather than washing a
/// shape behind it, and a disabled key keeps its glass but stops answering.
private struct BarButton: View {
    let icon: String
    var label: String = ""
    var isActive: Bool = false
    var isDisabled: Bool = false
    var isBusy: Bool = false
    var badge: String? = nil
    var tint: Color? = nil
    var truncateLabel: Bool = false
    /// A bundled image asset to draw instead of `icon` when one is present — the seam a provider's
    /// own mark drops into. Template-rendered, so it takes the tile's foreground like every other
    /// glyph and never arrives as an off-palette full-colour logo.
    var assetIcon: String? = nil
    var action: () -> Void = {}

    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var glyph: CGFloat = 24
    /// A bundled brand mark's square — see `DockGridMetrics.markGlyphBox` for why it is not `glyph`.
    @ScaledMetric(relativeTo: .title2) private var markGlyph: CGFloat
        = DockGridMetrics.markGlyphBox
    /// The glyph box — square, and one of the parts the dock panel also measures, so the height it
    /// snaps its rows to is the height this tile draws. A shared base, not a literal: the panel
    /// showing a sliver of the next row is exactly what these two drifting apart looks like.
    @ScaledMetric(relativeTo: .title2) private var glyphBox: CGFloat
        = DockGridMetrics.tileGlyphBox
    /// Floors, not scaled metrics: the tile's glyph box and its caption grow on
    /// their own, and these only stop a tile being smaller than a fingertip.
    private let minTileWidth = DockGridMetrics.tileMinWidth
    private let minTileHeight = DockGridMetrics.tileMinHeight
    @ScaledMetric(relativeTo: .caption2) private var badgeOffsetX: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var badgeOffsetY: CGFloat = 8
    /// The height the grid page chose for its keys, when there is one. The content is centred in
    /// it: squeezing takes the padding, never the glyph or the caption.
    @Environment(\.dockTileHeight) private var pageTileHeight

    private var foreground: Color {
        // Disabled reads as the audited quiet grey rather than as everything at
        // 0.4 — see the note on the missing `.opacity` below.
        if isDisabled { return OGTheme.secondaryLabel }
        if let tint, isActive { return OGTheme.tintedAccentLabel(tint) }
        return .primary
    }

    /// The key's glass. Active tints it with the tile's own hue — accent when it has none, so an
    /// untinted toggle that is on still reads as on. Only an enabled key is interactive: the press
    /// response is a promise that something will happen.
    private var keyGlass: Glass {
        var glass = Glass.regular
        if isActive {
            glass = glass.tint((tint ?? accent).opacity(OGTheme.Opacity.accentFill))
        }
        return glass.interactive(!(isDisabled || isBusy))
    }

    /// Glyph over label, or beside it at accessibility sizes. See the note at the call site.
    @ViewBuilder
    private func tileLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if typeSize.isAccessibilitySize {
            HStack(spacing: 8, content: content)
        } else {
            VStack(spacing: DockGridMetrics.tileStackSpacing, content: content)
        }
    }

    var body: some View {
        Button(action: action) {
            // Glyph over label normally; glyph *beside* label at accessibility sizes.
            //
            // Stacked, a tile is as tall as its glyph box plus its caption, and at AX5 that is
            // around 130pt — for a grid of them, above a capsule, in a dock that also has to leave
            // the screen room for the conversation. Laid out side by side the same tile is about
            // the height of one line, and the grid scrolls vertically inside its bounded height,
            // so the space it needs is there. Nothing is dropped or renamed; the parts change
            // places.
            tileLayout {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if icon == "AvenkinMark" {
                        LogoIcon(size: glyph)
                            .foregroundStyle(foreground)
                    } else if let assetIcon {
                        // Not `glyph`, which is the SF symbol's point size. A symbol drawn at a
                        // point size renders ink well beyond it and carries the family's stroke
                        // weights; a brand mark is flat artwork fitted inside its own viewBox
                        // margin, so at the same number it came out visibly lighter and, on
                        // device, too small to recognise. It takes the tile's glyph box instead.
                        Image(assetIcon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: markGlyph, height: markGlyph)
                            .foregroundStyle(foreground)
                    } else {
                        Image(systemName: icon)
                            .font(.title2.weight(.medium))
                            .foregroundStyle(foreground)
                    }

                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OGTheme.onAccentLabel(accent))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(accent, in: Capsule())
                            .offset(x: badgeOffsetX, y: -badgeOffsetY)
                    }
                }
                .frame(width: glyphBox, height: glyphBox)

                if !label.isEmpty {
                    Text(label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(foreground)   // .secondary was illegible over the ambience tint
                        // One line under the glyph, where the grid is three across. Beside the
                        // glyph at accessibility sizes the caption has a whole row, so a phrase
                        // wraps at its spaces there instead of losing its end to an ellipsis.
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                        .truncationMode(truncateLabel ? .middle : .tail)
                }
            }
            // The content alone, for the grid to count rows from (`DockTileContentHeightKey`).
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DockTileContentHeightKey.self,
                                           value: proxy.size.height)
                }
            )
            .padding(.horizontal, typeSize.isAccessibilitySize ? 14 : 6)
            .padding(.vertical, pageTileHeight == nil ? DockGridMetrics.tileVerticalPadding : 0)
            // The key fills its column, so three keys read as a row of equal buttons rather than
            // three captions each wearing a different-width border. On a grid page it is exactly
            // the page's tile height; elsewhere its own padding over the `tileMinHeight` floor.
            .frame(maxWidth: .infinity,
                   minHeight: pageTileHeight ?? minTileHeight,
                   maxHeight: pageTileHeight,
                   alignment: typeSize.isAccessibilitySize ? .leading : .center)
            .frame(minWidth: minTileWidth)
            .contentShape(.rect(cornerRadius: DockGridMetrics.tileCornerRadius))
            .glassEffect(keyGlass, in: .rect(cornerRadius: DockGridMetrics.tileCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isBusy)
        // Deliberately no blanket `.opacity(0.4)` on a disabled tile. It applied
        // to the label as well as the glyph, so a disabled caption rendered at
        // roughly a quarter of its ink — under AA by a wide margin, on a control
        // whose whole job in that state is to explain why it can't be used. The
        // dimming now lives in `foreground`, which is a measured value.
        .accessibilityLabel(label.isEmpty ? icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ") : label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Local model tile (was the full-width LocalModelBar band)

/// On-device model control as a dock tile: Load (accent) → Loading (spinner) → Loaded
/// (green, tap to unload). Shown only when the active model is local.
private struct LocalModelTile: View {
    @ObservedObject var service: LocalLLMService
    let modelConfig: ModelConfig
    @Environment(\.appAccent) private var accent

    var body: some View {
        let isLoaded = service.isModelLoaded && service.loadedModelId == modelConfig.model
        BarButton(
            icon: isLoaded ? "checkmark.circle.fill" : "cpu",
            // The preparation phase's own word while one is running, so a stop that is still
            // finishing reads as "Stopping" rather than as a load that will not end (Plan FC P2).
            label: service.isLoadingModel
                ? service.preparation.displayLabel
                : (isLoaded ? String(localized: "Unload") : String(localized: "Load \(modelConfig.name)")),
            isActive: !service.isLoadingModel,   // tinted whenever idle: accent invites Load, green marks Loaded
            isBusy: service.isLoadingModel,
            tint: isLoaded ? OGTheme.ok : accent,
            truncateLabel: true
        ) {
            if isLoaded {
                service.unloadModel()
            } else {
                Task { try? await service.loadModel(modelConfig.model) }
            }
        }
        .accessibilityLabel(isLoaded ? "\(modelConfig.name) loaded. Tap to unload."
                                     : "Load on-device model \(modelConfig.name)")
    }
}

// MARK: - Measured tile content, and the height a page draws its tiles at

/// The tallest tile content on a page — glyph and caption without the key's padding — so the grid
/// counts rows from what was drawn rather than from a prediction of it.
private struct DockTileContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else { return }
        value = max(value ?? 0, next)
    }
}

/// The height a grid page draws its keys at (`HomeGridPaging.fit`). `nil` outside the grid, where
/// a key keeps its own padding and floor.
private struct DockTileHeightEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    fileprivate var dockTileHeight: CGFloat? {
        get { self[DockTileHeightEnvironmentKey.self] }
        set { self[DockTileHeightEnvironmentKey.self] = newValue }
    }
}

// MARK: - Provider mark

/// Whether a provider's own brand mark is bundled, so the model tile can prefer it over the
/// SF-symbol stand-in. Asset-first by design: dropping `ProviderMark-<provider>` into the catalog
/// is the whole change, and nothing here draws an approximation of a mark that isn't there.
enum ProviderMark {
    static func bundledAsset(for provider: LLMProvider) -> String? {
        let name = DockLayout.providerMarkAsset(for: provider)
        return UIImage(named: name) == nil ? nil : name
    }
}

// MARK: - Recording tile

/// The record-meeting quick action as a live dock tile: red stop icon + elapsed duration while
/// a preserved recording is running. Observes the controller directly because a nested
/// ObservableObject's changes don't republish through `appState`.
private struct RecordingQuickActionTile: View {
    @EnvironmentObject var appState: AppState
    let action: QuickAction
    @ObservedObject var controller: SessionRecorderController
    @ObservedObject var audioRecorder: AudioRecordingService

    var body: some View {
        BarButton(
            icon: controller.isRecording ? "stop.circle.fill" : action.icon,
            label: controller.isRecording ? audioRecorder.formattedDuration : action.label,
            isActive: controller.isRecording,
            tint: .red
        ) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await appState.executeQuickAction(action) }
        }
        .accessibilityLabel("Record meeting")
        .accessibilityValue(controller.isRecording
                            ? "Recording, \(audioRecorder.formattedDuration)" : "Stopped")
        .accessibilityHint("Double-tap to start or stop recording.")
    }
}

// MARK: - Session seams

/// Every content tile reaches the session through a call some other surface already makes: a canned
/// prompt is `ChatInputBar`'s send, a photo prompt is the dock camera's capture-and-ask, and a
/// speed-dial action is the one the widget, the watch and the launcher all run.
extension AppState: HomeGridSession {
    /// What gates a tile on the grid right now. The one reading, so the editors explain what the
    /// grid actually does.
    var homeGridTilePresence: HomeGridTilePresence {
        HomeGridTilePresence(
            canType: !currentMode.isRealtime,
            assistiveAvailable: Config.accessibilityModeEnabled,
            connected: isConnected,
            localModelActive: llmService.localLLMService != nil
                && Config.activeModel?.llmProvider == .local,
            actionsShown: HomeSurfaceVisibility.showsActionTiles(mode: currentMode))
    }

    func submitHomePrompt(_ text: String) async {
        await sendTextMessage(text)
    }

    func submitHomePhotoPrompt(_ text: String) async {
        await capturePhotoAndSend(prompt: text)
    }

    func runHomeQuickAction(_ action: QuickAction) async {
        await executeQuickAction(action)
    }
}

/// A round dock button's surface: its own glass over the page, or a light accent wash when it
/// already sits on the accessory's glass.
private struct RoundDockSurface: ViewModifier {
    let isActive: Bool
    let accent: Color
    let onSystemGlass: Bool

    func body(content: Content) -> some View {
        if onSystemGlass {
            content.background(isActive ? accent.opacity(OGTheme.Opacity.accentFill) : Color.clear,
                               in: Circle())
        } else {
            content.glassEffect(isActive ? .regular.tint(accent.opacity(OGTheme.Opacity.accentFill)).interactive()
                                         : .regular.interactive(), in: .circle)
        }
    }
}
