import XCTest
@testable import OpenGlasses

/// Plan MQ P2 — llama.cpp's `common/chat` through the wrapper's chat bridge.
///
/// These run the real `common/chat` with no model: a template from source renders and parses fixed
/// strings. The templates in `Fixtures/ChatTemplates` are the copies llama.cpp's own
/// tests use, taken from the pinned checkout (`models/templates/` at v0.3.0): Gemma 4 (31B — the
/// family's template; the E-series carry the same call syntax), Qwen 3.5 4B and Qwen 3 0.6B.
///
/// Not claimed here: that a real GGUF model calls a tool well. That is the phone run's.
final class LlamaToolChatTests: XCTestCase {

    // MARK: - Fixtures

    private static var templatesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ChatTemplates")
    }

    private static func template(_ name: String) throws -> String {
        try String(contentsOf: templatesDirectory.appendingPathComponent("\(name).jinja"), encoding: .utf8)
    }

    private static let gemma4 = "google-gemma-4-31B-it"
    private static let qwen35 = "Qwen3.5-4B"
    private static let qwen3 = "Qwen-Qwen3-0.6B"

    private let engine = LlamaCppEngine()

    private func templates(_ name: String) throws -> LlamaChatTemplatesHandle {
        let bos = name == Self.gemma4 ? "<bos>" : ""
        let eos = name == Self.gemma4 ? "<eos>" : "<|im_end|>"
        let handle = try engine.chatTemplates(source: try Self.template(name), bosToken: bos, eosToken: eos)
        addTeardownBlock { [engine] in engine.freeChatTemplates(handle) }
        return handle
    }

    private static let readingTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "reading",
            "description": "Log a measured value on the open job.",
            "parameters": [
                "type": "object",
                "properties": [
                    "value": ["type": "number", "description": "The value."],
                    "unit": ["type": "string", "enum": ["psi", "kPa"]],
                ],
                "required": ["value"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    private static let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)

    /// A turn that already logged one reading and asks for the next: a call, its result, a turn.
    private static var transcript: [LocalToolLoop.Message] {
        let call = LocalToolLoop.Call(id: "call_1", name: "reading", arguments: ["value": 120, "unit": "psi"])
        return [.user("Log 120 psi on the high side"),
                .assistant("", calling: call),
                .toolResult("Logged 120 psi.", for: call),
                .user("and the low side is 60 psi")]
    }

    private func render(_ name: String, tools: [[String: Any]] = [readingTool],
                        messages: [LocalToolLoop.Message] = transcript) throws -> (json: String, render: LlamaToolChat.Render) {
        let json = try engine.renderChat(try templates(name), requestJSON: LlamaToolChat.requestJSON(
            system: "You are Avenkin.", messages: messages, tools: tools, thinkingOff: true, now: Self.fixedNow))
        return (json, try LlamaToolChat.render(json))
    }

    private func parse(_ text: String, with renderJSON: String) throws -> LlamaToolChat.Parsed {
        let parser = try engine.createChatParser(renderJSON: renderJSON)
        defer { engine.freeChatParser(parser) }
        return try LlamaToolChat.parsed(try engine.parseChat(parser, text: text, partial: false))
    }

    // MARK: - Render: each family in its own format

    func testGemma4RendersTheToolsTheCallAndTheResultInItsOwnSyntax() throws {
        let (_, render) = try render(Self.gemma4)
        XCTAssertEqual(render.formatName, "peg-gemma4")
        XCTAssertTrue(render.prompt.hasPrefix("<bos><|turn>system\nYou are Avenkin."))
        XCTAssertTrue(render.prompt.contains("<|tool>declaration:reading{"), "the tool goes in Gemma's declaration syntax")
        XCTAssertTrue(render.prompt.contains("<|tool_call>call:reading{unit:<|\"|>psi<|\"|>,value:120}<tool_call|>"),
                      "the earlier call is written back as Gemma writes one")
        XCTAssertTrue(render.prompt.contains("Logged 120 psi."), "and its result")
        XCTAssertTrue(render.prompt.hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"),
                      "thinking off: the thought channel opens and closes empty")
        XCTAssertTrue(render.toolsRendered)
        XCTAssertTrue(render.constrainsCalls, "a lazy grammar with a trigger")
        XCTAssertEqual(render.grammarTriggers.map(\.value), ["<|tool_call>"])
        XCTAssertTrue(render.preservedTokens.contains("<|tool_call>"))
        XCTAssertTrue(render.preservedTokens.contains("<tool_call|>"))
    }

    func testQwen35RendersItsXMLParameters() throws {
        let (_, render) = try render(Self.qwen35)
        XCTAssertEqual(render.formatName, "peg-native")
        XCTAssertTrue(render.prompt.contains(
            "<function=reading>\n<parameter=unit>\npsi\n</parameter>\n<parameter=value>\n120\n</parameter>"),
                      "the earlier call in Qwen 3.5's XML form (canonical arguments: sorted keys)")
        XCTAssertTrue(render.prompt.contains("<tool_response>\nLogged 120 psi.\n</tool_response>"))
        XCTAssertTrue(render.prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"), "thinking off")
        XCTAssertTrue(render.constrainsCalls)
        XCTAssertTrue(render.grammarTriggers.map(\.value).contains("<tool_call>"))
    }

    /// Qwen 3 has no handler of its own: `common/chat` builds its parser by probing the template,
    /// and the probe relies on catching what a probe render throws. In the app's image that catch
    /// misses (`LlamaCppEngine.catchesStandardExceptions`, found 2026-11-24: another vendored static
    /// library brings its own `std::exception` typeinfo), so these two run only where it works.
    private func skipUnlessTheImageCatchesStandardExceptions() throws {
        try XCTSkipUnless(LlamaCppEngine.catchesStandardExceptions,
                          "this image's catch (const std::exception &) misses libc++ exceptions, so common/chat's "
                          + "automatic parser cannot probe a template; Qwen 3-style templates fall back to the Hermes path")
    }

    func testQwen3RendersHermesJSON() throws {
        try skipUnlessTheImageCatchesStandardExceptions()
        let (_, render) = try render(Self.qwen3)
        XCTAssertEqual(render.formatName, "peg-native")
        XCTAssertTrue(render.prompt.contains("<tools>"))
        XCTAssertTrue(render.prompt.contains("{\"name\": \"reading\", \"arguments\": {\"value\": 120, \"unit\": \"psi\"}}"))
        XCTAssertTrue(render.constrainsCalls)
    }

    func testToolsWithheldRenderNoToolsAndNoGrammar() throws {
        let (_, render) = try render(Self.gemma4, tools: [])
        XCTAssertFalse(render.toolsRendered)
        XCTAssertFalse(render.prompt.contains("<|tool>declaration"))
        XCTAssertFalse(render.constrainsCalls, "no tools, nothing to constrain")
    }

    func testARenderIsTheSameEveryTime() throws {
        XCTAssertEqual(try render(Self.gemma4).json, try render(Self.gemma4).json,
                       "a fixed clock and the same inputs give the same prompt, which prefix reuse depends on")
    }

    // MARK: - Parse: calls out, prose kept, malformed never a call

    func testGemma4CallsAreParsedOutOfTheReply() throws {
        let json = try render(Self.gemma4).json
        let one = try parse("<|tool_call>call:reading{unit:<|\"|>psi<|\"|>,value:60}<tool_call|>", with: json)
        XCTAssertEqual(one.calls, [LocalToolCallEvent(name: "reading", arguments: ["unit": "psi", "value": 60])])
        XCTAssertEqual(one.content, "")

        let prose = try parse("Logged sixty on the low side.", with: json)
        XCTAssertEqual(prose.calls, [])
        XCTAssertEqual(prose.content, "Logged sixty on the low side.")

        let both = try parse("Logging it.<|tool_call>call:reading{value:60}<tool_call|>", with: json)
        XCTAssertEqual(both.content, "Logging it.")
        XCTAssertEqual(both.calls.map(\.name), ["reading"])

        let two = try parse("<|tool_call>call:reading{value:60}<tool_call|><|tool_call>call:reading{value:61}<tool_call|>",
                            with: json)
        XCTAssertEqual(two.calls.count, 2, "every call in a generation, in order")
    }

    func testACallCutOffMidArgumentsIsNeverACall() throws {
        let json = try render(Self.gemma4).json
        let cut = try parse("Sure.<|tool_call>call:reading{value:", with: json)
        XCTAssertEqual(cut.calls, [], "half a call is not run")
        XCTAssertEqual(cut.malformedCalls, 1)
        XCTAssertEqual(cut.content, "Sure.")
    }

    func testQwen35ReadsItsOwnFormatAndNotAnother() throws {
        let json = try render(Self.qwen35).json
        let xml = try parse("<tool_call>\n<function=reading>\n<parameter=value>\n60\n</parameter>\n</function>\n</tool_call>",
                            with: json)
        XCTAssertEqual(xml.calls, [LocalToolCallEvent(name: "reading", arguments: ["value": 60])])
        let hermes = try parse("<tool_call>\n{\"name\": \"reading\", \"arguments\": {\"value\": 60}}\n</tool_call>", with: json)
        XCTAssertEqual(hermes.calls, [], "another family's syntax is not this family's call")
    }

    func testQwen3ReadsHermesAndRefusesXML() throws {
        try skipUnlessTheImageCatchesStandardExceptions()
        let json = try render(Self.qwen3).json
        let hermes = try parse("<tool_call>\n{\"name\": \"reading\", \"arguments\": {\"value\": 60}}\n</tool_call>", with: json)
        XCTAssertEqual(hermes.calls, [LocalToolCallEvent(name: "reading", arguments: ["value": 60])])
        XCTAssertThrowsError(try parse("<tool_call>\n<function=reading>\n<parameter=value>\n60\n</parameter>\n</function>\n</tool_call>",
                                       with: json)) { error in
            XCTAssertEqual(error as? LlamaEngineError, .parseFailed, "output that is not the family's format")
        }
    }

    func testAPartialParseFeedsThePreviewWithoutTheCall() throws {
        let json = try render(Self.gemma4).json
        let parser = try engine.createChatParser(renderJSON: json)
        defer { engine.freeChatParser(parser) }
        let partial = try LlamaToolChat.parsed(try engine.parseChat(parser, text: "Logging it.<|tool_call>call:rea",
                                                                     partial: true))
        XCTAssertEqual(partial.content, "Logging it.")
        XCTAssertEqual(LlamaToolChat.previewDelta(shown: "Logg", current: partial.content), "ing it.")
        XCTAssertEqual(LlamaToolChat.previewDelta(shown: "Logging it!", current: "Logging it."), "",
                       "a preview never takes words back")
    }

    func testMalformedArgumentsFromTheParserAreCountedNotRun() throws {
        let parsed = try LlamaToolChat.parsed(#"{"content":"ok","tool_calls":[{"name":"reading","arguments":"{\"value\":"},{"name":"","arguments":"{}"},{"name":"reading","arguments":"[1]"},{"name":"reading","arguments":"{\"value\":3}"}]}"#)
        XCTAssertEqual(parsed.calls, [LocalToolCallEvent(name: "reading", arguments: ["value": 3])])
        XCTAssertEqual(parsed.malformedCalls, 3)
    }

    // MARK: - The request

    func testTheTranscriptGoesInAsOpenAIShapes() throws {
        let json = LlamaToolChat.requestJSON(system: "S", messages: Self.transcript, tools: [Self.readingTool],
                                             thinkingOff: true, now: Self.fixedNow)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "user"])
        let call = try XCTUnwrap((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["id"] as? String, "call_1")
        let function = try XCTUnwrap(call["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "reading")
        XCTAssertEqual(function["arguments"] as? String, #"{"unit":"psi","value":120}"#, "arguments as JSON text")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[3]["name"] as? String, "reading")
        XCTAssertEqual(object["enable_thinking"] as? Bool, false)
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, true)
        XCTAssertNil(LlamaToolChat.requestJSON(system: "S", messages: [], tools: [], thinkingOff: true)
            .range(of: "\"tools\""), "withheld tools are absent, not an empty list")
    }

}
