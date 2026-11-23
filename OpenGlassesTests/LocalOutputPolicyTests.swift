import XCTest
@testable import OpenGlasses

/// Plan FC P1 — the pure half of local-output containment: what a completion *is*, what of it may
/// be spoken, and what the streaming preview is allowed to show before the answer can be
/// classified at all.
///
/// The end-to-end half (the real `sendLocal`, a recording tool, history) is
/// `LocalTurnContainmentTests`. This file is where the boundary shapes live, because they are
/// character-level and there are a lot of them.
final class LocalOutputPolicyTests: XCTestCase {

    private let validFrame = #"<tool_call>{"name": "get_weather", "arguments": {"city": "Auckland"}}</tool_call>"#

    // MARK: - Valid calls

    // MARK: - Gemma 4's own call syntax (Plan MQ P3)

    /// The shapes Gemma 4 E2B wrote on the phone after the "I'll look that up" correction.
    func testGemmasCallsBehindAStrayOpenerAreRead() {
        let shapes = [
            #"<tool_call:equipment_lookup{query:<|"|>E105<|"|>}}"#,
            #"<tool_call:equipment_lookup{query:<|"|>E117<|"|>}>"#,
            "<tool_call>equipment_lookup{query:<|\"|>E226<|\"|>}\n</tool_call>",
            #"<tool_call>equipment_lookup{query:<|"|>E311<|"|>}"#,
            #"<|tool_call>call:equipment_lookup{query:<|"|>E105<|"|>}<tool_call|>"#,
        ]
        for raw in shapes {
            let result = LocalOutputPolicy.classify(raw)
            XCTAssertEqual(result.kind, .toolCall, raw)
            XCTAssertEqual(result.invocation?.name, "equipment_lookup", raw)
            XCTAssertNotNil(result.invocation?.arguments["query"] as? String, raw)
            XCTAssertEqual(result.text, "", "nothing of the frame is spoken: \(raw)")
        }
        let none = LocalOutputPolicy.classify("<tool_call>where_am_i()</tool_call>")
        XCTAssertEqual(none.invocation?.name, "where_am_i")
        XCTAssertEqual(none.invocation?.arguments.count, 0)
    }

    func testGemmasArgumentsKeepTheirTypes() {
        let raw = #"<tool_call:procedure_runner{action:<|"|>next<|"|>,count:2,ratio:0.5,confirmed:true}>"#
        let arguments = LocalOutputPolicy.classify(raw).invocation?.arguments ?? [:]
        XCTAssertEqual(arguments["action"] as? String, "next")
        XCTAssertEqual(arguments["count"] as? Int, 2)
        XCTAssertEqual(arguments["ratio"] as? Double, 0.5)
        XCTAssertEqual(arguments["confirmed"] as? Bool, true)
    }

    func testAGemmaBodyThatDoesNotReadIsNeverACallAndNeverSpoken() {
        for raw in [#"<tool_call:equipment_lookup{query:<|"|>E105}"#,          // unterminated string
                    #"<tool_call:equipment_lookup{query:E105}>"#,               // bare word value
                    #"<tool_call:equipment_lookup query E105>"#,                // no body
                    #"<tool_call:{query:<|"|>E105<|"|>}>"#] {                   // no name
            let result = LocalOutputPolicy.classify("Checking. " + raw)
            XCTAssertNil(result.invocation, raw)
            XCTAssertEqual(result.kind, .malformedCall, raw)
            XCTAssertEqual(result.text, "Checking.", raw)
        }
    }

    func testProseThatMentionsGemmasMarksIsLeftAlone() {
        let prose = "The code is E105, call: check the wiring {first}."
        XCTAssertEqual(LocalOutputPolicy.classify(prose).kind, .prose)
        XCTAssertEqual(LocalOutputPolicy.classify(prose).text, prose)
    }

    // MARK: - Python-style calls (Plan MQ P3)

    /// Gemma 4 E2B's whole reply on the phone, which logged nothing.
    func testThePhonesPythonStyleCallIsRead() {
        let raw = #"reading(action="record_reading", quantity="flame signal", unit="µA", value="2.9")"#
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.invocations.map(\.name), ["reading"])
        let arguments = result.invocation?.arguments ?? [:]
        XCTAssertEqual(arguments.count, 4)
        XCTAssertEqual(arguments["action"] as? String, "record_reading")
        XCTAssertEqual(arguments["quantity"] as? String, "flame signal")
        XCTAssertEqual(arguments["unit"] as? String, "µA")
        XCTAssertEqual(arguments["value"] as? String, "2.9", "a quoted number stays the text it was")
        XCTAssertEqual(result.text, "")
    }

    func testPythonStyleArgumentsKeepTheirTypes() {
        let raw = "domain_calc(count=2, ratio=0.5, big=-3, confirmed=True, dry_run=false, unit=None, note=null)"
        let arguments = LocalOutputPolicy.classify(raw).invocation?.arguments ?? [:]
        XCTAssertEqual(arguments["count"] as? Int, 2)
        XCTAssertEqual(arguments["ratio"] as? Double, 0.5)
        XCTAssertEqual(arguments["big"] as? Int, -3)
        XCTAssertEqual(arguments["confirmed"] as? Bool, true)
        XCTAssertEqual(arguments["dry_run"] as? Bool, false)
        XCTAssertNil(arguments["unit"], "None drops the key")
        XCTAssertNil(arguments["note"])
        XCTAssertEqual(arguments.count, 5)
    }

    func testPythonStyleStringsTakeEitherQuoteAndTheirEscapes() {
        let raw = #"note_add(text='it\'s "fine", a) b', title="say \"hi\"")"#
        let arguments = LocalOutputPolicy.classify(raw).invocation?.arguments ?? [:]
        XCTAssertEqual(arguments["text"] as? String, #"it's "fine", a) b"#)
        XCTAssertEqual(arguments["title"] as? String, #"say "hi""#)
    }

    func testPythonStyleCallsInAFenceASpanOrAfterCallAreRead() {
        let shapes = [
            "```python\nreading(action=\"record_reading\", value=\"120\")\n```",
            "```tool_code\nreading(action=\"record_reading\", value=\"120\")\n```",
            "```\nreading(action=\"record_reading\", value=\"120\")\n```",
            "`reading(action=\"record_reading\", value=\"120\")`",
            "call:reading(action=\"record_reading\", value=\"120\")",
            "<tool_call>reading(action=\"record_reading\", value=\"120\")</tool_call>",
            "<tool_call>reading(action=\"record_reading\", value=\"120\")",
        ]
        for raw in shapes {
            let result = LocalOutputPolicy.classify(raw)
            XCTAssertEqual(result.kind, .toolCall, raw)
            XCTAssertEqual(result.invocation?.name, "reading", raw)
            XCTAssertEqual(result.invocation?.arguments["value"] as? String, "120", raw)
            XCTAssertEqual(result.text, "", raw)
        }
    }

    func testEachPythonStyleCallLineIsACallInOrder() {
        let raw = "Logging both.\nreading(action=\"record_reading\", value=\"120\")\ndomain_calc(operation=\"voltage_drop\")\n"
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertEqual(result.invocations.map(\.name), ["reading", "domain_calc"])
        XCTAssertEqual(result.invocation?.name, "reading")
        XCTAssertEqual(result.text, "Logging both.")
        let fenced = LocalOutputPolicy.classify("```python\nreading(value=\"1\")\n\nwhere_am_i()\n```")
        XCTAssertEqual(fenced.invocations.map(\.name), ["reading", "where_am_i"])
    }

    func testAPythonStyleCallWithNoArgumentsIsACall() {
        let result = LocalOutputPolicy.classify("where_am_i()")
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.invocation?.name, "where_am_i")
        XCTAssertEqual(result.invocation?.arguments.count, 0)
    }

    func testAPythonStyleCallThatDoesNotReadIsNeverACallAndNeverSpoken() {
        for line in [#"reading("flame signal", value="2.9")"#,           // positional
                     #"reading(value=float("2.9"))"#,                    // nested call
                     "domain_calc(volts=120*2)",                          // expression
                     "reading(values=[1, 2])",                            // list
                     #"reading(extra={"a": 1})"#,                         // dict
                     #"reading(value="2.9)"#,                             // unterminated string
                     #"reading(value=2.9, value=3)"#,                     // repeated key
                     "reading(value=flame)"] {                            // bare word
            let result = LocalOutputPolicy.classify("Checking.\n" + line)
            XCTAssertNil(result.invocation, line)
            XCTAssertEqual(result.kind, .malformedCall, line)
            XCTAssertEqual(result.text, "Checking.", line)
        }
    }

    func testCallLikeTextInProseIsLeftAlone() {
        for prose in ["You can run print(x) to see it.",
                      "The function f(x=1) returns two.",
                      #"Logging it: reading(action="record_reading", value="2.9")"#,
                      "See the manual (page 4) for the wiring.",
                      "Check fuse(s) first.",
                      "```python\nx = 1\nprint(x=x)\n```",
                      "```bash\nreading(value=1)\n```"] {
            let result = LocalOutputPolicy.classify(prose)
            XCTAssertEqual(result.kind, .prose, prose)
            XCTAssertEqual(result.text, prose, prose)
        }
    }

    func testCompleteFrameIsAUsableCall() {
        let result = LocalOutputPolicy.classify(validFrame)
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.invocation?.name, "get_weather")
        XCTAssertEqual(result.invocation?.arguments["city"] as? String, "Auckland")
        XCTAssertEqual(result.text, "", "the frame itself is never speakable")
    }

    func testProseAroundAValidCallSurvives() {
        let result = LocalOutputPolicy.classify("Sure. \(validFrame) One moment.")
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.text, "Sure. One moment.")
        XCTAssertFalse(result.text.contains("<tool_call>"))
    }

    func testNestedArgumentObjectsParse() {
        let raw = #"<tool_call>{"name": "calculate", "arguments": {"expr": {"a": 1}}}</tool_call>"#
        XCTAssertEqual(LocalOutputPolicy.classify(raw).invocation?.name, "calculate")
    }

    func testSecondFrameIsStrippedButNeverBecomesTheCall() {
        let second = #"<tool_call>{"name": "set_timer", "arguments": {}}</tool_call>"#
        let result = LocalOutputPolicy.classify(validFrame + " and " + second)
        XCTAssertEqual(result.invocation?.name, "get_weather", "first usable call wins")
        XCTAssertEqual(result.text, "and")
        XCTAssertEqual(result.invocations.map(\.name), ["get_weather", "set_timer"],
                       "every usable call, in order, for a reader that runs them all (Plan MQ P3)")
    }

    func testEveryUsableCallIsListedInOrderAcrossBothGrammars() {
        let raw = #"<tool_call>{"name": "reading", "arguments": {"value": "120"}}</tool_call>"#
            + #" <tool_call:domain_calc{operation:<|"|>voltage_drop<|"|>}>"#
            + #" <tool_call>{"name": "broken", "arguments": </tool_call>"#
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.invocations.map(\.name), ["reading", "domain_calc"], "a broken frame is never a call")
        XCTAssertTrue(LocalOutputPolicy.classify("Just prose.").invocations.isEmpty)
        let parsed = LocalOutputPolicy.classify("", parsedCalls: [.init(name: "reading", arguments: [:]),
                                                                  .init(name: "domain_calc", arguments: [:])])
        XCTAssertEqual(parsed.invocation?.name, "reading")
        XCTAssertEqual(parsed.invocations.map(\.name), ["reading", "domain_calc"])
    }

    // MARK: - Broken protocol

    func testUnterminatedFrameIsIncompleteAndEatsTheTailNotThePreamble() {
        let result = LocalOutputPolicy.classify(#"Checking now. <tool_call>{"name": "get_we"#)
        XCTAssertEqual(result.kind, .incompleteFrame)
        XCTAssertNil(result.invocation)
        XCTAssertEqual(result.text, "Checking now.")
    }

    func testMalformedJSONInsideAFrameIsNeverACall() {
        for payload in [#"{"name": "get_weather", "arguments": }"#,
                        #"{"name": "get_weather"}"#,
                        #"{"tool": "get_weather", "arguments": {}}"#,
                        "{}",
                        "get_weather"] {
            let result = LocalOutputPolicy.classify("<tool_call>\(payload)</tool_call>")
            XCTAssertNil(result.invocation, "\(payload) must not parse into an action")
            XCTAssertTrue(result.text.isEmpty, "\(payload) must not be speakable")
            XCTAssertTrue(result.carriesProtocol)
        }
    }

    func testOrphanCloseTagIsProtocolNotSpeech() {
        let result = LocalOutputPolicy.classify("The forecast is fine.</tool_call>")
        XCTAssertEqual(result.kind, .incompleteFrame)
        XCTAssertEqual(result.text, "The forecast is fine.")
    }

    func testEmptyFrameIsProseWithProtocol() {
        let result = LocalOutputPolicy.classify("Right away.<tool_call></tool_call>")
        XCTAssertEqual(result.kind, .proseWithProtocol)
        XCTAssertEqual(result.text, "Right away.")
    }

    func testBareCallObjectIsRemovedAndNeverExecuted() {
        let result = LocalOutputPolicy.classify(#"{"name": "get_weather", "arguments": {"city": "Oslo"}}"#)
        XCTAssertEqual(result.kind, .malformedCall, "untagged output is not the protocol this app offers")
        XCTAssertNil(result.invocation)
        XCTAssertEqual(result.text, "")
    }

    func testBareCallObjectFollowedByAnOrphanCloseTag() {
        let raw = "Sure.\n" + #"{"name": "get_weather", "arguments": {}}</tool_call>"#
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertNil(result.invocation)
        XCTAssertEqual(result.text, "Sure.")
    }

    // MARK: - Positive controls: ordinary English must survive untouched

    func testOrdinarySentencesArePassedThroughUnchanged() {
        let sentences = [
            "Face the window and the light will be behind you.",
            "The web_search tool accepts a query, and returns a short summary.",
            #"A tool call looks like {"name": "x"} in JSON, but you don't need to write one."#,
            "Es ist heute sonnig in Auckland, mit leichtem Wind.",
            "今日は晴れです。",
            "tool_call is just a word here; so is arguments.",
        ]
        for sentence in sentences {
            let result = LocalOutputPolicy.classify(sentence)
            XCTAssertEqual(result.kind, .prose, sentence)
            XCTAssertEqual(result.text, sentence, sentence)
        }
    }

    func testQuotedCallObjectInsideASentenceIsNotProtocol() {
        let raw = #"You would send {"name": "get_weather", "arguments": {}} to the tool runner."#
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertEqual(result.kind, .prose, "a mid-sentence object is an explanation, not a call")
        XCTAssertEqual(result.text, raw)
    }

    func testLineInitialObjectThatKeepsTalkingIsNotACall() {
        let raw = #"{"name": "get_weather", "arguments": {}} is what the model should emit."#
        XCTAssertEqual(LocalOutputPolicy.classify(raw).kind, .prose)
    }

    /// Documented limitation: a *truncated* bare object cannot be told apart from a code fragment
    /// someone is asking about, so it stays prose. Tagged truncation — what a cut-off generation
    /// actually produces — is caught.
    func testTruncatedBareObjectIsADocumentedGap() {
        let result = LocalOutputPolicy.classify(#"{"name": "get_we"#)
        XCTAssertEqual(result.kind, .prose)
    }

    // MARK: - Speaker labels and tidying

    func testSpeakerLabelIsStrippedAndSeamsAreTidied() {
        XCTAssertEqual(LocalOutputPolicy.classify("OpenGlasses: It's sunny.").text, "It's sunny.")
        XCTAssertEqual(LocalOutputPolicy.classify("Avenkin: It's sunny.").text, "It's sunny.",
                       "the product name is stripped as a speaker label, as the old one still is")
        XCTAssertEqual(LocalOutputPolicy.classify("Note: bring an umbrella").text,
                       "Note: bring an umbrella")
        XCTAssertEqual(LocalOutputPolicy.classify("It is \(validFrame) sunny.").text, "It is sunny.")
    }

    // MARK: - cleanedNonEmptyLocalAnswer, now a wrapper over the policy

    func testValidatorRejectsAnUnterminatedFrameItUsedToLetThrough() {
        // The old regex only matched a *complete* frame, so this reached the speaker verbatim.
        XCTAssertThrowsError(try LLMService.cleanedNonEmptyLocalAnswer(#"<tool_call>{"name": "get_we"#)) { error in
            guard case LLMError.invalidResponse(let who) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertEqual(who, "Local")
        }
    }

    // MARK: - Streaming filter

    /// Feed chunks one at a time; returns everything the preview sink would have seen.
    private func streamed(_ chunks: [String]) -> String {
        let filter = LocalProtocolStreamFilter()
        var seen = ""
        for chunk in chunks { seen += filter.ingest(chunk) }
        seen += filter.flush()
        return seen
    }

    func testOrdinaryTextStreamsThroughUnchanged() {
        XCTAssertEqual(streamed(["It is ", "sunny ", "in Auckland."]), "It is sunny in Auckland.")
    }

    func testTagSplitAcrossChunksNeverReachesThePreview() {
        let chunks = ["Sure. ", "<tool_", "call>{\"na", "me\": \"get_weather\", ", "\"arguments\": {}}", "</tool_", "call>"]
        let seen = streamed(chunks)
        XCTAssertFalse(seen.contains("<tool_call>"))
        XCTAssertFalse(seen.contains("tool_"))
        XCTAssertFalse(seen.contains("get_weather"))
        XCTAssertEqual(seen.trimmingCharacters(in: .whitespaces), "Sure.")
    }

    func testUnterminatedFrameIsNeverReleasedAtFlush() {
        let seen = streamed(["Checking. ", "<tool_call>{\"name\": \"get_we"])
        XCTAssertEqual(seen.trimmingCharacters(in: .whitespaces), "Checking.")
    }

    func testBareCallObjectIsHeldBackAndSuppressed() {
        let seen = streamed([#"{"name": "#, #""get_weather", "arguments""#, #": {}}"#])
        XCTAssertEqual(seen, "")
    }

    func testLineInitialBraceThatIsNotACallIsReleased() {
        let raw = #"{"city": "Auckland"} is the payload."#
        XCTAssertEqual(streamed([raw]), raw)
    }

    func testMidSentenceBraceIsNeverHeld() {
        let raw = #"Send {"name": "x"} to the runner."#
        XCTAssertEqual(streamed([raw]), raw)
    }

    func testHoldbackIsAtMostAFewCharactersForOrdinaryText() {
        // The only thing a chunk ending in "<" can be is an unfinished tag, so one character is
        // held; everything before it is released immediately.
        let filter = LocalProtocolStreamFilter()
        XCTAssertEqual(filter.ingest("The answer is 42 <"), "The answer is 42 ")
        XCTAssertEqual(filter.ingest("b>bold"), "<b>bold")
    }

    func testPreviewResumesAfterAFrameCloses() {
        let seen = streamed(["Checking. ", validFrame, " Done."])
        XCTAssertEqual(seen, "Checking. Done.")
    }
}
