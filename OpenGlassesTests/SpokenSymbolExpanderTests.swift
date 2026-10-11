import XCTest
@testable import OpenGlasses

/// Symbols written out as words before a voice engine sees them.
final class SpokenSymbolExpanderTests: XCTestCase {

    private func expand(_ text: String, _ language: String = "en") -> String {
        SpokenSymbolExpander.expand(text, languageCode: language)
    }

    func testBrandPronunciationReachesSpeechWithAndWithoutSymbolExpansion() {
        XCTAssertEqual(SpokenSymbolExpander.spokenForm(of: "Connecting to Avenkin AI."),
                       "Connecting to Ah-Ven-Kin A I.")
        XCTAssertEqual(SpokenSymbolExpander.spokenForm(of: "**Avenkin AI** is ready."),
                       "Ah-Ven-Kin A I is ready.")
        XCTAssertEqual(SpokenSymbolExpander.spokenForm(of: "AVENKIN, avenkinAI, Avenkin’s voice."),
                       "Ah-Ven-Kin, Ah-Ven-Kin A I, Ah-Ven-Kin’s voice.")
    }

    func testBrandPronunciationKeepsUnrelatedWordsAndIsIdempotent() {
        let text = "Avenkins myAvenkin Avenkin2 AI railway"
        XCTAssertEqual(SpeechPronunciation.spokenForm(of: text), text)
        let spoken = SpeechPronunciation.spokenForm(of: "Avenkin AI")
        XCTAssertEqual(SpeechPronunciation.spokenForm(of: spoken), spoken)
    }

    // MARK: - Temperature

    func testCelsiusAndFahrenheitAreSpelledOut() {
        XCTAssertEqual(expand("It's 22°C in Auckland."), "It's 22 degrees Celsius in Auckland.")
        XCTAssertEqual(expand("Supply air is 140 °F."), "Supply air is 140 degrees Fahrenheit.")
        XCTAssertEqual(expand("A high of 18.5°C, low of 9°c"), "A high of 18.5 degrees Celsius, low of 9 degrees Celsius")
        XCTAssertEqual(expand("22℃ now, 72℉ inside"), "22 degrees Celsius now, 72 degrees Fahrenheit inside")
    }

    func testOneDegreeIsSingularAndBelowZeroKeepsItsSign() {
        XCTAssertEqual(expand("1°C"), "1 degree Celsius")
        XCTAssertEqual(expand("-1°C overnight"), "-1 degree Celsius overnight")
        XCTAssertEqual(expand("−12°C"), "−12 degrees Celsius")
        XCTAssertEqual(expand("0°C"), "0 degrees Celsius")
        XCTAssertEqual(expand("1.5°C"), "1.5 degrees Celsius")
    }

    func testABareDegreeSignIsDegrees() {
        XCTAssertEqual(expand("Turn 45° to the left."), "Turn 45 degrees to the left.")
        XCTAssertEqual(expand("Temperatures are in °C."), "Temperatures are in degrees Celsius.")
        XCTAssertEqual(expand("36°50′ south"), "36 degrees 50′ south")
        XCTAssertEqual(expand("Set it to 20°Cool mode"), "Set it to 20 degrees Cool mode",
                       "a scale letter must end there")
    }

    // MARK: - Units that carry a symbol

    func testSpeedAreaVolumeAndElectricalUnits() {
        XCTAssertEqual(expand("Wind is 35 km/h, gusting 50km/h."), "Wind is 35 kilometers per hour, gusting 50 kilometers per hour.")
        XCTAssertEqual(expand("It moves at 1 m/s."), "It moves at 1 meter per second.")
        XCTAssertEqual(expand("The room is 12 m² and 30 m³."), "The room is 12 square meters and 30 cubic meters.")
        XCTAssertEqual(expand("A 45 µF capacitor reading 10 kΩ"), "A 45 microfarads capacitor reading 10 kilohms")
        XCTAssertEqual(expand("Resistance is 1 Ω."), "Resistance is 1 ohm.")
        XCTAssertEqual(expand("Speeds are in km/h."), "Speeds are in kilometers per hour.")
    }

    func testAUnitInsideAnotherWordIsLeftAlone() {
        XCTAssertEqual(expand("and/or 24/7 km/hour"), "and/or 24/7 km/hour")
    }

    // MARK: - Units in plain letters

    func testAbbreviationsBehindANumberAreSpelledOut() {
        XCTAssertEqual(expand("Walk 5 km, about 12 min."), "Walk 5 kilometers, about 12 minutes.")
        XCTAssertEqual(expand("It weighs 2.5kg and holds 750 ml."), "It weighs 2.5 kilograms and holds 750 milliliters.")
        XCTAssertEqual(expand("Limit is 60 mph, or 100 kph."), "Limit is 60 miles per hour, or 100 kilometers per hour.")
        XCTAssertEqual(expand("Heart rate 72 bpm, pressure 120 mmHg, glucose 95 mg/dL."),
                       "Heart rate 72 beats per minute, pressure 120 millimeters of mercury, glucose 95 milligrams per deciliter.")
        XCTAssertEqual(expand("Static pressure is 0.28 inWC at 60 Hz, drawing 3 kW."),
                       "Static pressure is 0.28 inches of water column at 60 hertz, drawing 3 kilowatts.")
        XCTAssertEqual(expand("A 16 GB phone on 50 Mbps used 3 kWh."), "A 16 gigabytes phone on 50 megabits per second used 3 kilowatt hours.")
    }

    func testOneOfAThingIsSingular() {
        XCTAssertEqual(expand("1 km in 1 hr with 1 lb"), "1 kilometer in 1 hour with 1 pound")
        XCTAssertEqual(expand("1.0 km"), "1.0 kilometers")
    }

    func testAnAbbreviationWithoutANumberIsLeftAlone() {
        let text = "The km markers, the min and max, an MB of data, Hz and kg labels."
        XCTAssertEqual(expand(text), text)
    }

    func testSingleLettersAndLookalikesAreLeftAlone() {
        // "5m" is metres, minutes or millions; "5 in" is rarely inches.
        let text = "Raised $5m in 5 m of water, 3 g of salt, 5 in the morning, 10 kmart, 4 mg/kg, 12V, 5G."
        XCTAssertEqual(expand(text), text)
    }

    func testTheCaseOfAnAbbreviationMatters() {
        XCTAssertEqual(expand("5 MW and 5 mA, 3 Ms later"), "5 megawatts and 5 milliamps, 3 Ms later")
    }

    func testAnotherLanguageKeepsItsAbbreviations() {
        XCTAssertEqual(expand("Camina 5 km en 12 min.", "es"), "Camina 5 km en 12 min.")
    }

    // MARK: - Numbers

    func testRangesApproximationsAndFractions() {
        XCTAssertEqual(expand("It takes 5–10 minutes."), "It takes 5 to 10 minutes.")
        XCTAssertEqual(expand("About ~20 people, ≈ 3 hours"), "About about 20 people, approximately 3 hours")
        XCTAssertEqual(expand("Add 1½ cups, then ¾ of the rest."), "Add 1 and a half cups, then three quarters of the rest.")
        XCTAssertEqual(expand("Item #3 is next."), "Item number 3 is next.")
    }

    func testArithmeticAndComparison() {
        XCTAssertEqual(expand("3 × 4 = 12 and 12 ÷ 4 = 3"), "3 times 4 = 12 and 12 divided by 4 = 3")
        XCTAssertEqual(expand("Tolerance is ±5."), "Tolerance is plus or minus 5.")
        XCTAssertEqual(expand("Keep it ≤ 30 and ≥10."), "Keep it less than or equal to 30 and greater than or equal to 10.")
        XCTAssertEqual(expand("Anything <5 or >90 is out of range; 7 > 3."), "Anything less than 5 or greater than 90 is out of range; 7 is greater than 3.")
        XCTAssertEqual(expand("x² and 5³"), "x squared and 5 cubed")
    }

    // MARK: - Words

    func testAPathIsReadAsSteps() {
        XCTAssertEqual(expand("Open Settings > Connections > Services & Integrations."),
                       "Open Settings, then Connections, then Services and Integrations.")
        XCTAssertEqual(expand("Settings › Voice"), "Settings, then Voice")
        XCTAssertEqual(expand("Auckland → Wellington"), "Auckland to Wellington")
    }

    func testNamesAndTagsKeepTheirSigns() {
        let text = "AT&T and R&D use C# with colour #F08A4B, tag #swift, at ~/Documents."
        XCTAssertEqual(expand(text), text)
    }

    // MARK: - Markdown

    func testEmphasisMarkersAreTakenOutAndTheWordsKept() {
        XCTAssertEqual(expand("**Important:** turn the *main* valve off, _not_ the ~~red~~ blue one."),
                       "Important: turn the main valve off, not the red blue one.")
        XCTAssertEqual(expand("Run `git status` first."), "Run git status first.")
        XCTAssertEqual(expand("__Done__"), "Done")
    }

    func testHeadingsBulletsQuotesAndRulesLoseTheirMarkers() {
        let reply = """
        ## Steps
        - Turn off the power
        * Remove the panel
        + Check the fuse
        • Put it back
        ---
        > Mind the capacitor.
        1. Numbered lines keep their number.
        """
        let spoken = """
        Steps
        Turn off the power
        Remove the panel
        Check the fuse
        Put it back
        Mind the capacitor.
        1. Numbered lines keep their number.
        """
        XCTAssertEqual(expand(reply), spoken)
    }

    func testALinkIsItsWordsAndAFenceIsItsContents() {
        XCTAssertEqual(expand("See [the manual](https://example.com/manual_v2.pdf) and ![a diagram](x.png)."),
                       "See the manual and a diagram.")
        XCTAssertEqual(expand("Try:\n```swift\nprint(1)\n```\nThen run it."), "Try:\nprint(1)\nThen run it.")
    }

    func testATableIsReadARowAtATimeBehindItsColumnNames() {
        let reply = """
        Here are the parts:

        | Part | Qty | Price |
        |------|:---:|------:|
        | Bolt | 4 | $2 |
        | **Nut** | 1 |  |

        That's all.
        """
        let spoken = """
        Here are the parts:

        Part: Bolt, Qty: 4, Price: $2.
        Part: Nut, Qty: 1.

        That's all.
        """
        XCTAssertEqual(expand(reply, "es"), spoken)
    }

    func testATableSpokenALineAtATimeStillLosesItsPipes() {
        // Streamed speech hands over one line per utterance, so a row arrives without its header.
        XCTAssertEqual(expand("| Bolt | 4 | $2 |", "es"), "Bolt, 4, $2.")
        XCTAssertEqual(expand("| Part | Qty |\n|---|---|", "es"), "Part, Qty.")
        XCTAssertEqual(expand("|------|:---:|------:|", "es"), "", "a rule line has nothing to say")
    }

    func testAPipeInASentenceIsNotATable() {
        let text = "Run ls | grep txt to filter, or use a || b."
        XCTAssertEqual(expand(text, "es"), text)
    }

    func testAnUnclosedPairLeavesNoAsterisksBehind() {
        // A reply spoken a sentence at a time can split a pair across two utterances.
        XCTAssertEqual(expand("**Note: this is the first half."), "Note: this is the first half.")
        XCTAssertEqual(expand("and this is the second.** See the footnote*."), "and this is the second. See the footnote.")
    }

    func testMarkdownIsTakenOutInEveryLanguage() {
        XCTAssertEqual(expand("**Importante:** cierra la válvula.\n- Paso uno", "es"), "Importante: cierra la válvula.\nPaso uno")
    }

    func testWhatOnlyLooksLikeMarkdownIsKept() {
        let text = "Use snake_case_name and my_file.txt at https://example.com/a_b_c; 2*3*4 and 3 * 4 stay sums."
        XCTAssertEqual(expand(text, "es"), text)
        XCTAssertEqual(expand("3 * 4 is 12"), "3 times 4 is 12")
        XCTAssertEqual(expand("A well-known fact - and a dash."), "A well-known fact - and a dash.")
    }

    // MARK: - What is left alone

    func testTextWithoutASymbolIsUntouched() {
        let text = "Vitamin C is fine.  Press F to pay respects , 100% sure. It costs $5."
        XCTAssertEqual(expand(text), text, "spacing is only tidied where a symbol was replaced")
    }

    func testAnotherLanguageKeepsItsSymbols() {
        // English words dropped into a Spanish sentence would be worse than the symbol.
        XCTAssertEqual(expand("Hoy hay 22°C y viento de 35 km/h.", "es"), "Hoy hay 22°C y viento de 35 km/h.")
        XCTAssertEqual(expand("Сейчас 22°C.", "ru"), "Сейчас 22°C.")
    }

    func testSubscriptDigitsAreFlattenedInEveryLanguage() {
        XCTAssertEqual(expand("CO₂ and H₂O"), "CO2 and H2O")
        XCTAssertEqual(expand("El CO₂ sube.", "es"), "El CO2 sube.")
    }

    // MARK: - Which language

    func testTheLanguageIsTheRepliesOwnWhenItCanBeTold() {
        XCTAssertEqual(SpokenSymbolExpander.languageCode(
            of: "The weather today is sunny with a light breeze, and the high will be 22°C this afternoon.",
            fallback: "es"), "en")
        XCTAssertEqual(SpokenSymbolExpander.languageCode(
            of: "Hoy el clima está soleado con una brisa ligera, y la máxima será de 22°C por la tarde.",
            fallback: "en"), "es")
    }

    func testAReplyTooShortToCallFallsBackToThePhone() {
        XCTAssertEqual(SpokenSymbolExpander.languageCode(of: "22°C", fallback: "en"), "en")
    }
}
