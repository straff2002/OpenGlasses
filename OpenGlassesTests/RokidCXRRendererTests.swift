import XCTest
@testable import OpenGlasses

/// Covers the CXR-M display mapping: the documented overlay is text-only, so these tests pin
/// the flattening, the line budget and the wrapping rather than any device behaviour.
final class RokidCXRRendererTests: XCTestCase {

    // MARK: - Helpers

    /// The overlay text carried by a `WordTips_AiContent` command.
    private func asrText(_ command: RokidCXRCommand) -> String? {
        guard case .string(let payload)? = command.arguments.first,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return object["asr"]
    }

    // MARK: - Content

    func testContentRendersAsOneOverlayPush() {
        let commands = RokidCXRRenderer.renderContent(title: "Title", body: "Body text", icon: .info)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.channel, .sys)
        XCTAssertEqual(commands.first?.command, "WordTips_AiContent")

        let text = asrText(commands[0]) ?? ""
        XCTAssertTrue(text.contains("Title"))
        XCTAssertTrue(text.contains("Body text"))
    }

    func testClearPushesAnEmptyCaption() {
        let commands = RokidCXRRenderer.clearCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(asrText(commands[0]), "")
    }

    // MARK: - Screens

    func testScreenFlattensTitleLinesAndNumberedItems() {
        let screen = HUDScreen(
            title: "Menu",
            lines: [HUDLine("Line one"), HUDLine("Line two")],
            items: [
                HUDItem(id: "a", label: "First", action: {}),
                HUDItem(id: "b", label: "Second", action: {}),
            ]
        )
        let text = asrText(RokidCXRRenderer.renderScreen(screen)[0]) ?? ""
        XCTAssertTrue(text.contains("Menu"))
        XCTAssertTrue(text.contains("Line one"))
        XCTAssertTrue(text.contains("Line two"))
        XCTAssertTrue(text.contains("1. First"))
        XCTAssertTrue(text.contains("2. Second"))
    }

    func testCaptionIsCappedToTheLineBudget() {
        let body = (1...40).map { "word\($0)" }.joined(separator: " ")
        let caption = RokidCXRRenderer.caption(title: nil, body: body)
        XCTAssertLessThanOrEqual(caption.split(separator: "\n").count, RokidCXRRenderer.maxLines)
    }

    func testEmptyInputProducesAnEmptyCaption() {
        XCTAssertEqual(RokidCXRRenderer.caption(title: nil, body: ""), "")
        XCTAssertEqual(RokidCXRRenderer.caption(title: "", body: ""), "")
    }

    // MARK: - Wrapping

    func testWrappingRespectsTheCharacterBudgetAndKeepsEveryWord() {
        let body = "the quick brown fox jumps over the lazy dog and keeps on running for a while"
        let lines = RokidCXRRenderer.wrap(body)
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, RokidCXRRenderer.charBudget, "line too long: \(line)")
        }
        XCTAssertEqual(lines.joined(separator: " "), body)
    }

    func testAnOverlongWordIsBrokenRatherThanDropped() {
        let word = String(repeating: "x", count: RokidCXRRenderer.charBudget + 6)
        let lines = RokidCXRRenderer.wrap(word)
        XCTAssertEqual(lines.joined(), word)
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, RokidCXRRenderer.charBudget)
        }
    }
}
