import XCTest
@testable import OpenGlasses

/// Plan KP §7 — a kept caption session never goes to a model, to memory or to `BrainStore` unless
/// the wearer asks for it. There is no ingest hook, and this scrape holds that: only the caption
/// session files, the caption service that hands a stopped session over, its settings screen,
/// the app's wiring and the registry and erasure walk may name the store or the session type.
/// Anything that wanted to feed one to a prompt, the memory, search or Spotlight would have to
/// name it, and is not on this list.
///
/// Scrapes read code with comments and string literals removed, in the style of
/// `AssistingIsolationTests`.
final class CaptionSessionIsolationTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var sourcesRoot: URL { repoRoot.appendingPathComponent("OpenGlasses/Sources") }

    private static let allowed: Set<String> = [
        "Services/CaptionSessions/CaptionSession.swift",
        "Services/CaptionSessions/CaptionSessionStore.swift",
        "Services/AmbientCaptionService.swift",
        "App/Views/CaptionSessionsView.swift",
        "App/OpenGlassesApp.swift",
        "Services/Privacy/DataStoreRegistry.swift",
        "Services/Privacy/SubjectErasureCoordinator.swift",
        "Services/Privacy/AIFeatureRegistry.swift",
    ]

    private static let held = ["CaptionSessionStore", "CaptionSession", "CaptionSessionTranscript"]

    private static func swiftFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func relative(_ url: URL) -> String {
        String(url.path.dropFirst(sourcesRoot.path.count + 1))
    }

    private static func code(_ url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
        return text
    }

    private static func names(_ name: String, in code: String) -> Bool {
        code.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil
    }

    func testOnlyTheCaptionFilesTheWiringAndTheWalksNameAKeptSession() throws {
        let files = Self.swiftFiles()
        XCTAssertGreaterThan(files.count, 500, "sanity: the sources were found")
        for url in files {
            let relative = Self.relative(url)
            guard !Self.allowed.contains(relative) else { continue }
            let code = try Self.code(url)
            for name in Self.held where Self.names(name, in: code) {
                XCTFail("\(relative) names \(name). A kept caption session reaches no model, memory, "
                        + "search or Spotlight unless the wearer asks; only its own files, the wiring and "
                        + "the erasure walk name it.")
            }
        }
    }

    /// The allowed files are real, so the list cannot quietly go stale.
    func testEveryAllowedFileExists() {
        for relative in Self.allowed {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.sourcesRoot.appendingPathComponent(relative).path), "\(relative) is gone")
        }
    }

    /// The caption service hands a stopped session to one closure and keeps no store of its own.
    func testTheCaptionServiceOnlyHandsTheSessionOn() throws {
        let code = try Self.code(Self.sourcesRoot.appendingPathComponent("Services/AmbientCaptionService.swift"))
        XCTAssertFalse(Self.names("CaptionSessionStore", in: code))
        for memory in ["BrainStore", "SemanticMemoryStore", "SpotlightIndexService", "DocumentStore"] {
            XCTAssertFalse(Self.names(memory, in: code), "the caption service names \(memory)")
        }
    }

    /// The wiring hands a stopped session to the store and nothing else: the one closure names the
    /// store, never memory, Brain or a model.
    func testTheWiringGivesAStoppedSessionToTheStoreAlone() throws {
        let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("App/OpenGlassesApp.swift"),
                              encoding: .utf8)
        let marker = try XCTUnwrap(text.range(of: "ambientCaptions.onSessionEnded = {"))
        let tail = text[marker.upperBound...]
        let body = String(tail[..<(tail.range(of: "}")?.lowerBound ?? tail.endIndex)])
        XCTAssertTrue(body.contains("CaptionSessionStore.shared.keep(session)"), body)
        for memory in ["BrainStore", "userMemory", "llmService", "ingest", "Spotlight", "conversationStore"] {
            XCTAssertFalse(body.contains(memory), "a stopped session reaches \(memory)")
        }
    }
}
