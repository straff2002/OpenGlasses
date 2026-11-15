import XCTest
@testable import OpenGlasses

/// Plan LU P1b — the Live Activity while a private conversation is open says "Private conversation"
/// in the reply's place, and no reply text reaches the extension any other way.
final class PrivateLiveActivityTests: XCTestCase {

    override func tearDown() {
        PrivateConversationGate.setActive(false)
        super.tearDown()
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheSnippetIsThePlaceholderWhilePrivate() {
        PrivateConversationGate.setActive(true)
        for reply in ["See a GP about the mole if it has changed shape.",
                      String(repeating: "private words ", count: 30), ""] {
            let snippet = LiveActivityManager.snippet(
                reply, placeholder: PrivateConversationGate.placeholder(for: .liveActivitySnippet))
            XCTAssertEqual(snippet, PrivateConversationPolicy.placeholderText)
        }
    }

    func testTheSnippetIsTheReplyOtherwise() {
        let reply = "It closes at 5:30."
        XCTAssertEqual(LiveActivityManager.snippet(
            reply, placeholder: PrivateConversationGate.placeholder(for: .liveActivitySnippet)), reply)
    }

    /// The content state's one text field is the snippet, and only `update` fills it with anything
    /// but an empty string — so the placeholder is the only reply-shaped text the extension can get.
    func testOnlyTheSnippetReachesTheContentState() throws {
        let manager = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("OpenGlasses/Sources/Services/LiveActivityManager.swift"), encoding: .utf8)
        let assignments = manager.components(separatedBy: "lastResponseSnippet:").dropFirst()
            .map { $0.prefix(while: { $0 != "," && $0 != "\n" }).trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(assignments.isEmpty)
        XCTAssertEqual(Set(assignments), ["snippet", "\"\""],
                       "the content state is filled from the private-aware snippet or left empty")
    }

    /// The extension draws the snippet and nothing else of the reply; it reads no shared reply
    /// text of its own (the App Group, a file) that could carry a private answer.
    func testTheExtensionDrawsOnlyTheSnippet() throws {
        let dir = Self.repoRoot.appendingPathComponent("GlassesActivityWidget")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let mentions = source.components(separatedBy: "lastResponse").count - 1
            let snippetMentions = source.components(separatedBy: "lastResponseSnippet").count - 1
            XCTAssertEqual(mentions, snippetMentions,
                           "\(file.lastPathComponent) reads a reply other than the snippet")
        }
    }
}
