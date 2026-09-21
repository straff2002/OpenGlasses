import XCTest
@testable import OpenGlasses

/// Tests for the root tab bar's typed identifier. All pure — no view is built, no app state is
/// touched; what is asserted is the identity contract that lets a tab be inserted later without
/// moving an existing one.
final class MainTabTests: XCTestCase {

    // MARK: - Raw values are the identity

    /// The raw values are a wire format: the privacy log records them, and a persisted or
    /// transmitted selection would carry them. Spelled out here so a rename has to be deliberate.
    func testRawValuesAreStable() {
        XCTAssertEqual(MainTab.voice.rawValue, "voice")
        XCTAssertEqual(MainTab.modes.rawValue, "modes")
        XCTAssertEqual(MainTab.chat.rawValue, "chat")
        XCTAssertEqual(MainTab.job.rawValue, "job")
        XCTAssertEqual(MainTab.settings.rawValue, "settings")
    }

    func testRawValuesAreUnique() {
        let raws = MainTab.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    func testRawValueRoundTrips() {
        for tab in MainTab.allCases {
            XCTAssertEqual(MainTab(rawValue: tab.rawValue), tab)
        }
        // "job" was the stand-in for an identifier no tab had, until FO P2 made it one. The
        // assertion is the same — an unknown identifier resolves to nothing — on a token that is
        // still unknown.
        XCTAssertNil(MainTab(rawValue: "jobs"), "an unknown identifier must not resolve to a tab")
        XCTAssertNil(MainTab(rawValue: "Job"), "the raw values are case-sensitive")
    }

    func testIdentifierIsTheRawValue() {
        for tab in MainTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
        }
    }

    // MARK: - Order

    /// `displayOrder` is what `MainView` builds its tabs from, so it has to name every tab exactly
    /// once. A tab added without a place in the bar would otherwise simply not appear.
    func testDisplayOrderCoversEveryTabExactlyOnce() {
        XCTAssertEqual(Set(MainTab.displayOrder), Set(MainTab.allCases))
        XCTAssertEqual(MainTab.displayOrder.count, MainTab.allCases.count)
    }

    func testDisplayOrderPutsTheJobTabBetweenChatAndSettings() {
        XCTAssertEqual(MainTab.displayOrder, [.voice, .modes, .chat, .job, .settings])
    }

    /// The bar as everybody without Field Assist sees it: the four tabs that shipped, in the order
    /// they shipped in. Inserting `.job` must not have moved any of them relative to each other.
    func testWithoutTheJobTabTheBarIsExactlyWhatItAlwaysWas() {
        XCTAssertEqual(MainTab.visibleOrder(showingJob: false), [.voice, .modes, .chat, .settings])
    }

    func testWithTheJobTabTheOtherFourKeepTheirOrder() {
        let withJob = MainTab.visibleOrder(showingJob: true).filter { $0 != .job }
        XCTAssertEqual(withJob, MainTab.visibleOrder(showingJob: false))
    }

    /// Whatever the bar is, it is a prefix-preserving subsequence of the full order — no tab can be
    /// drawn twice and none can jump position.
    func testVisibleOrderIsAlwaysASubsequenceOfDisplayOrder() {
        for showingJob in [true, false] {
            let visible = MainTab.visibleOrder(showingJob: showingJob)
            XCTAssertEqual(Set(visible).count, visible.count)
            XCTAssertEqual(visible, MainTab.displayOrder.filter { visible.contains($0) })
        }
    }

    // MARK: - What the bar says

    func testEveryTabHasATitleAndASymbol() {
        for tab in MainTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab) has no name to read out")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) has no symbol")
        }
        XCTAssertEqual(MainTab.job.title, "Job")
    }

    func testTitlesAreDistinct() {
        let titles = MainTab.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count,
                       "two tabs with the same spoken name cannot be told apart by VoiceOver or a UI test")
    }

    // MARK: - Legacy Int selections

    func testLegacyIntsMapToTheTabsTheyNamed() {
        XCTAssertEqual(MainTab.legacy(0), .voice)
        XCTAssertEqual(MainTab.legacy(1), .modes)
        XCTAssertEqual(MainTab.legacy(2), .chat)
        XCTAssertEqual(MainTab.legacy(3), .settings)
    }

    func testLegacyRejectsNumbersThatNeverNamedATab() {
        XCTAssertNil(MainTab.legacy(-1))
        XCTAssertNil(MainTab.legacy(4))
        XCTAssertNil(MainTab.legacy(Int.max))
    }

    func testLegacyMappingRoundTripsBothWays() {
        for tab in MainTab.allCases {
            guard let value = tab.legacyValue else { continue }
            XCTAssertEqual(MainTab.legacy(value), tab)
        }
        for value in 0...3 {
            XCTAssertEqual(MainTab.legacy(value)?.legacyValue, value)
        }
    }

    /// The four tabs that shipped with numbers kept them, and the numbers are still distinct. A tab
    /// added later is expected to answer `nil` — this asserts the shipped four, so adding one
    /// cannot quietly renumber them.
    func testShippedTabsKeepTheirLegacyNumbers() {
        XCTAssertEqual(MainTab.voice.legacyValue, 0)
        XCTAssertEqual(MainTab.modes.legacyValue, 1)
        XCTAssertEqual(MainTab.chat.legacyValue, 2)
        XCTAssertEqual(MainTab.settings.legacyValue, 3)

        let numbered = MainTab.allCases.compactMap(\.legacyValue)
        XCTAssertEqual(Set(numbered).count, numbered.count)
    }

    /// The table is closed. A tab added after the identifier was typed has no legacy number, and
    /// giving it one would have to renumber Settings — the exact rewrite freezing the table
    /// prevents.
    func testTheJobTabHasNoLegacyNumber() {
        XCTAssertNil(MainTab.job.legacyValue)
        XCTAssertFalse((0...3).contains { MainTab.legacy($0) == .job })
        XCTAssertNil(MainTab.legacy(4))
    }
}
