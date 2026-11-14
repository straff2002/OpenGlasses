import XCTest
@testable import OpenGlasses

/// Plan LT §2 — the private-span rule: a turn that read outside content and the wearer's private
/// data asks before an outbound call carries a copied span of the private data.
final class PrivateSpanCheckTests: XCTestCase {

    private let health = "Metformin 500 mg twice daily with food, started in March."
    private let web = PrivateSpanCheck.Read(tool: "web_search", isNative: true, result: "A page about diabetes.")

    private func vault(_ text: String) -> PrivateSpanCheck.Read {
        PrivateSpanCheck.Read(tool: "health_vault", isNative: true, result: text)
    }

    // MARK: - Five words, 24 characters

    func testFiveCopiedWordsAreASpanWhateverTheirCaseAndPunctuation() {
        let finding = PrivateSpanCheck.check(outbound: ["side effects of METFORMIN 500mg... twice daily, with food?"],
                                             reads: [web, vault(health)])
        // "500mg" is one word, so this run is "metformin 500mg twice daily with" against
        // "metformin 500 mg twice daily" — not five in a row. The next query is.
        XCTAssertNil(finding)
        let copied = PrivateSpanCheck.check(outbound: ["side effects of METFORMIN 500 MG, twice daily"],
                                            reads: [web, vault(health)])
        XCTAssertEqual(copied, .init(source: .healthNotes, sent: "side effects of METFORMIN 500 MG, twice daily"))
    }

    func testFourWordsAreNotASpan() {
        XCTAssertNil(PrivateSpanCheck.check(outbound: ["metformin 500 mg twice"], reads: [web, vault(health)]))
    }

    func testTwentyFourCharactersWithNoSpaceAreASpan() {
        // One word to the word rule, so only the character rule can catch it.
        let policy = "Policy number AB2291XK77310QQ4410ZZ987 renews in June."
        let reads = [web, PrivateSpanCheck.Read(tool: "notes_vault", isNative: true, result: policy)]
        let id24 = "ab2291XK77310QQ4410ZZ987"          // 24 characters, case folded
        XCTAssertEqual(id24.count, 24)
        XCTAssertEqual(PrivateSpanCheck.check(outbound: ["lookup \(id24)"], reads: reads)?.source, .notes)
        let id23 = String(id24.dropLast())
        XCTAssertNil(PrivateSpanCheck.check(outbound: ["lookup \(id23)"], reads: reads))
    }

    // MARK: - Both halves, or no prompt

    /// Memory, notes and the health vault are our own stores: a turn that only read them, however
    /// much of them it copies, never prompts.
    func testAMemoryOnlyTurnNeverPrompts() {
        let reads = [vault(health),
                     PrivateSpanCheck.Read(tool: "memory_search", isNative: true, result: health),
                     PrivateSpanCheck.Read(tool: "document_knowledge", isNative: true, result: health)]
        XCTAssertFalse(PrivateSpanCheck.readExternalUntrusted(reads))
        XCTAssertNil(PrivateSpanCheck.check(outbound: [health], reads: reads))
    }

    func testNoExternalReadNoPrompt() {
        let reads = [PrivateSpanCheck.Read(tool: "calendar", isNative: true, result: health),
                     PrivateSpanCheck.Read(tool: "get_weather", isNative: true, result: "Sunny")]
        XCTAssertNil(PrivateSpanCheck.check(outbound: [health], reads: reads))
    }

    func testAnExternalReadWithNothingPrivateNoPrompt() {
        let reads = [web, PrivateSpanCheck.Read(tool: "get_news", isNative: true, result: health)]
        XCTAssertNil(PrivateSpanCheck.check(outbound: [health], reads: reads),
                     "copying a news result is not copying the wearer's data")
    }

    /// An MCP server's answer is outside content; a call still in flight has read nothing yet.
    func testAnMCPAnswerCountsAsOutsideAndACallInFlightDoesNot() {
        let inFlight = PrivateSpanCheck.Read(tool: "web_search", isNative: true, result: nil)
        XCTAssertFalse(PrivateSpanCheck.readExternalUntrusted([inFlight, vault(health)]))
        XCTAssertNil(PrivateSpanCheck.check(outbound: [health], reads: [inFlight, vault(health)]))

        let mcp = PrivateSpanCheck.Read(tool: "notion__search", isNative: false, result: "a page")
        XCTAssertTrue(PrivateSpanCheck.readExternalUntrusted([mcp]))
        XCTAssertEqual(PrivateSpanCheck.check(outbound: [health], reads: [mcp, vault(health)])?.source,
                       .healthNotes)
        // A server's tool named like one of ours is not one of ours.
        let impostor = PrivateSpanCheck.Read(tool: "health_vault", isNative: false, result: health)
        XCTAssertTrue(PrivateSpanCheck.privateOutputs([impostor]).isEmpty)
    }

    /// The ledger's derived facts: a memory lookup is untrusted for framing but not outside.
    func testTheLedgerTellsUntrustedFromExternal() {
        var ledger = AttemptToolLedger()
        let memory = ledger.dispatched(tool: "memory_search", arguments: "{}", effect: .readOnly, isNative: true)
        ledger.finished(memory, outcome: .completed(health))
        XCTAssertTrue(ledger.readUntrustedOutput)
        XCTAssertFalse(ledger.readExternalUntrusted)
        XCTAssertTrue(ledger.readPrivateOutput)

        let search = ledger.dispatched(tool: "web_search", arguments: "{}", effect: .readOnly, isNative: true)
        XCTAssertTrue(ledger.hasCallInFlight(tool: "web_search"))
        XCTAssertFalse(ledger.readExternalUntrusted, "a search still running has read nothing")
        ledger.finished(search, outcome: .completed("results"))
        XCTAssertTrue(ledger.readExternalUntrusted)
        XCTAssertFalse(ledger.hasCallInFlight(tool: nil))
    }

    // MARK: - The ask

    func testTheAskSaysWhatWouldBeSentWhereAndFromWhat() {
        let finding = PrivateSpanCheck.Finding(source: .healthNotes, sent: "metformin 500 mg twice daily")
        let native = PrivateSpanCheck.approvalSummary(
            for: finding, destination: .native(askVerb: NativeEgressProfile.webSearch.askVerb))
        XCTAssertTrue(native.hasPrefix(NativeEgressProfile.webSearch.askVerb))
        XCTAssertTrue(native.contains("\u{201C}metformin 500 mg twice daily\u{201D}"))
        XCTAssertTrue(native.contains(PrivateSpanCheck.Source.healthNotes.spoken))
        XCTAssertTrue(PrivateSpanCheck.approvalSummary(for: finding, destination: .server(label: "Notion"))
            .contains("Notion"))
        XCTAssertTrue(PrivateSpanCheck.approvalSummary(for: finding, destination: .gateway).contains("gateway"))
        let long = PrivateSpanCheck.preview(String(repeating: "word ", count: 60))
        XCTAssertLessThanOrEqual(long.count, 121)
    }

    /// The marks name real native tools, so a renamed tool cannot fall silently out of the rule.
    func testEveryMarkedToolIsARealNativeTool() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/NativeTools")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("Could not enumerate tools")
        }
        var corpus = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            corpus += try String(contentsOf: url, encoding: .utf8)
        }
        for name in Set(PrivateSpanCheck.privateOutputTools.keys).union(PrivateSpanCheck.ownStores) {
            XCTAssertTrue(corpus.contains("\"\(name)\""), "\(name) is not a native tool name")
        }
        // Our own stores are untrusted for framing — that is exactly why they need carving out.
        for store in PrivateSpanCheck.ownStores where store != "session_search" {
            XCTAssertTrue(PromptInjectionPolicy.untrustedOutputTools.contains(store), store)
        }
    }
}
