import XCTest
@testable import OpenGlasses

/// Pins the CXR-M vocabulary against the decompiled `client-m` 1.0.8 reference.
final class RokidCXRProtocolTests: XCTestCase {

    // MARK: - Channels

    func testChannelsMatchTheDocumentedNamespaces() {
        XCTAssertEqual(RokidCXRChannel.allCases.map(\.rawValue),
                       ["Dev", "Ai", "Med", "Sys", "Trans", "Settings", "ARTC"])
    }

    // MARK: - Caps type tags

    func testCapsTypeTagsAreTheSDKCharacters() {
        XCTAssertEqual(RokidCapsValue.void.typeTag, "V")
        XCTAssertEqual(RokidCapsValue.int32(1).typeTag, "i")
        XCTAssertEqual(RokidCapsValue.uint32(1).typeTag, "u")
        XCTAssertEqual(RokidCapsValue.int64(1).typeTag, "l")
        XCTAssertEqual(RokidCapsValue.uint64(1).typeTag, "k")
        XCTAssertEqual(RokidCapsValue.float(1).typeTag, "f")
        XCTAssertEqual(RokidCapsValue.double(1).typeTag, "d")
        XCTAssertEqual(RokidCapsValue.string("x").typeTag, "S")
        XCTAssertEqual(RokidCapsValue.binary(Data()).typeTag, "B")
        XCTAssertEqual(RokidCapsValue.object([]).typeTag, "O")
    }

    // MARK: - Ai channel

    func testTTSIsAnAiResultCarryingPlainText() {
        let command = RokidCXRCommand.tts("hello")
        XCTAssertEqual(command.channel, .ai)
        XCTAssertEqual(command.command, "TTS_Result")
        XCTAssertEqual(command.arguments, [.string("hello")])
    }

    func testASRVariantsUseTheDocumentedCommandNames() {
        XCTAssertEqual(RokidCXRCommand.asrResult("hi").command, "ASR_Result")
        XCTAssertEqual(RokidCXRCommand.asrNone().command, "ASR_None")
        XCTAssertEqual(RokidCXRCommand.asrEnd().command, "ASR_End")
        XCTAssertEqual(RokidCXRCommand.asrError().command, "ASR_Error")
        XCTAssertEqual(RokidCXRCommand.asrNone().arguments, [])
    }

    func testTakePhotoCarriesGeometryAsJSON() {
        let command = RokidCXRCommand.takePhoto(width: 640, height: 480)
        XCTAssertEqual(command.channel, .ai)
        XCTAssertEqual(command.command, "Ai_TakePhoto")
        guard case .string(let payload)? = command.arguments.first else {
            return XCTFail("expected a JSON string argument")
        }
        XCTAssertTrue(payload.contains("\"width\":640"))
        XCTAssertTrue(payload.contains("\"height\":480"))
    }

    func testExitCarriesTheSessionCountAsInt32() {
        let command = RokidCXRCommand.exit(sessionCount: 3)
        XCTAssertEqual(command.command, "Exit")
        XCTAssertEqual(command.arguments, [.int32(3)])
    }

    // MARK: - Dev channel

    func testBrightnessAndVolumeClampToTheDocumentedRange() {
        XCTAssertEqual(RokidCXRCommand.brightness(99).arguments, [.uint32(15)])
        XCTAssertEqual(RokidCXRCommand.brightness(-4).arguments, [.uint32(0)])
        XCTAssertEqual(RokidCXRCommand.brightness(7).arguments, [.uint32(7)])
        XCTAssertEqual(RokidCXRCommand.volume(99).arguments, [.uint32(15)])
        XCTAssertEqual(RokidCXRCommand.volume(-1).arguments, [.uint32(0)])
    }

    func testDeviceCommandsUseTheDevChannel() {
        XCTAssertEqual(RokidCXRCommand.brightness(1).channel, .dev)
        XCTAssertEqual(RokidCXRCommand.volume(1).channel, .dev)
        XCTAssertEqual(RokidCXRCommand.timeUpdate(timeZone: "UTC", milliseconds: 0).channel, .dev)
        XCTAssertEqual(RokidCXRCommand.timeUpdate(timeZone: "UTC", milliseconds: 5).command,
                       "Dev_TimeUpdate")
    }

    // MARK: - Text display and settings

    func testWordTipsIsTheDocumentedTextPath() {
        let config = RokidCXRCommand.wordTipsConfig(["lines": 3])
        XCTAssertEqual(config.channel, .sys)
        XCTAssertEqual(config.command, "WordTips_SetTvConfig")

        let content = RokidCXRCommand.wordTipsContent(asr: "caption")
        XCTAssertEqual(content.channel, .sys)
        XCTAssertEqual(content.command, "WordTips_AiContent")
        guard case .string(let payload)? = content.arguments.first else {
            return XCTFail("expected a JSON string argument")
        }
        XCTAssertTrue(payload.contains("\"asr\":\"caption\""))
    }

    func testTranslationResultCarriesTheStructuredFields() {
        let command = RokidCXRCommand.translationResult(id: 7, result: "bonjour")
        XCTAssertEqual(command.channel, .trans)
        XCTAssertEqual(command.command, "Trans_Result")
        guard case .string(let payload)? = command.arguments.first else {
            return XCTFail("expected a JSON string argument")
        }
        XCTAssertTrue(payload.contains("\"id\":7"))
        XCTAssertTrue(payload.contains("\"result\":\"bonjour\""))
        XCTAssertTrue(payload.contains("\"finished\":true"))
    }

    func testSettingsUpdateRendersAJSONArray() {
        let command = RokidCXRCommand.settingsUpdate([("settings_photo_width", "640")])
        XCTAssertEqual(command.channel, .settings)
        XCTAssertEqual(command.command, "Settings_Update")
        guard case .string(let payload)? = command.arguments.first else {
            return XCTFail("expected a JSON string argument")
        }
        XCTAssertTrue(payload.hasPrefix("["))
        XCTAssertTrue(payload.contains("\"key\":\"settings_photo_width\""))
        XCTAssertTrue(payload.contains("\"value\":\"640\""))
    }

    // MARK: - Regression guard

    /// The legacy `{"cmd","key","param"}` model is deliberately separate; nothing here may
    /// regress the vocabulary to the old category names.
    func testNoCommandUsesTheLegacyCategoryPrefixes() {
        let commands = [
            RokidCXRCommand.aiStart(),
            RokidCXRCommand.tts("x"),
            RokidCXRCommand.takePhoto(width: 1, height: 1),
            RokidCXRCommand.wordTipsContent(asr: "x"),
            RokidCXRCommand.translationResult(id: 1, result: "x"),
            RokidCXRCommand.brightness(1),
            RokidCXRCommand.artcStop(),
        ]
        let legacy = ["Custom_View", "Ntf", "Tts_SendPlayTts"]
        for command in commands {
            XCTAssertFalse(legacy.contains(command.command),
                           "\(command.command) regressed to the legacy vocabulary")
        }
    }
}
