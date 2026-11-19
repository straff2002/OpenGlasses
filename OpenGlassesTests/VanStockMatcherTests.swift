import XCTest
@testable import OpenGlasses

/// Plan IH P0 — what was said finds one line, several, or none; it never picks.
final class VanStockMatcherTests: XCTestCase {

    private func item(_ id: String, number: String? = nil, _ description: String,
                      codes: [String] = [], bin: String? = nil) -> VanStockItem {
        VanStockItem(id: id, number: number, description: description, bin: bin, codes: codes,
                     createdBatch: "b0")
    }

    private lazy var sensor = item("sensor", number: "62-23543-01", "Flame sensor", codes: ["0123456789012"])
    private lazy var dualRun = item("dual", "Capacitor, dual run, 45/5 µF 440 V")
    private lazy var singleRun = item("single", "Capacitor, run, 5 µF 440 V")
    private lazy var igniter = item("igniter", number: "22B22", "Igniter")
    private lazy var oldIgniter = item("old-igniter", number: "21B21", "Igniter, old pattern")

    private var index: VaultPartsIndex {
        VaultPartsIndex(files: [("parts.md", """
        | Part | Description | Fits | Supersedes |
        |---|---|---|---|
        | 22B22 | Igniter | RTU-500 | 21B21 |
        """)])
    }

    func testAScannedCodeAlreadyOnALineWins() {
        let matcher = VanStockMatcher(items: [dualRun, sensor])
        XCTAssertEqual(matcher.match(code: "0123456789012"), .one(sensor))
        XCTAssertEqual(matcher.match(code: "9999999999999"), .none)
    }

    func testTheNumberMatchesExactlyHoweverItWasSaid() {
        let matcher = VanStockMatcher(items: [dualRun, sensor])
        XCTAssertEqual(matcher.match(number: "62-23543-01"), .one(sensor))
        XCTAssertEqual(matcher.match(number: " #62-23543-01. "), .one(sensor))
        XCTAssertEqual(matcher.match(number: "62-23543-02"), .none)
    }

    func testASupersededNumberFindsTheStockOfItsReplacement() {
        let matcher = VanStockMatcher(items: [sensor, igniter], partsIndex: index)
        XCTAssertEqual(matcher.match(number: "21B21"), .one(igniter))
    }

    func testTheNewNumberFindsOldStock() {
        let matcher = VanStockMatcher(items: [sensor, oldIgniter], partsIndex: index)
        XCTAssertEqual(matcher.match(number: "22B22"), .one(oldIgniter))
    }

    func testWithoutAVaultASupersededNumberMatchesNothing() {
        XCTAssertEqual(VanStockMatcher(items: [igniter]).match(number: "21B21"), .none)
    }

    func testDescriptionWordsFindALine() {
        let matcher = VanStockMatcher(items: [sensor, dualRun, singleRun])
        XCTAssertEqual(matcher.match(description: "45/5 capacitors"), .one(dualRun))
        XCTAssertEqual(matcher.match(description: "a flame sensor"), .one(sensor))
        XCTAssertEqual(matcher.match(description: "thermostat"), .none)
    }

    func testWordsGivenAsANumberAreStillWords() {
        let matcher = VanStockMatcher(items: [sensor, dualRun, singleRun])
        XCTAssertEqual(matcher.match(number: "45/5 capacitor"), .one(dualRun))
        XCTAssertEqual(matcher.match(number: "flame sensor"), .one(sensor))
    }

    func testSeveralCandidatesAreReturnedNeverChosen() {
        let matcher = VanStockMatcher(items: [sensor, dualRun, singleRun])
        XCTAssertEqual(matcher.match(description: "capacitor"), .several([dualRun, singleRun]))
        XCTAssertEqual(VanStockMatcher(items: [igniter, oldIgniter]).match(description: "igniter"),
                       .several([igniter, oldIgniter]))
    }

    func testADifferentNumberIsADifferentPartHoweverAlikeTheWords() {
        let matcher = VanStockMatcher(items: [sensor])
        XCTAssertEqual(matcher.match(number: "62-99999-01", description: "flame sensor"), .none)
    }

    func testANumberCanJoinALineThatHasNone() {
        let unnumbered = item("plain", "Flame sensor")
        XCTAssertEqual(VanStockMatcher(items: [unnumbered]).match(number: "62-23543-01", description: "flame sensor"),
                       .one(unnumbered))
    }

    func testNothingSaidMatchesNothing() {
        let matcher = VanStockMatcher(items: [sensor])
        XCTAssertEqual(matcher.match(), .none)
        XCTAssertEqual(matcher.match(number: " ", description: "the", code: ""), .none)
    }

    func testTokensDropPluralsAndFiller() {
        XCTAssertEqual(VanStockMatcher.tokens("some 45/5 Capacitors for the glass"), ["45", "5", "capacitor", "glass"])
    }

    // MARK: A tester's build-728 report — a brand heard as a common word, a number heard in pieces

    // Invented names and numbers throughout.
    private lazy var couplings = item("couplings", number: "71234", "Kwartz Coupling 6 x 250 mm")
    private lazy var lookalike = item("lookalike", "Kwarts Coupling 6 x 250 mm")
    private lazy var bracket = item("bracket", "Bracket 6250")
    private lazy var stud = item("stud", "Stud 2 x 4")
    private lazy var transformer = item("transformer", "Transformer 24 V")

    func testANumberHeardInPiecesIsAnExactMatch() {
        let matcher = VanStockMatcher(items: [sensor, couplings])
        XCTAssertEqual(matcher.match(description: "kwartz coupling 6 x 2 50"), .one(couplings))
        XCTAssertEqual(VanStockMatcher(items: [transformer]).match(description: "transformer 2 4 v"), .one(transformer))
    }

    func testAnXKeepsTheNumbersEitherSideApart() {
        XCTAssertEqual(VanStockMatcher(items: [bracket]).match(description: "bracket 6 x 2 50"), .none,
                       "6 is never joined to 250 across the x")
    }

    func testTheNumbersAsHeardAreAlwaysTriedToo() {
        XCTAssertEqual(VanStockMatcher(items: [stud]).match(description: "stud 2 4"), .one(stud))
        XCTAssertEqual(VanStockMatcher.saidTokens("6 x 2 50"), [["6", "x", "2", "50"], ["6", "x", "250"]])
    }

    func testABrandHeardAsTheWordItSoundsLikeIsANearMissNotAMatch() {
        let matcher = VanStockMatcher(items: [sensor, couplings, dualRun])
        XCTAssertEqual(matcher.match(description: "quartz coupling 6 x 2 50"), .near([couplings]))
        XCTAssertEqual(matcher.match(number: "quartz coupling 6 x 250"), .near([couplings]),
                       "words given where a number goes are near-matched the same way")
    }

    func testTwoLinesThatBothSoundLikeItAreBothGiven() {
        let matcher = VanStockMatcher(items: [couplings, sensor, lookalike])
        XCTAssertEqual(matcher.match(description: "quartz coupling 6 x 250"), .near([couplings, lookalike]))
    }

    func testANearMissIsNeverOnANumber() {
        let matcher = VanStockMatcher(items: [couplings])
        XCTAssertEqual(matcher.match(description: "kwartz coupling 6 x 251"), .none)
        XCTAssertEqual(matcher.match(description: "kwartz coupling 8 x 250"), .none)
    }

    func testAOneWordQueryNeverNearMisses() {
        let matcher = VanStockMatcher(items: [couplings, sensor])
        XCTAssertEqual(matcher.match(description: "quartz"), .none)
        XCTAssertEqual(matcher.match(description: "flame senser"), .none, "one word matched is not enough")
    }

    func testTwoWordsMisheardIsNotANearMiss() {
        XCTAssertEqual(VanStockMatcher(items: [couplings]).match(description: "quartz bracket 6 x 250"), .none)
    }

    func testAWordForWordMatchWinsOverANearOne() {
        let matcher = VanStockMatcher(items: [couplings, lookalike])
        XCTAssertEqual(matcher.match(description: "kwarts coupling 6 x 250"), .one(lookalike))
    }

    func testSoundsAlike() {
        XCTAssertEqual(VanStockMatcher.soundKey("quartz"), VanStockMatcher.soundKey("kwartz"))
        XCTAssertEqual(VanStockMatcher.soundKey("phlint"), VanStockMatcher.soundKey("flint"))
        XCTAssertTrue(VanStockMatcher.soundsAlike("senser", "sensor"))
        XCTAssertTrue(VanStockMatcher.soundsAlike("thermistor", "thermostor"))
        XCTAssertFalse(VanStockMatcher.soundsAlike("cap", "cat"), "under four letters it must sound the same")
        XCTAssertFalse(VanStockMatcher.soundsAlike("valve", "motor"))
        XCTAssertEqual(VanStockMatcher.distance("kitten", "sitting"), 3)
    }
}
