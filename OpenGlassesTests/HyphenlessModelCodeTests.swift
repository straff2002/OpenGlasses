import XCTest
@testable import OpenGlasses

/// Cloud dictation writes a trade code without its hyphens whatever the vocabulary prompt says
/// ("QZ4417" for a manual's "QZ-4417"), and a technician typing a question leaves them out too.
/// A code written without its hyphens is the printed code: it reaches the same model section and
/// the same manual passages. Only the hyphens are optional — the shape screen and the length
/// floors are unchanged, so a short code or a fault code matches no more than it did.
///
/// Pure, over invented model numbers.
final class HyphenlessModelCodeTests: XCTestCase {

    private static let models = """
    # Models — QZ series

    ## QZ-4417 (QZV-4417-60B; 17 in. cabinet)
    ## QZ-5520 (QZV-5520-60C; 21 in. cabinet)

    The condensate kit KT-3308 fits both cabinets.
    """

    private let index = VaultModelIndex(vaultName: "Invented QZ Furnace Service",
                                        files: [("models.md", models)])

    private func names(_ models: [VaultModelIndex.Model]) -> [String] { models.map(\.name) }

    // MARK: - Model index

    func testACodeWithoutItsHyphenResolvesToThePrintedModel() {
        XCTAssertEqual(names(index.resolve(token: "QZ-4417")), ["QZ-4417"], "the printed spelling, as before")
        XCTAssertEqual(names(index.resolve(token: "QZ4417")), ["QZ-4417"], "transcribed without the hyphen")
        XCTAssertEqual(names(index.resolve(token: "qz4417")), ["QZ-4417"])
    }

    func testAMultiHyphenSpellingResolvesWithoutItsHyphens() {
        XCTAssertEqual(names(index.resolve(token: "QZV-4417-60B")), ["QZ-4417"])
        XCTAssertEqual(names(index.resolve(token: "QZV441760B")), ["QZ-4417"])
        XCTAssertEqual(names(index.resolve(token: "QZV4417-60B")), ["QZ-4417"], "one hyphen of two")
    }

    func testASentenceNamingTheCodeWithoutItsHyphenMatchesOneModel() {
        XCTAssertEqual(names(index.match(text: "what's the gas valve setting on the QZ4417")), ["QZ-4417"])
        XCTAssertEqual(names(index.match(text: "nameplate says QZV 5520 60C, model QZ5520")), ["QZ-5520"])
    }

    func testACorrectionSaidWithoutTheHyphenReachesTheModel() {
        XCTAssertEqual(names(index.match(fragment: "QZ4417")), ["QZ-4417"])
        XCTAssertEqual(names(index.match(fragment: "5520")), ["QZ-5520"], "a part said alone, as before")
    }

    func testTheVaultKnowsAProseCodeWithoutItsHyphen() {
        XCTAssertTrue(index.isKnown(token: "QZ4417"))
        XCTAssertTrue(index.isKnown(token: "KT3308"), "an accessory printed only in prose")
        XCTAssertTrue(index.mentions(token: "KT3308"))
        XCTAssertFalse(index.isKnown(token: "QZ4418"), "another number is still another machine")
    }

    func testTheShapeScreenAndLengthFloorsAreUnchanged() {
        XCTAssertFalse(VaultModelIndex.isModelLike("R454B"), "a refrigerant is never a machine")
        XCTAssertFalse(VaultModelIndex.isModelLike("E223"), "a fault code is never a machine")
        XCTAssertEqual(index.resolve(token: "Q4"), [], "too short to reach a model by substring")
        XCTAssertEqual(index.resolve(token: "44"), [])
    }

    // MARK: - Manual text

    func testACodeWithoutItsHyphenFindsThePrintedCodeInManualText() {
        let page = "Set the gas valve on the QZ-4417 to 3.5 in. w.c."
        XCTAssertTrue(CodeTokenizer.contains(page, token: "QZ-4417"))
        XCTAssertTrue(CodeTokenizer.contains(page, token: "QZ4417"))
        XCTAssertTrue(CodeTokenizer.contains("Kit for QZV-4417-60B only", token: "QZV441760B"))
        XCTAssertTrue(CodeTokenizer.contains("Refrigerant: R-454B (A2L).", token: "R454B"))
    }

    func testAPrintedHyphenlessCodeIsFoundByItsHyphenatedSpelling() {
        // The model scope searches passages for a heading's spellings, hyphens and all.
        XCTAssertTrue(CodeTokenizer.contains("Replace the QZ4417 inducer.", token: "QZ-4417"))
    }

    func testTheHyphenlessSearchStaysAWholeCode() {
        XCTAssertFalse(CodeTokenizer.contains("Kit for QZV-4417-60B only", token: "QZ4417"),
                       "part of a longer code is another code")
        XCTAssertFalse(CodeTokenizer.contains("Kit for QZV-4417-60B only", token: "QZV4417"))
        XCTAssertFalse(CodeTokenizer.contains("See the QZ-44170 chart", token: "QZ4417"))
        XCTAssertFalse(CodeTokenizer.contains("Rows 7-9 of table 4", token: "79"), "a range is not a number")
        XCTAssertFalse(CodeTokenizer.contains("Code E-5 means open limit", token: "E5"), "short codes stay exact")
        XCTAssertFalse(CodeTokenizer.contains("Rule 26-700 applies", token: "26700"), "a clause has no letter")
    }

    func testTheExistingWholeTokenRulesAreKept() {
        XCTAssertTrue(CodeTokenizer.contains("code E5 means", token: "E5"))
        XCTAssertFalse(CodeTokenizer.contains("code E50 means", token: "E5"))
        XCTAssertTrue(CodeTokenizer.contains("Kit for QZV-4417-60B only", token: "4417"),
                      "a hyphen still separates words for a part searched as itself")
    }
}
