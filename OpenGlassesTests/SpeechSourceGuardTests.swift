import XCTest
@testable import OpenGlasses

/// Plan KL P4 — every spoken line says where it came from.
///
/// `TextToSpeechService.speak`, `speakReporting` and `speakStreaming` take a `SpeechSource` with no
/// default, so the compiler already refuses a caller that leaves it out. What the compiler cannot
/// see is a wrapper: a closure or helper that takes a bare `String` and calls the speaker with one
/// fixed token would put every line through it under that token, or a declaration that defaults the
/// source would make it optional again. So this reads the source, as `OutboundFrameConsumerTests`
/// does: it finds every call to the three entry points in `OpenGlasses/Sources` and fails unless it
/// passes `source:`, or its receiver is one of the seams listed below, each of which is a
/// `String` closure whose wiring in `AppState` names the source.
final class SpeechSourceGuardTests: XCTestCase {

    // MARK: - Source scraping

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Receivers named `speak` that are not the speech service. Each is a seam: a pure service is
    /// handed a `(String) async -> Void`, and the closure it is handed (in `AppState`'s wiring) is
    /// a `speechService.speak(…, source: …)` call this scrape checks.
    private static let seamReceivers: Set<String> = [
        // Field Assist's job flow, job sends, job files and the offline handoff (`seams.speak`).
        "seams",
        // The turn runner, the remote-command executor (`deps.speak`).
        "deps",
        // Fingerspelling's injected speaker.
        "dependencies",
        // `AVSpeechSynthesizer.speak(_:)`: the system voice itself, below the source.
        "synthesizer", "localCueSynth",
    ]

    /// Files whose bare `speak(…)` is a stored closure, not the speech service. Same reasoning as
    /// `seamReceivers`; a bare call anywhere else must pass `source:`.
    private static let seamClosureFiles: Set<String> = [
        "TurnAnnouncement.swift",            // `Speak` carries the source as its second argument
        "AudibleLifecycleCoordinator.swift",
        "AgentSessionService.swift",
        "BroadcastChatReadbackService.swift",
        "ReadinessWalkthroughRunner.swift",
        "LiveSessionActivator.swift",
    ]

    private struct Call {
        let file: String
        let line: Int
        let receiver: String
        let arguments: String
    }

    private static let entryPoints: Set<String> = ["speak", "speakReporting", "speakStreaming"]

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Every call in one file, with its receiver (the identifier before the `.`, or "" for a bare
    /// call) and its argument text up to the matching parenthesis.
    private func calls(in file: URL) throws -> [Call] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        // Comments are documentation, not calls: blank every comment line so lines still count.
        let code = contents.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") ? "" : line
        }.joined(separator: "\n")
        let text = Array(code)
        var found: [Call] = []
        var line = 1
        var index = 0
        while index < text.count {
            let character = text[index]
            if character == "\n" { line += 1 }
            guard character == "s", index == 0 || !Self.isIdentifier(text[index - 1]) else {
                index += 1
                continue
            }
            var end = index
            while end < text.count, Self.isIdentifier(text[end]) { end += 1 }
            let word = String(text[index..<end])
            guard Self.entryPoints.contains(word), end < text.count, text[end] == "(" else {
                index = end
                continue
            }
            let before = String(text[max(0, index - 5)..<index])
            // A declaration (`func speak(`) or an enum case (`case speak(text:`) is not a call.
            if before.hasSuffix("func ") || before.hasSuffix("case ") {
                index = end
                continue
            }
            var receiver = ""
            if index > 0, text[index - 1] == "." {
                var cursor = index - 2
                if cursor >= 0, text[cursor] == "?" || text[cursor] == "!" { cursor -= 1 }
                // `.speak(text:)` with nothing before the dot is an enum member, not a call.
                guard cursor >= 0, Self.isIdentifier(text[cursor]) || text[cursor] == ")" else {
                    index = end
                    continue
                }
                var first = cursor
                while first >= 0, Self.isIdentifier(text[first]) { first -= 1 }
                receiver = String(text[(first + 1)...cursor])
            }
            // The argument list, to the matching parenthesis.
            var depth = 0
            var cursor = end
            var arguments = ""
            while cursor < text.count {
                let next = text[cursor]
                if next == "(" { depth += 1 }
                if next == ")" { depth -= 1 }
                arguments.append(next)
                if depth == 0 { break }
                cursor += 1
            }
            found.append(Call(file: file.lastPathComponent, line: line, receiver: receiver,
                              arguments: arguments))
            index = end
        }
        return found
    }

    private func swiftFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: Self.sourcesRoot,
                                                              includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate \(Self.sourcesRoot.path)")
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func allCalls() throws -> [Call] {
        try swiftFiles().flatMap { try calls(in: $0) }
    }

    /// Whether a call is to the speech service and so has to name its source.
    private func isSpeechServiceCall(_ call: Call) -> Bool {
        if Self.seamReceivers.contains(call.receiver) { return false }
        if call.receiver.isEmpty || call.receiver == "self" {
            return !Self.seamClosureFiles.contains(call.file)
        }
        return true
    }

    // MARK: - The scrape is finding things

    /// Without this, a moved folder or a renamed entry point would make every assertion below a
    /// vacuous pass.
    func testTheScrapeFindsTheKnownCallSites() throws {
        let checked = try allCalls().filter(isSpeechServiceCall)
        XCTAssertGreaterThan(checked.count, 90,
                             "expected about a hundred speech calls; found \(checked.count)")
        let files = Set(checked.map(\.file))
        for expected in ["OpenGlassesApp.swift", "TextToSpeechService.swift", "CarPlaySceneDelegate.swift",
                         "AppState+AIDisclosure.swift", "LiveCoachService.swift",
                         "HealthSummaryTool.swift", "ScanAssistSpeaking.swift"] {
            XCTAssertTrue(files.contains(expected), "the scrape missed \(expected)")
        }
        XCTAssertTrue(checked.contains { $0.arguments.hasPrefix("(chunk") },
                      "the gateway's streamed reply (`speakStreaming`) is not being read")
    }

    // MARK: - The claim

    /// Every call to the speech service passes `source:` at the top level of its arguments.
    func testEverySpeechCallNamesItsSource() throws {
        let missing = try allCalls().filter(isSpeechServiceCall).filter { !$0.arguments.contains("source:") }
        XCTAssertTrue(missing.isEmpty, "Spoken lines with no source (Plan KL P4): "
            + missing.map { "\($0.file):\($0.line) \($0.receiver).…\($0.arguments.prefix(80))" }
                .joined(separator: "; "))
    }

    /// No declaration makes the source optional again: no `SpeechSource` parameter or property
    /// defaults to a case. (`StreamedReplyQueue.source` is a `let` set by its required init.)
    func testNoDeclarationDefaultsTheSource() throws {
        let defaulted = try NSRegularExpression(pattern: #":\s*SpeechSource\??\s*="#)
        var hits: [String] = []
        for file in try swiftFiles() {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if defaulted.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "a defaulted SpeechSource: \(hits.joined(separator: ", "))")
    }

    /// Both `speaking` lines the service writes (the one-shot chain and a streamed sentence) log
    /// the source beside the length.
    func testEverySpeakingLogLineCarriesTheSource() throws {
        let tts = try String(contentsOf: Self.sourcesRoot
            .appendingPathComponent("Services/TextToSpeechService.swift"), encoding: .utf8)
        let lines = tts.components(separatedBy: "PrivacyLog.tts(.speaking").dropFirst()
        XCTAssertEqual(lines.count, 2, "expected the chain's and the streamed sentence's speaking lines")
        for line in lines {
            XCTAssertTrue(line.prefix(300).contains("source: source.token"),
                          "a speaking line without its source: \(line.prefix(120))")
        }
    }
}
