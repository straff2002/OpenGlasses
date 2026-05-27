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

    func testSmartHomeSectionDetectedForHomeKeywords() {
        let queries = ["turn on the lights", "set thermostat to 22", "lock the front door"]
        for query in queries {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.smartHome),
                          "'\(query)' should include smart home section")
        }
    }

    func testToolsSectionIncludedForToolKeywords() {
        let queries = ["set a timer for 5 minutes", "what's the weather", "remind me tomorrow"]
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
