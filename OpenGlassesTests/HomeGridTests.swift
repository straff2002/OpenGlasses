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

    // MARK: - The panel's one height (EB device rounds 3–5)

    /// The frame is subtraction and nothing else: what the screen has, minus what the surface above
    /// it *measured*. No share, no page, no slot count — and, since round 5, no row term either.
    ///
    /// The reserved numbers stand for the two states a wearer moves between: ~400 pt for a status
    /// card over a short or collapsed My Day plus the dock's own rhythm, ~600 pt with the card
    /// open. They are inputs here rather than constants in the code, which is the whole point: the
    /// panel is sized by whatever was drawn.
    func testPanelHeightIsTheScreenMinusWhatTheSurfaceAboveMeasured() {
        let cases: [(available: CGFloat, reserved: CGFloat, row: CGFloat, height: CGFloat)] = [
            // A phone, My Day open and then short. Every point the surface hands back is a point
            // the glass takes — not "as many whole rows as fit", which is what left a gap.
            (874, 600, 52, 274),
            (874, 400, 52, 474),
            // A smaller phone. Same rule, less of it — and the first cell is the floor winning,
            // because 67 pt of budget is less than one row and the dots.
            (667, 600, 52, 92),
            (667, 400, 52, 267),
            // An accessibility text size does not enter the frame at all any more. It only moves
            // the floor, and neither of these is near it.
            (874, 600, 120, 274),
            (874, 400, 120, 474),
        ]
        for expectation in cases {
            XCTAssertEqual(
                DockGridMetrics.panelPagesHeight(availableHeight: expectation.available,
                                                 reservedHeight: expectation.reserved,
                                                 rowHeight: expectation.row),
                expectation.height,
                accuracy: 0.001,
                "\(expectation.available)pt tab, \(expectation.reserved)pt reserved, "
                    + "\(expectation.row)pt row")
        }
    }

    /// The rhythm rule, stated as arithmetic: **nothing is left over between the modules.**
    ///
    /// This is the round-5 report and it is the strict version of round 4's. Measuring the surface
    /// fixed the size of the reservation; snapping the *frame* to whole rows then put up to a row
    /// of the leftover back between the card and the panel, beside gaps that are all `moduleGap`.
    /// Pure subtraction means the sum is exact: the surface, the panel and the dock's own rhythm
    /// account for the entire screen, so the only gaps a wearer sees are the ones we chose.
    func testNothingIsLeftOverBetweenTheModules() {
        for available in stride(from: CGFloat(600), through: 1000, by: 20) {
            for reserved in stride(from: CGFloat(200), through: 560, by: 20) {
                for row in [CGFloat(48), 52, 64, 96] {
                    let pages = DockGridMetrics.panelPagesHeight(availableHeight: available,
                                                                 reservedHeight: reserved,
                                                                 rowHeight: row)
                    let context = "\(available)pt tab, \(reserved)pt reserved, \(row)pt row"

                    // Above the floor, every point is accounted for. Not "within a row of it" —
                    // exactly. Below it the panel refuses to shrink further and the zone scrolls,
                    // which its own test covers.
                    guard available - reserved >= DockGridMetrics.minimumPagesHeight(rowHeight: row)
                    else { continue }
                    XCTAssertEqual(reserved + pages, available, accuracy: 0.001,
                                   "The screen did not add up, so the difference is a gap: \(context)")
                }
            }
        }
    }

    /// The panel still refuses to vanish. Below its floor the arithmetic stops subtracting and the
    /// zone above scrolls instead — a dock with no controls is not a smaller dock.
    func testThePanelFloorsRatherThanVanishing() {
        for row in [CGFloat(48), 52, 64, 120] {
            let floor = DockGridMetrics.minimumPagesHeight(rowHeight: row)
            XCTAssertGreaterThanOrEqual(
                DockGridMetrics.panelPagesHeight(availableHeight: 400, reservedHeight: 500,
                                                 rowHeight: row),
                floor,
                "A surface taller than the tab took the panel below its floor")
            XCTAssertGreaterThanOrEqual(
                DockGridMetrics.panelPagesHeight(availableHeight: 300, reservedHeight: 290,
                                                 rowHeight: row),
                floor)
            // One row and the dots, so a floored panel is still a usable one.
            XCTAssertGreaterThanOrEqual(floor, row)
            XCTAssertGreaterThanOrEqual(floor, DockGridMetrics.pageIndicatorHeight)
        }
    }

    /// Collapsing My Day — or a day with less in it — is the wearer's one control over the panel's
    /// height. Restated for round 5: a shorter surface above always buys the panel height, point
    /// for point, and never costs it any.
    func testAShorterSurfaceAboveAlwaysBuysThePanelHeight() {
        for available in stride(from: CGFloat(600), through: 1000, by: 20) {
            for row in [CGFloat(48), 52, 64, 96] {
                var previous: CGFloat = 0
                // Walking the surface *down* in height: every step affords at least as much panel.
                for reserved in stride(from: CGFloat(560), through: 200, by: -20) {
                    let pages = DockGridMetrics.panelPagesHeight(availableHeight: available,
                                                                 reservedHeight: reserved,
                                                                 rowHeight: row)
                    XCTAssertGreaterThanOrEqual(
                        pages, previous,
                        "A shorter surface above cost the panel height: \(available)pt tab, "
                            + "\(reserved)pt reserved, \(row)pt row")
                    previous = pages
                }
            }
        }
    }

    // MARK: - Where the snap went (EB device round 5)

    /// P8's rule, at the edge it actually bites: the grid's **scroll viewport**. The frame no
    /// longer snaps, so the sub-row remainder sits under the tiles as empty glass — but a tile is
    /// still never sliced, because the edge that clips one is its scroll view's, and that edge
    /// lands on a row boundary.
    func testTheGridViewportShowsWholeRowsAndNeverSlicesATile() {
        for body in stride(from: CGFloat(60), through: 700, by: 10) {
            for row in [CGFloat(48), 52, 64, 96, 130] {
                let rows = DockGridMetrics.viewportRows(availableHeight: body, rowHeight: row)
                let viewport = DockGridMetrics.gridHeight(rows: rows, tileHeight: row)
                let context = "\(body)pt page body, \(row)pt row"

                XCTAssertGreaterThanOrEqual(rows, 1, "A viewport with no rows: \(context)")
                if body >= row {
                    XCTAssertLessThanOrEqual(viewport, body + 0.001,
                                             "The viewport overran the page: \(context)")
                }
                // One more row would not have fitted, so nothing of it can peek at the edge.
                let oneMore = DockGridMetrics.gridHeight(rows: rows + 1, tileHeight: row)
                XCTAssertGreaterThan(oneMore, body,
                                     "Another whole row fitted and the viewport did not show it: \(context)")
            }
        }
    }

    /// The invariant, stated as arithmetic: the height function has no page parameter, so no swipe
    /// can change the frame. Round 4's promise, and pure subtraction makes it stronger rather than
    /// weaker — there is no longer a term in the expression a page could reach.
    func testTheFrameCannotDependOnThePage() {
        let heights = DockPage.allCases.map { _ in
            DockGridMetrics.panelPagesHeight(availableHeight: 874, reservedHeight: 400,
                                             rowHeight: 52)
        }
        XCTAssertEqual(Set(heights).count, 1,
                       "Every page resolves to the same frame — the page is not an input")
    }

    /// Nor does the content: a wearer with four tiles gets the same frame as one with forty,
    /// because the conversation page shares it and a short grid must not shrink the transcript to
    /// a two-line window. The short grid's unused rows are empty glass, not a shorter panel.
    func testAShortGridKeepsTheTallFrame() {
        let tall = DockGridMetrics.panelPagesHeight(availableHeight: 874, reservedHeight: 400,
                                                    rowHeight: 52)
        XCTAssertGreaterThan(tall, DockGridMetrics.gridHeight(rows: 4, tileHeight: 52),
                             "The old four-row ceiling is still capping the panel")
        // The rows the *content* needs are a separate question, and still answerable — the grid
        // scrolls past what the viewport shows.
        XCTAssertEqual(DockGridMetrics.rowsNeeded(slotCount: 6, columns: 4), 2)
        XCTAssertEqual(DockGridMetrics.rowsNeeded(slotCount: 40, columns: 4), 10)
    }

    /// Before the first layout there is nothing measured to subtract — no screen, and no surface
    /// above. The panel opens at a sensible guess rather than at nothing, and the first real
    /// measurement settles it.
    func testAnUnmeasuredScreenFallsBackToAGuess() {
        let guess = DockGridMetrics.gridHeight(rows: DockGridMetrics.defaultRowsWithoutMeasurement,
                                               tileHeight: 52)
            + DockGridMetrics.pageIndicatorHeight
        let unmeasured: [(available: CGFloat, reserved: CGFloat?)] = [
            (0, 400),
            (0, nil),
            // The surface above has not reported yet, which is the frame the measurement added.
            (874, nil),
        ]
        for state in unmeasured {
            XCTAssertEqual(DockGridMetrics.panelPagesHeight(availableHeight: state.available,
                                                            reservedHeight: state.reserved,
                                                            rowHeight: 52),
                           guess,
                           accuracy: 0.001,
                           "\(state.available)pt tab, \(String(describing: state.reserved)) reserved")
        }
    }

    /// One curve for the whole exchange. The card grows and the panel gives way on the same motion
    /// because there is only one to be on — a second animation on the panel is what made the two
    /// surfaces look like they were moving independently.
    func testThereIsOneSettleCurveForEveryHeightChange() {
        XCTAssertEqual(DockGridMetrics.heightSettle, .easeInOut(duration: 0.25))
    }

    /// The rhythm is one number, and the dock is part of it rather than a surface with its own.
    func testTheModuleGapIsTheOneRhythm() {
        XCTAssertEqual(DockGridMetrics.moduleGap, 16)
        // Below the capsule is the tab bar, not another module — deliberately not the module gap.
        XCTAssertNotEqual(DockGridMetrics.dockBottomPadding, DockGridMetrics.moduleGap)
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
