import XCTest
@testable import OpenGlasses

/// Tests for the Siri Shortcuts catalog (Plan Z). The `INVoiceShortcutCenter` fetch
/// can't run headlessly, so the device-independent logic — normalize + prompt-block
/// formatting + persistence — is factored into pure static helpers and tested here.
final class ShortcutsCatalogTests: XCTestCase {
    private typealias Entry = ShortcutsCatalog.Entry

    func testNormalizeSortsAndDedupesCaseInsensitively() {
        let raw = [
            Entry(phrase: "Start Focus", title: "Focus"),
            Entry(phrase: "log water", title: "Water"),
            Entry(phrase: "LOG WATER", title: "Water dup"),   // case-insensitive duplicate
            Entry(phrase: "Arrive Home", title: "Home"),
        ]
        let out = ShortcutsCatalog.normalize(raw, max: 10)
        XCTAssertEqual(out.count, 3)   // duplicate collapsed
        XCTAssertEqual(out.map { $0.phrase.lowercased() }, ["arrive home", "log water", "start focus"])
    }

    func testNormalizeCapsAtMax() {
        let raw = (1...30).map { Entry(phrase: "p\($0)", title: "t\($0)") }
        XCTAssertEqual(ShortcutsCatalog.normalize(raw, max: 25).count, 25)
    }

    func testPromptBlockFormatsAndIncludesCaveat() throws {
        let entries = [Entry(phrase: "log water", title: "Log Water"),
                       Entry(phrase: "start focus", title: "Start Focus")]
        let block = try XCTUnwrap(ShortcutsCatalog.promptBlock(for: entries))
        XCTAssertTrue(block.contains("- \"log water\" → Log Water"))
        XCTAssertTrue(block.contains("- \"start focus\" → Start Focus"))
        XCTAssertTrue(block.contains("run_shortcut"))                       // tells the model how to use them
        XCTAssertTrue(block.lowercased().contains("more shortcuts"))        // the iOS-limit caveat
    }

    func testPromptBlockNilWhenEmpty() {
        XCTAssertNil(ShortcutsCatalog.promptBlock(for: []))
    }

    func testPromptBlockRespectsMax() throws {
        let entries = (1...10).map { Entry(phrase: "p\($0)", title: "t\($0)") }
        let block = try XCTUnwrap(ShortcutsCatalog.promptBlock(for: entries, max: 3))
        let bullets = block.split(separator: "\n").filter { $0.hasPrefix("- \"") }
        XCTAssertEqual(bullets.count, 3)
    }

    func testEntryCodableRoundTrips() throws {
        let entries = [Entry(phrase: "a", title: "A"), Entry(phrase: "b", title: "B")]
        let decoded = try JSONDecoder().decode([Entry].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(decoded, entries)
    }
}
