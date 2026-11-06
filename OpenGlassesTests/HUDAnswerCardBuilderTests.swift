import XCTest
@testable import OpenGlasses

/// Plan KP P0 — the answer card's screens and buttons (§3).
final class HUDAnswerCardBuilderTests: XCTestCase {

    private typealias ID = HUDAnswerCardBuilder.ItemID

    private let longAnswer = """
    Turn the isolator off before you open the panel. Check the capacitor with a meter, \
    because it can hold a charge for minutes after the power is cut. If the reading is above \
    five volts, discharge it with an insulated resistor. Then swap the contactor, refit the \
    cover and restore the power.
    """

    private var paged: [HUDAnswerPage] {
        HUDAnswerPager.pages(for: longAnswer, geometry: .raybanDisplay)
    }

    private var single: [HUDAnswerPage] {
        HUDAnswerPager.pages(for: "The filter is behind the front grille.", geometry: .raybanDisplay)
    }

    private let followUps = ["How long does it take?", "What tools do I need?", "Is it safe?"]

    private func ids(_ screen: HUDScreen?) -> [String] { screen?.items.map(\.id) ?? [] }
    private func labels(_ screen: HUDScreen?) -> [String] { screen?.items.map(\.label) ?? [] }

    // MARK: - Pages

    func testANotLastPageHasNextAndActions() throws {
        let pages = paged
        XCTAssertGreaterThan(pages.count, 2)
        for index in 0..<(pages.count - 1) {
            let screen = HUDAnswerCardBuilder.page(pages, index: index, followUps: followUps) { _ in }
            XCTAssertEqual(ids(screen), [ID.next, ID.actions], "page \(index)")
            XCTAssertEqual(labels(screen), ["Next ›", "Actions"])
            XCTAssertEqual(screen?.items.first?.style, .primary)
        }
    }

    func testANotLastPageShowsItsLinesAndFooter() throws {
        let pages = paged
        let screen = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: []) { _ in })
        XCTAssertNil(screen.title)
        XCTAssertEqual(screen.lines.map(\.text), pages[0].lines + ["1/\(pages.count)"])
        XCTAssertEqual(screen.lines.last?.emphasis, .meta)
        XCTAssertTrue(screen.lines.dropLast().allSatisfy { $0.emphasis == .primary })
    }

    func testFollowUpsShowOnlyOnTheLastPage() {
        let pages = paged
        for index in 0..<(pages.count - 1) {
            let screen = HUDAnswerCardBuilder.page(pages, index: index, followUps: followUps) { _ in }
            XCTAssertFalse(ids(screen).contains { $0.hasPrefix("kp.followup") }, "page \(index)")
        }
    }

    func testThePagedLastPageHasTwoFollowUpsActionsAndBack() throws {
        let pages = paged
        let screen = try XCTUnwrap(
            HUDAnswerCardBuilder.page(pages, index: pages.count - 1, followUps: followUps) { _ in })
        XCTAssertEqual(ids(screen), [ID.followUp(0), ID.followUp(1), ID.actions, ID.back])
        XCTAssertEqual(labels(screen), [followUps[0], followUps[1], "Actions", "‹ Back"])
        XCTAssertEqual(screen.lines.last?.text, "\(pages.count)/\(pages.count)")
    }

    func testAnOnlyPageHasNoBackAndNoFooter() throws {
        let pages = single
        XCTAssertEqual(pages.count, 1)
        let screen = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: followUps) { _ in })
        XCTAssertEqual(ids(screen), [ID.followUp(0), ID.followUp(1), ID.actions])
        XCTAssertFalse(ids(screen).contains(ID.back))
        // Today's single body line, nothing else.
        XCTAssertEqual(screen.lines.map(\.text), ["The filter is behind the front grille."])
        XCTAssertEqual(screen.lines.first?.emphasis, .primary)
    }

    func testAnOnlyPageWithoutFollowUpsHasJustActions() {
        let screen = HUDAnswerCardBuilder.page(single, index: 0, followUps: []) { _ in }
        XCTAssertEqual(ids(screen), [ID.actions])
    }

    func testOneFollowUpShowsOne() {
        let screen = HUDAnswerCardBuilder.page(single, index: 0, followUps: ["Why?"]) { _ in }
        XCTAssertEqual(ids(screen), [ID.followUp(0), ID.actions])
    }

    func testACappedLastPageMarksTheMoreLine() throws {
        let text = (1...200).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let pages = HUDAnswerPager.pages(for: text, geometry: .raybanDisplay)
        let screen = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 7, followUps: []) { _ in })
        let moreLine = screen.lines[screen.lines.count - 2]
        XCTAssertEqual(moreLine.text, HUDAnswerPager.moreOnPhoneLine)
        XCTAssertEqual(moreLine.emphasis, .secondary)
        XCTAssertEqual(screen.lines.last?.text, "8/8")
    }

    func testIndexIsClampedAndNoPagesGiveNoScreen() {
        XCTAssertNil(HUDAnswerCardBuilder.page([], index: 0, followUps: []) { _ in })
        let pages = paged
        let past = HUDAnswerCardBuilder.page(pages, index: 99, followUps: []) { _ in }
        XCTAssertEqual(ids(past), [ID.actions, ID.back])
        let before = HUDAnswerCardBuilder.page(pages, index: -3, followUps: []) { _ in }
        XCTAssertEqual(ids(before), [ID.next, ID.actions])
    }

    // MARK: - Actions screen

    func testTheActionsScreen() throws {
        let pages = paged
        let screen = HUDAnswerCardBuilder.actions(pages, followUps: Array(followUps.prefix(2))) { _ in }
        XCTAssertNil(screen.title)
        XCTAssertEqual(screen.lines.map(\.text), [pages[0].lines[0]])
        XCTAssertEqual(screen.lines.first?.emphasis, .secondary)
        XCTAssertEqual(ids(screen), [ID.more, ID.repeatAnswer, ID.save, ID.send, ID.close])
        XCTAssertEqual(labels(screen), ["More", "Repeat", "Save", "Send", "Close"])
    }

    func testAThirdFollowUpShowsOnTheActionsScreen() {
        let screen = HUDAnswerCardBuilder.actions(paged, followUps: followUps + ["A fourth one?"]) { _ in }
        XCTAssertEqual(ids(screen), [ID.followUp(2), ID.more, ID.repeatAnswer, ID.save, ID.send, ID.close])
        XCTAssertEqual(screen.items.first?.label, followUps[2])
    }

    func testTheActionsScreenForASinglePageUsesItsFirstLine() {
        let screen = HUDAnswerCardBuilder.actions(single, followUps: []) { _ in }
        XCTAssertEqual(screen.lines.map(\.text), [single[0].lines[0]])
    }

    // MARK: - Presses

    func testEveryPressReportsItsAction() throws {
        var pressed: [HUDAnswerAction] = []
        let record: (HUDAnswerAction) -> Void = { pressed.append($0) }
        let pages = paged

        let first = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: followUps, onAction: record))
        first.items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.next, .actions])

        pressed = []
        let last = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: pages.count - 1,
                                                            followUps: followUps, onAction: record))
        last.items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.followUp(index: 0, text: followUps[0]),
                                 .followUp(index: 1, text: followUps[1]),
                                 .actions, .back])

        pressed = []
        let actions = HUDAnswerCardBuilder.actions(pages, followUps: followUps, onAction: record)
        actions.items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.followUp(index: 2, text: followUps[2]),
                                 .more, .repeatAnswer, .save, .send, .close])
    }

    func testItemIdsAreStableAndUnique() {
        let pages = paged
        let all = ids(HUDAnswerCardBuilder.page(pages, index: pages.count - 1, followUps: followUps) { _ in })
            + ids(HUDAnswerCardBuilder.actions(pages, followUps: followUps) { _ in })
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(ID.next, "kp.next")
        XCTAssertEqual(ID.back, "kp.back")
        XCTAssertEqual(ID.actions, "kp.actions")
        XCTAssertEqual(ID.more, "kp.more")
        XCTAssertEqual(ID.repeatAnswer, "kp.repeat")
        XCTAssertEqual(ID.save, "kp.save")
        XCTAssertEqual(ID.send, "kp.send")
        XCTAssertEqual(ID.close, "kp.close")
        XCTAssertEqual(ID.followUp(1), "kp.followup.1")
    }

    func testTheRenderKeyChangesWithThePage() throws {
        let pages = paged
        let one = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: []) { _ in })
        let two = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 1, followUps: []) { _ in })
        XCTAssertNotEqual(one.renderKey, two.renderKey)
    }
}
