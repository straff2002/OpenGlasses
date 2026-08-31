import XCTest
@testable import OpenGlasses

/// The dock panel's pager: when it flips itself, when it refuses to, and what an edit means.
///
/// "The panel moved on its own while I was reading it" is miserable to reproduce by hand and
/// trivial to state as a table, which is the whole reason the policy is a pure type.
final class DockPagerTests: XCTestCase {

    private let states: [VoiceVisualState] = [.idle, .listening, .thinking, .speaking]

    // MARK: - The table

    /// Every transition, and what the pager does with it from its resting page.
    ///
    /// | from      | to        | flips to conversation? |
    /// |-----------|-----------|------------------------|
    /// | idle      | thinking  | yes — the turn started |
    /// | listening | thinking  | yes — the turn started |
    /// | thinking  | speaking  | yes — the reply arrived|
    /// | idle      | listening | no  — the mic opening is not a turn |
    /// | speaking  | idle      | no  — and it does not flip *back*, either |
    /// | thinking  | thinking  | no  — a level, not an edge |
    func testTheAutoFlipTable() {
        func flips(_ from: VoiceVisualState, _ to: VoiceVisualState) -> Bool {
            DockPagerPolicy.advance(DockPagerState(), from: from, to: to).page == .conversation
        }

        XCTAssertTrue(flips(.idle, .thinking))
        XCTAssertTrue(flips(.listening, .thinking))
        XCTAssertTrue(flips(.thinking, .speaking))

        XCTAssertFalse(flips(.idle, .listening))
        XCTAssertFalse(flips(.listening, .idle))
        XCTAssertFalse(flips(.speaking, .idle))
        XCTAssertFalse(flips(.thinking, .thinking))
        XCTAssertFalse(flips(.idle, .idle))
    }

    /// The grid is home. Nothing about a turn ending brings the panel back to it — the reply stays
    /// readable until the wearer swipes away or the next turn arrives. There is no idle timer on
    /// purpose: a panel that slides out from under someone still reading is the same failure as one
    /// that fights their swipe, only on a delay.
    func testATurnEndingLeavesTheConversationOnScreen() {
        var state = DockPagerState()
        state = DockPagerPolicy.advance(state, from: .idle, to: .thinking)
        state = DockPagerPolicy.advance(state, from: .thinking, to: .speaking)
        XCTAssertEqual(state.page, .conversation)

        state = DockPagerPolicy.advance(state, from: .speaking, to: .idle)
        XCTAssertEqual(state.page, .conversation, "The reply was taken away when the turn ended")
    }

    // MARK: - Never fight the user

    /// The rule with teeth. A swipe back to the grid mid-response has to mean something, or the
    /// panel is arguing with the hand that moved it.
    func testASwipeDuringATurnIsNotOverruledByThatTurn() {
        var state = DockPagerPolicy.advance(DockPagerState(), from: .idle, to: .thinking)
        XCTAssertEqual(state.page, .conversation)

        state = DockPagerPolicy.userMoved(state, to: .actions)
        XCTAssertTrue(state.userMovedThisTurn)

        // The reply arriving would normally flip. It does not, because this turn was already
        // decided by a finger.
        state = DockPagerPolicy.advance(state, from: .thinking, to: .speaking)
        XCTAssertEqual(state.page, .actions)
    }

    /// A *new* turn is new news, and earns the flip back.
    func testTheNextTurnFlipsAgain() {
        var state = DockPagerPolicy.advance(DockPagerState(), from: .idle, to: .thinking)
        state = DockPagerPolicy.userMoved(state, to: .actions)
        state = DockPagerPolicy.advance(state, from: .speaking, to: .idle)
        XCTAssertEqual(state.page, .actions)

        state = DockPagerPolicy.advance(state, from: .idle, to: .thinking)
        XCTAssertEqual(state.page, .conversation)
        XCTAssertFalse(state.userMovedThisTurn, "A new turn did not clear the override")
    }

    /// The same promise for the edit page: a wearer who went to arrange their tiles is not dragged
    /// out of it by their own last question finishing.
    func testTheEditPageIsNotYankedAwayEither() {
        var state = DockPagerPolicy.advance(DockPagerState(), from: .idle, to: .thinking)
        state = DockPagerPolicy.userMoved(state, to: .edit)
        state = DockPagerPolicy.advance(state, from: .thinking, to: .speaking)
        XCTAssertEqual(state.page, .edit)
    }

    // MARK: - Shape

    func testTheGridIsHomeAndSitsBetweenTheOtherTwo() {
        XCTAssertEqual(DockPage.home, .actions)
        XCTAssertEqual(DockPage.allCases, [.conversation, .actions, .edit])
        // Order is the swipe order, so home being the middle raw value is what makes the
        // conversation and the editor one gesture away each.
        XCTAssertEqual(DockPage.actions.rawValue, 1)
    }

    func testEveryPageIsNamedForVoiceOver() {
        for page in DockPage.allCases {
            XCTAssertFalse(page.showActionName.isEmpty, "\(page) has no named action")
            XCTAssertFalse(page.spokenName.isEmpty, "\(page) is not announced")
        }
        XCTAssertEqual(Set(DockPage.allCases.map(\.showActionName)).count, DockPage.allCases.count)
    }

    func testTurnActivityIsThinkingAndSpeakingOnly() {
        for state in states {
            XCTAssertEqual(DockPagerPolicy.isTurnActive(state),
                           state == .thinking || state == .speaking)
        }
    }

    // MARK: - Editing, wherever it is driven from

    private let controls = DockLayout.canonical
    private let speedDial = [
        QuickAction(id: "describe", label: "Describe", icon: "eye", type: .photoThenPrompt,
                    promptText: "Describe what you see."),
    ]

    private var resolved: [DockSlot] {
        DockGridCatalog.slots(arrangement: .default, controlOrder: controls,
                              quickActions: speedDial, showsActions: true)
    }

    /// The in-panel page nudges with buttons and the full editor drags; both mean the same thing,
    /// because both call this.
    func testNudgingMovesOneSlotAndClampsAtTheEnds() {
        let slots = resolved
        let first = slots[0].id
        let second = slots[1].id

        let down = DockArrangementEditor.moving(.default, resolved: slots, id: first, by: 1)
        XCTAssertEqual(Array(down.order.prefix(2)), [second, first])

        // Already at the top: a no-op, not a wrap to the bottom.
        let up = DockArrangementEditor.moving(.default, resolved: slots, id: first, by: -1)
        XCTAssertEqual(up.order, slots.map(\.id))

        let last = slots[slots.count - 1].id
        let past = DockArrangementEditor.moving(.default, resolved: slots, id: last, by: 1)
        XCTAssertEqual(past.order.last, last)
    }

    func testDraggingAndNudgingAgreeOnTheResult() {
        let slots = resolved
        let dragged = DockArrangementEditor.moving(.default, resolved: slots,
                                                   fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let nudged = DockArrangementEditor.moving(.default, resolved: slots,
                                                  id: slots[0].id, by: 1)
        XCTAssertEqual(dragged.order, nudged.order)
    }

    /// The rule that cannot live in one list's gesture configuration: a control is not something a
    /// wearer can strip off their own dock, whichever surface asks.
    func testRemovingRefusesControlsFromEitherSurface() {
        let slots = resolved
        guard let control = slots.first(where: { !$0.isHideable })?.id,
              let action = slots.first(where: \.isHideable)?.id else {
            return XCTFail("The fixture has no control and action to tell apart")
        }

        let after = DockArrangementEditor.removing(.default, resolved: slots,
                                                   ids: [control, action])
        XCTAssertTrue(after.order.contains(control))
        XCTAssertFalse(after.order.contains(action))
        XCTAssertEqual(after.hidden, [action])
    }

    func testAddingPutsASlotBackAndUnhidesIt() {
        let slots = resolved
        guard let action = slots.first(where: \.isHideable)?.id else {
            return XCTFail("The fixture has no removable action")
        }
        let removed = DockArrangementEditor.removing(.default, resolved: slots, ids: [action])

        let remaining = DockGridCatalog.slots(arrangement: removed, controlOrder: controls,
                                              quickActions: speedDial, showsActions: true)
        let restored = DockArrangementEditor.adding(removed, resolved: remaining, id: action)
        XCTAssertTrue(restored.order.contains(action))
        XCTAssertFalse(restored.hidden.contains(action))
    }
}
