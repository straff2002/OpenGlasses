import XCTest
@testable import OpenGlasses

/// Plan GV P0 — the per-tool table and the sentences the model receives.
@MainActor
final class PhoneCapturePolicyTests: XCTestCase {

    // MARK: - The table

    func testFieldAssistAndVisionToolsAskOnThePhone() {
        for tool in ["capture_photo", "photo_log", "equipment_lookup", "manual_lookup",
                     "safety_assessment", "vision_assess", "scan_document", "document_knowledge",
                     "reading_assist", "look_closely", "smart_capture", "identify_medication",
                     "identify_money", "identify_color", "scan_code", "qr_context", "scan_badge",
                     "study", "teleprompter", "parking"] {
            XCTAssertEqual(PhoneCapturePolicy.route(forTool: tool), .askOnPhone, tool)
        }
    }

    func testLiveStreamToolsAndFaceRecognitionStayOnTheGlasses() {
        XCTAssertEqual(PhoneCapturePolicy.glassesOnlyTools,
                       ["face_recognition", "fitness_coach", "live_coach", "navigation_assist",
                        "video_recording", "record_clip", "pin_frame"])
    }

    func testAnUnknownToolAsksOnThePhoneRatherThanTakingAHiddenShot() {
        XCTAssertEqual(PhoneCapturePolicy.route(forTool: "some_future_tool"), .askOnPhone)
    }

    func testEveryAskOnPhoneToolHasAHint() {
        for tool in PhoneCapturePolicy.askOnPhoneTools {
            XCTAssertFalse(PhoneCapturePolicy.framingHint(forTool: tool).isEmpty, tool)
        }
        XCTAssertFalse(PhoneCapturePolicy.framingHint(forTool: nil).isEmpty)
    }

    // MARK: - Router budget

    func testBudgetGrowsByTheWaitOnlyWithTheGlassesAwayAndOnlyForAskOnPhoneTools() {
        let wait = PhoneCapturePolicy.requestTimeout + PhoneCapturePolicy.presentationGrace
        XCTAssertEqual(PhoneCapturePolicy.timeoutBudget(base: 30, toolName: "safety_assessment",
                                                        glassesConnected: false), 30 + wait)
        XCTAssertEqual(PhoneCapturePolicy.timeoutBudget(base: 30, toolName: "safety_assessment",
                                                        glassesConnected: true), 30)
        XCTAssertEqual(PhoneCapturePolicy.timeoutBudget(base: 30, toolName: "face_recognition",
                                                        glassesConnected: false), 30)
        XCTAssertEqual(PhoneCapturePolicy.timeoutBudget(base: 30, toolName: "get_weather",
                                                        glassesConnected: false), 30,
                       "a tool outside the table never waits on a photo, so keeps its budget")
    }

    func testRouterWidensTheDeclaredTimeoutAndKeepsTheRestOfTheContract() {
        let declared = ToolExecutionSemantics.read(.bestEffort, timeout: .seconds(45))
        let widened = NativeToolRouter.semantics(declared, toolName: "vision_assess",
                                                 glassesConnected: false, routerDefault: 30)
        XCTAssertEqual(widened.timeout, .seconds(45 + PhoneCapturePolicy.requestTimeout
                                                 + PhoneCapturePolicy.presentationGrace))
        XCTAssertEqual(widened.effect, declared.effect)
        XCTAssertEqual(widened.cancellation, declared.cancellation)
        XCTAssertEqual(widened.idempotency, declared.idempotency)

        let routerDefault = NativeToolRouter.semantics(.read(), toolName: "scan_code",
                                                       glassesConnected: false, routerDefault: 30)
        XCTAssertEqual(routerDefault.timeout, .seconds(30 + PhoneCapturePolicy.requestTimeout
                                                       + PhoneCapturePolicy.presentationGrace))

        XCTAssertEqual(NativeToolRouter.semantics(declared, toolName: "vision_assess",
                                                  glassesConnected: true, routerDefault: 30),
                       declared, "with glasses there is no phone wait to budget for")
    }

    // MARK: - Tiles

    func testCameraJobTilesOpenThePhoneCameraFirstOnlyWithoutGlasses() {
        for id in ["fa-fault-code", "fa-safety-check", "fa-log-photo"] {
            XCTAssertNotNil(PhoneCapturePolicy.preCaptureHint(forQuickAction: id, glassesConnected: false), id)
            XCTAssertNil(PhoneCapturePolicy.preCaptureHint(forQuickAction: id, glassesConnected: true), id)
        }
        XCTAssertNil(PhoneCapturePolicy.preCaptureHint(forQuickAction: "fa-order-part",
                                                       glassesConnected: false))
        XCTAssertNil(PhoneCapturePolicy.preCaptureHint(forQuickAction: "describe",
                                                       glassesConnected: false))
    }

    func testPreCaptureTilesExistAndNameAskOnPhoneTools() {
        let tileIds = Set(QuickAction.fieldAssistJobActions.map(\.id))
        for (tile, tool) in PhoneCapturePolicy.preCaptureTiles {
            XCTAssertTrue(tileIds.contains(tile), "\(tile) is not a Field Assist tile")
            XCTAssertEqual(PhoneCapturePolicy.route(forTool: tool), .askOnPhone, tool)
        }
    }

    // MARK: - Sentences (the contract with the model)

    func testEveryEndingWithoutAPhotoHasASentenceThatSaysNoPhotoWasTaken() {
        let endings: [PhonePhotoOutcome] = [.cancelled, .timedOut, .busy, .appNotOnScreen, .couldNotPresent]
        for outcome in endings {
            let sentence = try? XCTUnwrap(outcome.toolResultSentence)
            XCTAssertTrue(sentence?.contains("no photo was taken") == true
                          || sentence?.hasPrefix("No photo was taken") == true,
                          "\(outcome): \(sentence ?? "nil")")
            XCTAssertFalse(sentence?.isEmpty ?? true)
        }
        XCTAssertNil(PhonePhotoOutcome.photo(Data([1])).toolResultSentence)
    }

    func testCancelAndTimeoutTellTheModelNothingWasSeen() {
        XCTAssertEqual(PhonePhotoOutcome.cancelled.toolResultSentence,
                       "The user cancelled the phone camera, so no photo was taken. Nothing was seen — do not describe or guess what is in front of them.")
        XCTAssertEqual(PhonePhotoOutcome.timedOut.toolResultSentence,
                       "No photo was taken within 90 seconds, so the phone camera was closed. Nothing was seen — do not describe or guess what is in front of them.")
    }

    func testAPhotoErrorReadsAsItsSentence() {
        XCTAssertEqual(PhonePhotoError(outcome: .cancelled).localizedDescription,
                       PhonePhotoOutcome.cancelled.toolResultSentence)
    }

    func testCancelNeedsNoNoticeButTheOthersDo() {
        XCTAssertNil(PhonePhotoOutcome.cancelled.userNotice)
        for outcome in [PhonePhotoOutcome.timedOut, .busy, .appNotOnScreen, .couldNotPresent] {
            XCTAssertNotNil(outcome.userNotice, "\(outcome)")
        }
    }

    // MARK: - Result composition

    func testAMissedPhotoIsPrependedSoTheToolsOwnWordsSurvive() {
        let ledger = PhoneCaptureLedger()
        ledger.record(.cancelled)
        let result = PhoneCapturePolicy.toolResult("Saved the spot without a photo.", ledger: ledger)
        XCTAssertTrue(result.hasPrefix(PhonePhotoOutcome.cancelled.toolResultSentence!))
        XCTAssertTrue(result.hasSuffix("Saved the spot without a photo."))
    }

    func testAPhonePhotoIsNotedAfterTheResultAndTheImageMarkerStillParses() {
        let ledger = PhoneCaptureLedger()
        ledger.record(.photo(Data([1, 2, 3])))
        let raw = "[IMAGE_CAPTURED:\(Data([9, 9, 9]).base64EncodedString())] Photo captured."
        let result = PhoneCapturePolicy.toolResult(raw, ledger: ledger)
        XCTAssertTrue(result.hasSuffix(PhoneCapturePolicy.phonePhotoNote))
        XCTAssertEqual(ToolResultImage.extract(from: result).image, Data([9, 9, 9]))
    }

    func testANoPhoneCallIsUntouched() {
        XCTAssertEqual(PhoneCapturePolicy.toolResult("sunny", ledger: PhoneCaptureLedger()), "sunny")
    }

    func testTheFirstFailureIsKeptAndPhotosAreCounted() {
        let ledger = PhoneCaptureLedger()
        ledger.record(.photo(Data([1])))
        ledger.record(.timedOut)
        ledger.record(.cancelled)
        XCTAssertEqual(ledger.phonePhotos, 1)
        XCTAssertEqual(ledger.failure, .timedOut)
    }

    func testScopeTurnsAThrowAfterAMissedPhotoIntoTheSentence() async throws {
        struct Boom: Error {}
        let result = try await PhoneCaptureScope.run {
            PhoneCaptureScope.ledger?.record(.appNotOnScreen)
            throw Boom()
        }
        XCTAssertEqual(result, PhonePhotoOutcome.appNotOnScreen.toolResultSentence)

        do {
            _ = try await PhoneCaptureScope.run { throw Boom() }
            XCTFail("an unrelated error must still propagate")
        } catch is Boom {}
    }
}
