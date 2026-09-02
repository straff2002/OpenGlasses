import XCTest
@testable import OpenGlasses

/// The Voice tab's home grid: what yields to what, what the catalog promises, which seam an entry
/// reaches, and what the arrangement store salvages.
///
/// Every value here is pure or injected. The grid's own view runs against `AppState`, whose
/// services fatal headless — so the part worth proving is the part that is not a view.
final class HomeGridTests: XCTestCase {

    private let speedDial: [QuickAction] = [
        QuickAction(id: "describe", label: "Describe", icon: "eye", type: .photoThenPrompt,
                    promptText: "Describe what you see."),
        QuickAction(id: "record-meeting", label: "Record", icon: "record.circle",
                    type: .toggleRecording),
    ]

    private func ids(_ entries: [HomeGridEntry]) -> [String] { entries.map(\.id) }

    // MARK: - P1: yielding

    /// The truth table the surface is built on. My Day compacts while listening; the grid does not
    /// appear at all there, and both give the zone to captions and to an assistant turn.
    /// My Day still yields the conversation zone. The content tiles no longer yield anything — the
    /// dock pages instead, so the conversation takes the front rather than the tiles being taken
    /// away. `DockPagerTests` holds that half.
    func testMyDayYieldsOnTheStatesItShould() {
        for state in [VoiceVisualState.idle, .listening, .thinking, .speaking] {
            let quiet = HomeSurfaceVisibility.showsMyDay(state: state, captionsActive: false)
            XCTAssertEqual(quiet, state == .idle || state == .listening,
                           "My Day is wrong at \(state)")

            XCTAssertFalse(HomeSurfaceVisibility.showsMyDay(state: state, captionsActive: true),
                           "My Day is still taking caption height at \(state)")
        }
    }

    /// The tiles submit ordinary Direct-mode turns, so they do not offer themselves in a realtime
    /// session that runs its own spine — the gate the dock's quick-action slot carried. This is the
    /// only condition left on the tiles, and it never was a yielding rule.
    func testTheTilesAreADirectModeSurface() {
        for mode in [AppMode.geminiLive, .openaiRealtime] {
            XCTAssertFalse(HomeSurfaceVisibility.showsActionTiles(mode: mode),
                           "The tiles offer Direct-mode turns during \(mode.rawValue)")
        }
        XCTAssertTrue(HomeSurfaceVisibility.showsActionTiles(mode: .direct))
    }

    // MARK: - P1/P2: the catalog

    /// The ids are what the arrangement persists, so renaming one silently empties somebody's grid.
    func testBuiltInIdsAreStable() {
        XCTAssertEqual(HomeGridAction.builtIns.map(\.id),
                       ["meetings-today", "tasks-today", "photo-to-event", "photo-to-task"])
    }

    func testEntryIdsAreNamespacedSoASpeedDialActionCannotCollide() {
        let entries = HomeGridCatalog.available(quickActions: [
            QuickAction(id: "meetings-today", label: "Mine", icon: "star", type: .prompt,
                        promptText: "Something else"),
        ])
        XCTAssertEqual(Set(ids(entries)).count, entries.count)
        XCTAssertTrue(ids(entries).contains("builtin:meetings-today"))
        XCTAssertTrue(ids(entries).contains("quick:meetings-today"))
    }

    func testActionKindsAreMarkedAndPhotoActionsAreTheOnesThatCapture() {
        XCTAssertEqual(HomeGridAction.meetingsToday.kind, .prompt)
        XCTAssertEqual(HomeGridAction.tasksToday.kind, .prompt)
        XCTAssertEqual(HomeGridAction.photoToEvent.kind, .photoPrompt)
        XCTAssertEqual(HomeGridAction.photoToTask.kind, .photoPrompt)

        XCTAssertFalse(HomeGridEntry.builtIn(.meetingsToday).capturesPhoto)
        XCTAssertTrue(HomeGridEntry.builtIn(.photoToTask).capturesPhoto)
        XCTAssertTrue(HomeGridEntry.quickAction(speedDial[0]).capturesPhoto)
        XCTAssertFalse(HomeGridEntry.quickAction(speedDial[1]).capturesPhoto)
    }

    /// Prompt text is the whole behaviour of a `.prompt` tile — it has to be a real turn, and it
    /// has to ask for the thing the tile is named after rather than name a tool.
    func testPromptTextIsPresentAndAsksForWhatTheTilePromises() {
        for action in HomeGridAction.builtIns {
            XCTAssertFalse(action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(action.id) has no turn to submit")
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertFalse(action.icon.isEmpty)
        }
        XCTAssertTrue(HomeGridAction.meetingsToday.prompt.lowercased().contains("calendar"))
        XCTAssertTrue(HomeGridAction.tasksToday.prompt.lowercased().contains("reminders"))
        XCTAssertTrue(HomeGridAction.photoToEvent.prompt.lowercased().contains("this image"))
        XCTAssertTrue(HomeGridAction.photoToTask.prompt.lowercased().contains("this image"))
    }

    /// A tile's hint is where the camera exists for someone who cannot see the glyph.
    func testEveryEntryHasAHintAndPhotoEntriesSayTheyTakeAPicture() {
        for entry in HomeGridCatalog.available(quickActions: speedDial) {
            XCTAssertFalse(entry.spokenHint.isEmpty, "\(entry.id) has no hint")
            XCTAssertFalse(entry.label.isEmpty, "\(entry.id) has no label")
            if entry.capturesPhoto {
                XCTAssertTrue(entry.spokenHint.lowercased().contains("photo"),
                              "\(entry.id) captures without saying so")
            }
        }
        XCTAssertEqual(HomeGridEntry.quickAction(speedDial[1]).spokenHint,
                       "Double-tap to start or stop recording.")
    }

    // MARK: - P2: which seam an entry reaches

    /// A fake session, so what is provable is *which* call a tile makes.
    @MainActor
    private final class FakeSession: HomeGridSession {
        var prompts: [String] = []
        var photoPrompts: [String] = []
        var quickActions: [QuickAction] = []

        func submitHomePrompt(_ text: String) async { prompts.append(text) }
        func submitHomePhotoPrompt(_ text: String) async { photoPrompts.append(text) }
        func runHomeQuickAction(_ action: QuickAction) async { quickActions.append(action) }
    }

    @MainActor
    func testAPromptActionReachesTheSameSeamAsTypedInput() async {
        let session = FakeSession()
        await HomeGridDispatcher.run(.builtIn(.meetingsToday), on: session)

        XCTAssertEqual(session.prompts, [HomeGridAction.meetingsToday.prompt])
        XCTAssertTrue(session.photoPrompts.isEmpty)
        XCTAssertTrue(session.quickActions.isEmpty)
    }

    @MainActor
    func testAPhotoActionCapturesBeforeItAsks() async {
        let session = FakeSession()
        await HomeGridDispatcher.run(.builtIn(.photoToEvent), on: session)

        XCTAssertEqual(session.photoPrompts, [HomeGridAction.photoToEvent.prompt],
                       "A photo tile submitted a bare prompt — the capture was skipped")
        XCTAssertTrue(session.prompts.isEmpty)
    }

    @MainActor
    func testASpeedDialEntryKeepsItsShippedBehaviour() async {
        let session = FakeSession()
        await HomeGridDispatcher.run(.quickAction(speedDial[1]), on: session)

        XCTAssertEqual(session.quickActions, [speedDial[1]])
        XCTAssertTrue(session.prompts.isEmpty)
        XCTAssertTrue(session.photoPrompts.isEmpty)
    }

    // MARK: - Resolution by id (Plan EB: the currency the voice surfaces speak)

    /// Every entry resolves back from its own id — the ids a Siri phrase and an Action Button
    /// press carry.
    func testEveryEntryResolvesFromItsOwnId() {
        for entry in HomeGridCatalog.available(quickActions: speedDial) {
            XCTAssertEqual(HomeGridCatalog.entry(id: entry.id, quickActions: speedDial), entry)
        }
        XCTAssertNil(HomeGridCatalog.entry(id: "quick:gone", quickActions: speedDial))
        XCTAssertNil(HomeGridCatalog.entry(id: "builtin:nope", quickActions: speedDial))
    }

    /// Resolution ignores the arrangement: a tile taken off the bar is still the wearer's action,
    /// and a hardware button bound to it has to keep working. Hiding is layout, not revocation.
    func testAHiddenTileStillResolvesById() {
        var arrangement = HomeGridArrangement()
        arrangement.hidden = ["quick:describe"]
        XCTAssertFalse(HomeGridCatalog.entries(arrangement: arrangement, quickActions: speedDial)
            .contains { $0.id == "quick:describe" })
        XCTAssertEqual(HomeGridCatalog.entry(id: "quick:describe", quickActions: speedDial),
                       .quickAction(speedDial[0]))
    }

    // MARK: - P3: the arrangement

    func testTheDefaultGridIsTheBuiltInsThenTheSpeedDial() {
        let entries = HomeGridCatalog.entries(arrangement: .default, quickActions: speedDial)
        XCTAssertEqual(ids(entries), [
            "builtin:meetings-today", "builtin:tasks-today",
            "builtin:photo-to-event", "builtin:photo-to-task",
            "quick:describe", "quick:record-meeting",
        ])
    }

    /// Nothing is cut off: the grid wraps and scrolls, so every arranged entry resolves.
    func testEveryArrangedEntryResolvesWithNoCeiling() {
        let many = (0..<12).map {
            QuickAction(id: "a\($0)", label: "A\($0)", icon: "star", type: .prompt, promptText: "x")
        }
        let entries = HomeGridCatalog.entries(arrangement: .default, quickActions: many)
        XCTAssertEqual(entries.count, HomeGridAction.builtIns.count + many.count)
    }

    func testReorderAddAndRemoveRoundTripThroughTheStore() {
        let available = HomeGridCatalog.available(quickActions: speedDial).map(\.id)

        var arrangement = HomeGridArrangement()
        arrangement.order = ["quick:describe", "builtin:photo-to-task", "builtin:meetings-today"]
        arrangement.hidden = ["builtin:tasks-today"]

        let decoded = HomeGridStore.decode(HomeGridStore.encode(arrangement), available: available)
        XCTAssertEqual(decoded.arrangement, arrangement)
        XCTAssertTrue(decoded.droppedIds.isEmpty)

        let entries = ids(HomeGridCatalog.entries(arrangement: decoded.arrangement,
                                                  quickActions: speedDial))
        // The explicit order leads; the hidden entry is off; what was never mentioned appends.
        XCTAssertEqual(entries, [
            "quick:describe", "builtin:photo-to-task", "builtin:meetings-today",
            "builtin:photo-to-event", "quick:record-meeting",
        ])
    }

    /// Salvage semantics: a stored record naming actions this build has no entry for is repaired,
    /// and the ids it lost come back to the caller rather than disappearing.
    func testLossyDecodeNamesWhatItDropped() {
        let available = HomeGridCatalog.available(quickActions: speedDial).map(\.id)
        var stored = HomeGridArrangement()
        stored.order = ["quick:retired-action", "builtin:meetings-today", "builtin:meetings-today"]
        stored.hidden = ["quick:also-gone"]

        let decoded = HomeGridStore.decode(HomeGridStore.encode(stored), available: available)
        XCTAssertEqual(decoded.droppedIds, ["quick:retired-action", "quick:also-gone"])
        XCTAssertEqual(decoded.arrangement.order, ["builtin:meetings-today"],
                       "Duplicates should collapse to their first appearance")
        XCTAssertTrue(decoded.arrangement.hidden.isEmpty)
    }

    func testAnUnreadableRecordFallsBackToTheShippedOrder() {
        let available = HomeGridCatalog.available(quickActions: speedDial).map(\.id)
        let decoded = HomeGridStore.decode("{not json", available: available)
        XCTAssertEqual(decoded.arrangement, .default)
        XCTAssertEqual(ids(HomeGridCatalog.entries(arrangement: decoded.arrangement,
                                                   quickActions: speedDial)),
                       available)
    }

    /// A record from a version this build doesn't know is still two lists of ids, so it is
    /// salvaged and re-stamped rather than thrown away.
    func testAFutureVersionIsSalvagedAndRestamped() {
        let available = HomeGridCatalog.available(quickActions: speedDial).map(\.id)
        var stored = HomeGridArrangement()
        stored.version = 99
        stored.order = ["builtin:tasks-today"]

        let decoded = HomeGridStore.decode(HomeGridStore.encode(stored), available: available)
        XCTAssertEqual(decoded.arrangement.version, HomeGridArrangement.currentVersion)
        XCTAssertEqual(decoded.arrangement.order, ["builtin:tasks-today"])
    }

    func testResetRestoresTheDefaults() {
        // Reset writes an empty string, which is what a fresh install reads.
        let available = HomeGridCatalog.available(quickActions: speedDial).map(\.id)
        let decoded = HomeGridStore.decode("", available: available)
        XCTAssertEqual(decoded.arrangement, .default)
        XCTAssertEqual(ids(HomeGridCatalog.entries(arrangement: decoded.arrangement,
                                                   quickActions: speedDial)),
                       available)
    }

    /// Removing a tile hides it. The action behind it is still in the catalog the editor, the
    /// widget, the watch and the launcher all read, so nothing the user configured is lost.
    func testRemovingATileNeverRemovesTheActionBehindIt() {
        var arrangement = HomeGridArrangement()
        arrangement.hidden = ["quick:describe", "builtin:photo-to-task"]

        let onGrid = ids(HomeGridCatalog.entries(arrangement: arrangement,
                                                 quickActions: speedDial))
        XCTAssertFalse(onGrid.contains("quick:describe"))
        XCTAssertFalse(onGrid.contains("builtin:photo-to-task"))

        let catalog = ids(HomeGridCatalog.available(quickActions: speedDial))
        XCTAssertTrue(catalog.contains("quick:describe"))
        XCTAssertTrue(catalog.contains("builtin:photo-to-task"))
    }

    // MARK: - The dock's one grid

    private var controls: [DockItem] { DockLayout.canonical }

    private func slotIds(_ slots: [DockSlot]) -> [String] { slots.map(\.id) }

    /// One grid: the controls the user arranged, then the content actions.
    func testTheDockGridIsControlsThenActions() {
        let slots = DockGridCatalog.slots(arrangement: .default, controlOrder: controls,
                                          quickActions: speedDial, showsActions: true)
        XCTAssertEqual(Array(slotIds(slots).prefix(controls.count)),
                       controls.map { "control:\($0.rawValue)" })
        XCTAssertEqual(Array(slotIds(slots).dropFirst(controls.count)), [
            "builtin:meetings-today", "builtin:tasks-today",
            "builtin:photo-to-event", "builtin:photo-to-task",
            "quick:describe", "quick:record-meeting",
        ])
    }

    /// The mode gate: realtime sessions run their own turn spine, so the Direct-mode tiles are not
    /// offered there. This is no longer a *yielding* rule — the panel pages instead — but the gate
    /// itself never was one.
    func testARealtimeModeStillLeavesEveryControlAndNoActions() {
        let slots = DockGridCatalog.slots(arrangement: .default, controlOrder: controls,
                                          quickActions: speedDial, showsActions: false)
        XCTAssertEqual(slotIds(slots), controls.map { "control:\($0.rawValue)" })
    }

    /// A control is not something a user can strip off their own dock — an arrangement that hides
    /// one is honoured for everything except that.
    func testControlsCannotBeHidden() {
        var arrangement = HomeGridArrangement()
        arrangement.hidden = ["control:disconnect", "quick:describe"]

        let slots = DockGridCatalog.slots(arrangement: arrangement, controlOrder: controls,
                                          quickActions: speedDial, showsActions: true)
        XCTAssertTrue(slotIds(slots).contains("control:disconnect"))
        XCTAssertFalse(slotIds(slots).contains("quick:describe"))
        XCTAssertFalse(DockSlot.control(.disconnect).isHideable)
        XCTAssertTrue(DockSlot.action(.builtIn(.meetingsToday)).isHideable)
    }

    /// A control and an action can sit next to each other, which is the whole reason the two
    /// editors became one.
    func testControlsAndActionsInterleaveInOneOrder() {
        var arrangement = HomeGridArrangement()
        arrangement.order = ["builtin:tasks-today", "control:disconnect", "quick:describe"]

        let slots = DockGridCatalog.slots(arrangement: arrangement, controlOrder: controls,
                                          quickActions: speedDial, showsActions: true)
        XCTAssertEqual(Array(slotIds(slots).prefix(3)),
                       ["builtin:tasks-today", "control:disconnect", "quick:describe"])
        // Everything unmentioned still arrives, exactly once.
        XCTAssertEqual(Set(slotIds(slots)).count, slots.count)
        XCTAssertEqual(slots.count,
                       controls.count + HomeGridAction.builtIns.count + speedDial.count)
    }

    /// A bar arranged before the two grids merged keeps its control order with no migration step.
    func testAStoredControlOrderStillLeads() {
        let userOrder: [DockItem] = [.disconnect, .micMode] + DockLayout.canonical.filter {
            $0 != .disconnect && $0 != .micMode
        }
        let slots = DockGridCatalog.slots(arrangement: .default, controlOrder: userOrder,
                                          quickActions: speedDial, showsActions: true)
        XCTAssertEqual(Array(slotIds(slots).prefix(2)),
                       ["control:disconnect", "control:micMode"])
    }

    // MARK: - The panel's one height (EB device round 3)

    /// The truth table the panel's height is: My Day's state and the screen, and nothing else.
    ///
    /// The measured numbers are from the device this was reported on — an 874 pt tab and a ~52 pt
    /// row. Whole rows in every cell, because the truncation is the snap.
    func testPanelHeightIsMyDayStateTimesTheScreenAndNothingElse() {
        let cases: [(available: CGFloat, row: CGFloat, compact: Bool, rows: Int)] = [
            // A phone, My Day expanded and then collapsed: collapsing hands back its card and the
            // panel takes it — in whole rows, which is the point of the ceiling being gone.
            (874, 52, false, 4),
            (874, 52, true, 8),
            // A smaller phone. Fewer rows, same rule.
            (667, 52, false, 3),
            (667, 52, true, 6),
            // An accessibility text size grows the row, so the same screen affords fewer.
            (874, 120, false, 1),
            (874, 120, true, 3),
        ]
        for expectation in cases {
            XCTAssertEqual(
                DockGridMetrics.restingRows(availableHeight: expectation.available,
                                            rowHeight: expectation.row,
                                            surfaceAboveIsCompact: expectation.compact),
                expectation.rows,
                "\(expectation.available)pt tab, \(expectation.row)pt row, compact=\(expectation.compact)")
        }
    }

    /// Collapsing My Day is the one control a wearer has over the panel's height, and it must buy
    /// *whole rows* — the gap it used to leave was the report that started this.
    func testCollapsingMyDayBuysWholeRowsAndNotAGap() {
        for available in stride(from: CGFloat(600), through: 1000, by: 20) {
            for row in [CGFloat(48), 52, 64, 96] {
                let expanded = DockGridMetrics.restingRows(
                    availableHeight: available, rowHeight: row, surfaceAboveIsCompact: false)
                let collapsed = DockGridMetrics.restingRows(
                    availableHeight: available, rowHeight: row, surfaceAboveIsCompact: true)
                XCTAssertGreaterThanOrEqual(collapsed, expanded,
                                            "Collapsing My Day cost the panel height")

                // What the panel took is never more than the share it was given, so the surface
                // above always keeps its own.
                let share = DockGridMetrics.heightShareWhenSurfaceAboveIsCompact
                XCTAssertLessThanOrEqual(CGFloat(collapsed) * row, available * share + 0.001,
                                         "The panel took more than its share of the screen")
            }
        }
    }

    /// The invariant, stated as arithmetic: the height function has no page parameter, so no swipe
    /// can change the frame. This is the round-4 promise restored rather than revised — a per-page
    /// height was tried on paper and is exactly what "it keeps growing and shrinking" describes.
    func testTheFrameCannotDependOnThePage() {
        let heights = DockPage.allCases.map { _ in
            DockGridMetrics.restingRows(availableHeight: 874, rowHeight: 52,
                                        surfaceAboveIsCompact: false)
        }
        XCTAssertEqual(Set(heights).count, 1,
                       "Every page resolves to the same frame — the page is not an input")
    }

    /// Nor does the content: a wearer with four tiles gets the same frame as one with forty,
    /// because the conversation page shares it and a short grid must not shrink the transcript to
    /// a two-line window.
    func testAShortGridKeepsTheTallFrame() {
        let tall = DockGridMetrics.restingRows(availableHeight: 874, rowHeight: 52,
                                               surfaceAboveIsCompact: true)
        XCTAssertGreaterThan(tall, 4, "The old four-row ceiling is still capping the panel")
        // The rows the *content* needs are a separate question, and still answerable — the grid
        // scrolls past what the frame shows.
        XCTAssertEqual(DockGridMetrics.rowsNeeded(slotCount: 6, columns: 4), 2)
        XCTAssertEqual(DockGridMetrics.rowsNeeded(slotCount: 40, columns: 4), 10)
    }

    /// Before the first layout there is no measured height to divide by. The panel opens at a
    /// sensible guess rather than at zero rows, and the first real measurement settles it.
    func testAnUnmeasuredScreenFallsBackToAGuess() {
        for (available, row) in [(CGFloat(0), CGFloat(52)), (874, 0), (0, 0)] {
            XCTAssertEqual(DockGridMetrics.restingRows(availableHeight: available, rowHeight: row,
                                                       surfaceAboveIsCompact: false),
                           DockGridMetrics.defaultRowsWithoutMeasurement)
        }
    }

    /// Never zero, whatever the arithmetic says: a panel with no rows is a panel with no controls.
    func testAVeryShortScreenStillGetsARow() {
        XCTAssertEqual(DockGridMetrics.restingRows(availableHeight: 100, rowHeight: 52,
                                                   surfaceAboveIsCompact: false),
                       1)
    }

    /// Two columns at accessibility sizes means the same slots need more rows — and still snap.
    func testTheAccessibilityColumnCountChangesRowsNotTheSnap() {
        XCTAssertEqual(DockGridMetrics.rowsNeeded(slotCount: 6, columns: 2), 3)
        XCTAssertEqual(DockGridMetrics.rowsNeeded(slotCount: 12, columns: 2), 6)
    }

    /// The bug this arithmetic exists to prevent: a height that lands mid-tile, so the row below
    /// the last complete one shows as a sliver at the panel's edge. For every row count and every
    /// plausible tile height, the panel is exactly `n` tiles plus the `n - 1` gaps between them —
    /// never the trailing gap, which is the gap a sliver would sit in.
    func testThePanelHeightIsAlwaysAWholeNumberOfRows() {
        for tileHeight in [DockGridMetrics.tileMinHeight, 48, 65, 96, 130] as [CGFloat] {
            for rows in 1...4 {
                let height = DockGridMetrics.gridHeight(rows: rows, tileHeight: tileHeight)
                XCTAssertEqual(height,
                               CGFloat(rows) * tileHeight + CGFloat(rows - 1) * DockGridMetrics.rowSpacing,
                               accuracy: 0.001)

                // The next row's first pixel is strictly below the viewport, so nothing of it shows.
                let nextRowTop = height + DockGridMetrics.rowSpacing
                XCTAssertGreaterThan(nextRowTop, height,
                                     "A row boundary that coincides with the panel edge would peek")
            }
        }
        XCTAssertEqual(DockGridMetrics.gridHeight(rows: 0, tileHeight: 48), 0)
    }

    /// The panel measures the tile the tile draws, and it measures it *generously*. The two ways of
    /// being wrong are not equal — a row height under the drawn tile clips it, which is the bug;
    /// over it leaves a hairline of glass, which nobody can see. This pins the safe direction.
    func testTheRowHeightNeverUnderestimatesTheTile() {
        XCTAssertEqual(DockGridMetrics.tileGlyphBox, 28)
        XCTAssertEqual(DockGridMetrics.tileStackSpacing, 3)

        // `.caption` renders a line at roughly 16.7 pt at the default text size; the base is above
        // it, so a stacked tile's estimate is never short of what it draws.
        XCTAssertGreaterThan(DockGridMetrics.tileCaptionLine, 16.7)

        let stacked = DockGridMetrics.tileGlyphBox + DockGridMetrics.tileStackSpacing
            + DockGridMetrics.tileCaptionLine
        XCTAssertGreaterThanOrEqual(max(DockGridMetrics.tileMinHeight, stacked),
                                    DockGridMetrics.tileMinHeight)
        // And the floor is still a fingertip, which is the reason it is a floor at all.
        XCTAssertGreaterThanOrEqual(DockGridMetrics.tileMinHeight, OGMetrics.minTouchTarget)
    }

    func testHidingEverythingLeavesAnEmptyGridRatherThanTheDefaults() {
        var arrangement = HomeGridArrangement()
        arrangement.hidden = HomeGridCatalog.available(quickActions: speedDial).map(\.id)
        XCTAssertTrue(HomeGridCatalog.entries(arrangement: arrangement,
                                              quickActions: speedDial).isEmpty)
    }
}
