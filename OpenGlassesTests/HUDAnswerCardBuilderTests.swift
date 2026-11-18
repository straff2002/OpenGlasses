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

    func testTheFirstPageHasNextAndActions() throws {
        let pages = paged
        XCTAssertGreaterThan(pages.count, 2)
        let screen = HUDAnswerCardBuilder.page(pages, index: 0, followUps: followUps) { _ in }
        XCTAssertEqual(ids(screen), [ID.next, ID.actions])
        XCTAssertEqual(labels(screen), ["Next ›", "Actions"])
        XCTAssertEqual(screen?.items.first?.style, .primary)
    }

    /// P1: a middle page has ‹ Back as well, so the band alone can go back a page.
    func testAMiddlePageHasNextActionsAndBack() throws {
        let pages = paged
        XCTAssertGreaterThan(pages.count, 2)
        for index in 1..<(pages.count - 1) {
            let screen = HUDAnswerCardBuilder.page(pages, index: index, followUps: followUps) { _ in }
            XCTAssertEqual(ids(screen), [ID.next, ID.actions, ID.back], "page \(index)")
            XCTAssertEqual(labels(screen), ["Next ›", "Actions", "‹ Back"])
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
        XCTAssertEqual(ids(screen), [ID.more, ID.repeatAnswer, ID.save, ID.send, ID.answer, ID.close])
        XCTAssertEqual(labels(screen), ["More", "Repeat", "Save", "Send", "‹ Answer", "Close"])
    }

    func testAThirdFollowUpShowsOnTheActionsScreen() {
        let screen = HUDAnswerCardBuilder.actions(paged, followUps: followUps + ["A fourth one?"]) { _ in }
        XCTAssertEqual(ids(screen), [ID.followUp(2), ID.more, ID.repeatAnswer, ID.save, ID.send,
                                     ID.answer, ID.close])
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
                                 .more, .repeatAnswer, .save, .send, .answer, .close])
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
        XCTAssertEqual(ID.answer, "kp.answer")
        XCTAssertEqual(ID.followUp(1), "kp.followup.1")
    }

    func testTheRenderKeyChangesWithThePage() throws {
        let pages = paged
        let one = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: []) { _ in })
        let two = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 1, followUps: []) { _ in })
        XCTAssertNotEqual(one.renderKey, two.renderKey)
    }

    // MARK: - Page on the last page (Plan MG §5)

    private let allFollowUps = ["How long does it take?", "What tools do I need?", "Is it safe?"]
    private let actionsTail = [ID.more, ID.repeatAnswer, ID.save, ID.send, ID.answer, ID.close]

    /// With a page to show, the last page is the first follow-up (if any) · Page · Actions · ‹ Back
    /// (paged only): Page takes the second follow-up's place.
    func testWithAPageThePageGoesOnTheLastPageInTheSecondFollowUpsPlace() throws {
        for (name, pages) in [("paged", paged), ("single", single)] {
            let back = pages.count > 1 ? [ID.back] : []
            let expected: [[String]] = [
                [ID.page, ID.actions] + back,                              // no follow-ups
                [ID.followUp(0), ID.page, ID.actions] + back,              // one
                [ID.followUp(0), ID.page, ID.actions] + back,              // two
                [ID.followUp(0), ID.page, ID.actions] + back,              // three
            ]
            for count in 0...3 {
                let screen = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: pages.count - 1,
                                                                     followUps: Array(allFollowUps.prefix(count)),
                                                                     hasPage: true) { _ in })
                XCTAssertEqual(ids(screen), expected[count], "\(name), \(count) follow-ups")
                XCTAssertLessThanOrEqual(screen.items.count, 4, "four buttons at most")
                let page = try XCTUnwrap(screen.items.first { $0.id == ID.page })
                XCTAssertEqual(page.label, "Page")
                XCTAssertEqual(page.style, .secondary)
            }
        }
    }

    /// Without a page, the last page is as before: up to two follow-ups · Actions · ‹ Back.
    func testWithoutAPageTheLastPageIsUnchanged() throws {
        for (name, pages) in [("paged", paged), ("single", single)] {
            let back = pages.count > 1 ? [ID.back] : []
            let expected: [[String]] = [
                [ID.actions] + back,
                [ID.followUp(0), ID.actions] + back,
                [ID.followUp(0), ID.followUp(1), ID.actions] + back,
                [ID.followUp(0), ID.followUp(1), ID.actions] + back,
            ]
            for count in 0...3 {
                let follow = Array(allFollowUps.prefix(count))
                let screen = HUDAnswerCardBuilder.page(pages, index: pages.count - 1, followUps: follow) { _ in }
                XCTAssertEqual(ids(screen), expected[count], "\(name), \(count) follow-ups")
                XCTAssertEqual(ids(screen), ids(HUDAnswerCardBuilder.page(pages, index: pages.count - 1,
                                                                          followUps: follow, hasPage: false) { _ in }))
                XCTAssertLessThanOrEqual(screen?.items.count ?? 0, 4, "four buttons at most")
            }
        }
    }

    /// Page never goes on a page before the last.
    func testPageIsOnlyOnTheLastPage() {
        let pages = paged
        for index in 0..<(pages.count - 1) {
            let screen = HUDAnswerCardBuilder.page(pages, index: index, followUps: allFollowUps, hasPage: true) { _ in }
            XCTAssertFalse(ids(screen).contains(ID.page), "page \(index)")
        }
    }

    /// The Actions screen: with a page, the follow-ups the last page has no room for (the second and
    /// the third) and no Page; without one, the third alone, as before. Page is never on it.
    func testTheActionsScreenWithAndWithoutAPage() {
        let withPage: [[String]] = [
            actionsTail,
            actionsTail,
            [ID.followUp(1)] + actionsTail,
            [ID.followUp(1), ID.followUp(2)] + actionsTail,
        ]
        let withoutPage: [[String]] = [
            actionsTail,
            actionsTail,
            actionsTail,
            [ID.followUp(2)] + actionsTail,
        ]
        for count in 0...3 {
            let follow = Array(allFollowUps.prefix(count))
            let on = HUDAnswerCardBuilder.actions(paged, followUps: follow, hasPage: true) { _ in }
            XCTAssertEqual(ids(on), withPage[count], "with a page, \(count) follow-ups")
            XCTAssertEqual(labels(on).prefix(max(0, count - 1)), ArraySlice(follow.dropFirst()))
            let off = HUDAnswerCardBuilder.actions(paged, followUps: follow) { _ in }
            XCTAssertEqual(ids(off), withoutPage[count], "without a page, \(count) follow-ups")
        }
    }

    /// Every follow-up stays reachable exactly once, with or without a page.
    func testEveryFollowUpIsOfferedOnceWithAPage() throws {
        var presses: [HUDAnswerAction] = []
        let last = try XCTUnwrap(HUDAnswerCardBuilder.page(paged, index: paged.count - 1, followUps: allFollowUps,
                                                           hasPage: true) { presses.append($0) })
        let actions = HUDAnswerCardBuilder.actions(paged, followUps: allFollowUps, hasPage: true) { presses.append($0) }
        for item in last.items + actions.items { item.action() }
        let followUps = presses.compactMap { action -> Int? in
            if case .followUp(let index, let text) = action {
                XCTAssertEqual(text, allFollowUps[index])
                return index
            }
            return nil
        }
        XCTAssertEqual(followUps, [0, 1, 2])
        XCTAssertEqual(presses.filter { $0 == .page }.count, 1)
    }
}
