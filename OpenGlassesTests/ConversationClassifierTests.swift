import XCTest
@testable import OpenGlasses

/// Tests for the three-tier conversation classification system.
/// Tier 0: Direct tool calls (skip LLM). Tier 1: Prompt section detection. Tier 2: Complexity/model tier.
final class ConversationClassifierTests: XCTestCase {

    private let classifier = ConversationClassifier()

    // MARK: - Tier 0: Direct Tool Calls

    func testTimeQueriesMatchDirectly() {
        let queries = ["what time is it", "what's the time", "current time", "what day is it", "what's the date"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "get_datetime",
                           "'\(query)' should directly call get_datetime")
            XCTAssertEqual(result.complexity, 0.0)
            XCTAssertEqual(result.modelTier, .fast)
        }
    }

    func testStepCountMatchesDirectly() {
        let queries = ["how many steps", "step count", "steps today"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "step_count",
                           "'\(query)' should directly call step_count")
        }
    }

    func testBatteryMatchesDirectly() {
        let queries = ["battery level", "how much battery", "battery percentage"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "device_info",
                           "'\(query)' should directly call device_info")
        }
    }

    /// Live-traced (calendar-for-tomorrow): the 2B local model only ever called calendar with
    /// the default "today", then interrogated the user for a date, then denied having access.
    /// Informational calendar questions now route deterministically with the right action.
    func testCalendarLookupsMatchDirectlyWithDayAction() {
        let cases: [(String, String)] = [
            ("do i have anything in my calendar for tomorrow", "tomorrow"),
            ("have i got anything on my calendar tomorrow", "tomorrow"),
            ("what's on my schedule today", "today"),
            ("do i have any meetings this week", "upcoming"),
            ("what's my next meeting", "next"),
            ("am i free tomorrow according to my calendar", "tomorrow"),
        ]
        for (query, action) in cases {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "calendar",
                           "'\(query)' should directly call calendar")
            XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, action,
                           "'\(query)' should pick action '\(action)'")
        }
    }

    // MARK: - New topic (hands-free context clear)

    func testNewTopicCommandsMatchDirectly() {
        for query in ["new topic",
                      "let's start a new topic",
                      "start over",
                      "can we start fresh",
                      "clear the conversation",
                      "okay new conversation",
                      "forget this conversation"] {
            XCTAssertEqual(classifier.classify(query).directToolCall?.toolName, "new_topic",
                           "'\(query)' should directly clear context")
        }
    }

    /// "New topic" as CONTENT (not a command) must reach the LLM — a substring match here
    /// would wipe the user's conversation mid-thought.
    func testNewTopicInsideContentDoesNotMatch() {
        for query in ["suggest a new topic for my essay",
                      "write about a new topic in quantum computing",
                      "when we start over in january what changes",
                      "help me start over with this recipe from step three"] {
            XCTAssertNil(classifier.classify(query).directToolCall,
                         "'\(query)' is content, not a reset command")
        }
    }

    // MARK: - Scan Assist (Plan FB P2)

    func testScanAssistControlPhrasesRouteToTheToolWithTheRightAction() {
        let cases: [(String, String)] = [
            ("start scan reminders", "start"),
            ("start my scan reminders please", "start"),
            ("turn on scan assist", "start"),
            ("pause scan reminders", "pause"),
            ("pause the scan reminders", "pause"),
            ("resume scan reminders", "resume"),
            ("continue scan reminders", "resume"),
            ("stop scan reminders", "stop"),
            ("stop the scan reminders now", "stop"),
            ("turn off scan assist", "stop"),
        ]
        for (query, action) in cases {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "scan_assist",
                           "'\(query)' should reach scan_assist without a model")
            XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, action,
                           "'\(query)' should pick action '\(action)'")
        }
    }

    func testAskingForASideSetsThatSide() {
        for (query, side) in [("remind me to check my left", "left"),
                              ("remind me to check left", "left"),
                              ("remind me to check my right", "right"),
                              ("switch the reminders to the left", "left"),
                              ("move the reminders to my right", "right")] {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "scan_assist")
            XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "set_side")
            XCTAssertEqual(result.directToolCall?.arguments["side"] as? String, side,
                           "'\(query)' names \(side) and nothing else may decide that")
        }
    }

    /// Ambiguous phrasing routes to the tool *without* a side, so the tool asks. Guessing here
    /// would send someone to practise the side they did not choose.
    func testAmbiguousSidePhrasesCarryNoSide() {
        for query in ["remind me to check the other side",
                      "remind me to check",
                      "remind me to check left or right"] {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "scan_assist",
                           "'\(query)' should still be answered deterministically")
            XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "set_side")
            XCTAssertNil(result.directToolCall?.arguments["side"],
                         "'\(query)' does not name a side, so nothing may supply one")
        }
    }

    /// "right now" is a time word far more often than a side.
    func testRightNowIsNotReadAsASide() {
        let result = classifier.classify("remind me to check right now")
        XCTAssertEqual(result.directToolCall?.toolName, "scan_assist")
        XCTAssertNil(result.directToolCall?.arguments["side"])
    }

    func testAskingWhichSideIsAnsweredDeterministically() {
        for query in ["which side am i checking", "what side am i checking",
                      "which side are my reminders on"] {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "scan_assist", "'\(query)'")
            XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "status")
        }
    }

    /// Bare-query gated like `new_topic`: the same words inside a real sentence are content, and
    /// must reach the LLM rather than silently moving someone's reminders.
    func testScanAssistWordsInsideContentDoNotMatch() {
        for query in ["remind me to check the oven before we leave",
                      "remind me to check my email at four",
                      "write a note about how to stop scan reminders in the manual"] {
            XCTAssertNil(classifier.classify(query).directToolCall,
                         "'\(query)' is content, not a Scan Assist command")
        }
    }

    /// Creation and modification must still reach the LLM — they need title/time extraction.
    func testCalendarMutationsDoNotMatchDirectly() {
        for query in ["add a meeting to my calendar tomorrow at 3pm",
                      "schedule a dentist appointment for tomorrow",
                      "cancel my meeting tomorrow"] {
            XCTAssertNil(classifier.classify(query).directToolCall,
                         "'\(query)' must reach the LLM for extraction")
        }
    }

    func testMusicPauseMatchesDirectly() {
        let result = classifier.classify("pause")
        XCTAssertEqual(result.directToolCall?.toolName, "music_control")
        XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "pause")
    }

    func testMusicNextMatchesDirectly() {
        let result = classifier.classify("next song")
        XCTAssertEqual(result.directToolCall?.toolName, "music_control")
        XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "next")
    }

    func testNowPlayingMatchesDirectly() {
        let result = classifier.classify("what's playing")
        XCTAssertEqual(result.directToolCall?.toolName, "music_control")
        XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "now_playing")
    }

    func testFlashlightOnMatchesDirectly() {
        let result = classifier.classify("flashlight on")
        XCTAssertEqual(result.directToolCall?.toolName, "flashlight")
        XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "on")
    }

    func testFlashlightOffMatchesDirectly() {
        let result = classifier.classify("turn off the flashlight")
        XCTAssertEqual(result.directToolCall?.toolName, "flashlight")
        XCTAssertEqual(result.directToolCall?.arguments["action"] as? String, "off")
    }

    func testAmbiguousQueryDoesNotMatchDirectly() {
        let queries = [
            "tell me about the weather",
            "help me plan my day",
            "what's the meaning of life",
            "can you explain quantum physics",
        ]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertNil(result.directToolCall,
                         "'\(query)' should not match a direct tool call")
        }
    }

    /// A larger question that merely *contains* a Tier-0 pattern must reach the LLM —
    /// a substring match would speak the current time/date as the "answer".
    func testEmbeddedPatternsDoNotShortCircuitToDirectCall() {
        let queries = [
            "what time does the game start",
            "what day is the concert",
            "what time is sunset in tokyo",
            "how much battery does my tesla have",
            "how many steps are in this recipe",
        ]
        for query in queries {
            XCTAssertNil(classifier.classify(query).directToolCall,
                         "'\(query)' should go to the LLM, not a direct tool call")
        }
    }

    func testBareQueriesWithFillerStillMatchDirectly() {
        XCTAssertEqual(classifier.classify("what time is it right now").directToolCall?.toolName, "get_datetime")
        XCTAssertEqual(classifier.classify("hey what's the date today").directToolCall?.toolName, "get_datetime")
        XCTAssertEqual(classifier.classify("how's my phone battery").directToolCall?.toolName, "device_info")
    }

    // MARK: - Tier 1: Prompt Section Detection

    func testVisionSectionDetectedForImageInput() {
        let result = classifier.classify("what is this?", hasImage: true)
        XCTAssertTrue(result.relevantSections.contains(.vision))
    }

    func testVisionSectionDetectedForVisionKeywords() {
        let queries = ["look at this", "read this sign", "what do you see", "scan the barcode"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.vision),
                          "'\(query)' should include vision section")
        }
    }

    func testLocationSectionDetectedForLocationKeywords() {
        let queries = ["restaurants nearby", "find a pharmacy near me", "directions to the airport"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.location),
                          "'\(query)' should include location section")
        }
    }

    /// Weather is implicitly about "here": without the .location section the send path passes
    /// locationContext = nil, the prompt has no USER LOCATION line, and the on-device model
    /// asks "what city are you in?" instead of answering.
    func testWeatherQueriesIncludeLocationSection() {
        // Contract updated 2026-07-15 (live-traced): BARE weather questions are tier-0
        // direct get_weather calls now — a 2B local model asked to tool-call stalls in
        // ever-new phrasings. Weather-ADJACENT questions still reach the LLM with
        // .location (+ .weather pre-fetch).
        for query in ["what's the weather", "weather forecast for tomorrow"] {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "get_weather",
                           "'\(query)' is a bare weather question — tier-0")
        }
        let queries = [
            "will it rain today", "do i need an umbrella",
            "when is sunset", "how hot is it today",
        ]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertNil(result.directToolCall, "'\(query)' should reach the LLM, not a direct tool")
            XCTAssertTrue(result.relevantSections.contains(.location),
                          "'\(query)' should include location section")
        }
    }

    func testSmartHomeSectionDetectedForHomeKeywords() {
        let queries = ["turn on the lights", "set thermostat to 22", "lock the front door"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.smartHome),
                          "'\(query)' should include smart home section")
        }
    }

    func testToolsSectionIncludedForToolKeywords() {
        // "what's the weather" moved to tier-0 (see above) — swapped for another tool phrase.
        let queries = ["set a timer for 5 minutes", "take a note about the meeting", "remind me tomorrow"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.tools),
                          "'\(query)' should include tools section")
        }
    }

    func testGatewaySectionDetectedForGatewayKeywords() {
        let queries = ["on my computer", "send on slack", "check my email"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.openClaw),
                          "'\(query)' should include OpenClaw section")
        }
    }

    // MARK: - CJK (no-space scripts)

    /// English-only patterns + space-split word counts used to classify every CJK query as
    /// trivial (one "word" → fast tier → 2B local model) with no location/smart-home sections.
    func testChineseWeatherQueryIncludesLocationAndTools() {
        let result = classifier.classify("今天天气怎么样")
        XCTAssertTrue(result.relevantSections.contains(.location), "天气 should include location")
        XCTAssertTrue(result.relevantSections.contains(.tools), "天气 should include tools")
    }

    func testChineseSmartHomeDetected() {
        XCTAssertTrue(classifier.classify("帮我开灯").relevantSections.contains(.smartHome))
    }

    func testChineseComplexQueryIsNotFastTier() {
        // Analysis + comparison + chaining in one long sentence — must not route to the fast tier.
        let result = classifier.classify("帮我分析一下这两种方案的优缺点然后推荐一个")
        XCTAssertNotEqual(result.modelTier, .fast,
                          "long analytical Chinese query must not be scored as trivial")
    }

    func testChineseGreetingStaysFastTier() {
        XCTAssertEqual(classifier.classify("你好").modelTier, .fast)
    }

    func testUnspecificQueryDefaultsToTools() {
        let result = classifier.classify("tell me a joke")
        XCTAssertTrue(result.relevantSections.contains(.tools),
                      "Unspecific queries should default to including tools")
    }

    // MARK: - Tier 2: Complexity Estimation

    func testShortSimpleQueryIsLowComplexity() {
        let result = classifier.classify("hello")
        XCTAssertLessThanOrEqual(result.complexity, 0.2)
        XCTAssertEqual(result.modelTier, .fast)
    }

    func testGreetingsAreLowComplexity() {
        let queries = ["yes", "no", "ok", "thanks", "good morning"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertLessThanOrEqual(result.complexity, 0.2,
                                     "'\(query)' should be low complexity")
        }
    }

    func testImageInputIncreasesComplexity() {
        let withoutImage = classifier.classify("describe what you see")
        let withImage = classifier.classify("describe what you see", hasImage: true)
        XCTAssertGreaterThan(withImage.complexity, withoutImage.complexity)
    }

    func testLongRequestsHaveHigherComplexity() {
        let short = classifier.classify("weather")
        let long = classifier.classify("can you help me plan a comprehensive workout routine that targets upper body strength while also incorporating some cardio elements and stretching at the end")
        XCTAssertGreaterThan(long.complexity, short.complexity)
    }

    func testChainingIndicatorsIncreaseComplexity() {
        let simple = classifier.classify("set a timer")
        let chained = classifier.classify("set a timer and then remind me to call john after that")
        XCTAssertGreaterThan(chained.complexity, simple.complexity)
    }

    func testReasoningIndicatorsIncreaseComplexity() {
        let simple = classifier.classify("what is a banana")
        let reasoning = classifier.classify("explain why bananas are curved and what are the pros and cons of eating them daily")
        XCTAssertGreaterThan(reasoning.complexity, simple.complexity)
    }

    func testConversationDepthIncreasesComplexity() {
        let fresh = classifier.classify("tell me more", conversationTurnCount: 0)
        let deep = classifier.classify("tell me more", conversationTurnCount: 10)
        XCTAssertGreaterThanOrEqual(deep.complexity, fresh.complexity)
    }

    func testComplexityClampedTo0And1() {
        // Very simple
        let simple = classifier.classify("ok")
        XCTAssertGreaterThanOrEqual(simple.complexity, 0.0)

        // Very complex
        let complex = classifier.classify(
            "analyze and compare the differences between these approaches, explain why one is better, and then organize my schedule around that decision",
            hasImage: true,
            conversationTurnCount: 10
        )
        XCTAssertLessThanOrEqual(complex.complexity, 1.0)
    }

    // MARK: - Model Tier Assignment

    func testFastTierForTrivialRequests() {
        let result = classifier.classify("thanks")
        XCTAssertEqual(result.modelTier, .fast)
    }

    func testBestTierForComplexRequests() {
        let result = classifier.classify(
            "analyze this image and compare it with what we discussed earlier, then summarize your recommendations",
            hasImage: true,
            conversationTurnCount: 8
        )
        XCTAssertEqual(result.modelTier, .best)
    }

    // MARK: - Direct Tool Call Has Minimal Sections

    func testDirectToolCallUsesMinimalSections() {
        let result = classifier.classify("what time is it")
        XCTAssertNotNil(result.directToolCall)
        XCTAssertEqual(result.relevantSections, .minimal)
    }
}
