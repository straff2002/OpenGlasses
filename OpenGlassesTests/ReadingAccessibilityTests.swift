import XCTest
@testable import OpenGlasses

/// Tests for ReadingProfile persistence, ReadingMode directives, and the equipment_lookup
/// OCR-token heuristic.
final class ReadingAccessibilityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLevel")
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLanguage")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLevel")
        UserDefaults.standard.removeObject(forKey: "accessibilityReadingLanguage")
        super.tearDown()
    }

    // MARK: - ReadingProfile

    func testReadingLevelDefaultsToAdult() {
        XCTAssertEqual(ReadingProfile.level, .adult)
    }

    func testReadingLevelPersists() {
        ReadingProfile.setLevel(.child)
        XCTAssertEqual(ReadingProfile.level, .child)
        ReadingProfile.setLevel(.professional)
        XCTAssertEqual(ReadingProfile.level, .professional)
    }

    func testPreferredLanguagePersists() {
        ReadingProfile.setPreferredLanguage("es")
        XCTAssertEqual(ReadingProfile.preferredLanguage, "es")
        XCTAssertEqual(ReadingProfile.languageName(for: "es"), "Spanish")
    }

    // MARK: - ReadingMode

    func testModeParsingIsCaseInsensitive() {
        XCTAssertEqual(ReadingMode(rawValue: "READ"), .read)
        XCTAssertEqual(ReadingMode(rawValue: "Translate"), .translate)
        XCTAssertNil(ReadingMode(rawValue: "bogus"))
    }

    func testSimplifyDirectiveReflectsLevel() {
        let directive = ReadingMode.simplify.directive(level: .child)
        XCTAssertTrue(directive.contains("SIMPLIFY"))
        XCTAssertTrue(directive.contains("6–10"), "Got: \(directive)")
    }

    func testTranslateDirectiveNamesTargetLanguage() {
        let directive = ReadingMode.translate.directive(targetLanguage: "fr")
        XCTAssertTrue(directive.contains("TRANSLATE"))
        XCTAssertTrue(directive.contains("French"), "Got: \(directive)")
    }

    func testTranslateDirectiveFallsBackToProfileLanguage() {
        ReadingProfile.setPreferredLanguage("de")
        let directive = ReadingMode.translate.directive()
        XCTAssertTrue(directive.contains("German"), "Got: \(directive)")
    }

    func testReadAndDefineDirectivesAreDistinct() {
        XCTAssertTrue(ReadingMode.read.directive().contains("READ ALOUD"))
        XCTAssertTrue(ReadingMode.define.directive().contains("under 40 words"))
    }

    // MARK: - equipment_lookup OCR token heuristic

    @MainActor
    func testCandidateTokensExtractsCodesAndModels() {
        let tool = EquipmentLookupTool()
        let tokens = tool.candidateTokens(from: "DAIKIN\nMODEL RXS24\nERROR E5\n!!! 12")
        XCTAssertTrue(tokens.contains("DAIKIN"))
        XCTAssertTrue(tokens.contains("RXS24"))
        XCTAssertTrue(tokens.contains("E5"))
        XCTAssertTrue(tokens.contains("12"))
    }

    @MainActor
    func testCandidateTokensDropsNoiseAndDuplicates() {
        let tool = EquipmentLookupTool()
        let tokens = tool.candidateTokens(from: "E5 e5 a thisisaverylongtokenover14chars ##")
        XCTAssertEqual(tokens.filter { $0.uppercased() == "E5" }.count, 1) // de-duped case-insensitively
        XCTAssertFalse(tokens.contains("a"))  // too short
        XCTAssertFalse(tokens.contains { $0.count > 14 })
    }
}
