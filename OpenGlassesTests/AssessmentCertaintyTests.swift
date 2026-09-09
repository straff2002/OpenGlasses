import XCTest
@testable import OpenGlasses

/// W08.2 — no assessment surface may state a certainty nobody produced.
///
/// The defect these tests exist to keep out: every schema hard-coded `confidence: 1.0`, so the card
/// printed "Confidence 100%" whether the model had rated itself or not, and a blurry frame of a dark
/// job site produced the same green tick as a clear one. The tests below assert the three halves of
/// the fix — an absent confidence stays absent, poor input abstains instead of clearing, and every
/// rendered string says what limited the view and who to escalate to.
final class AssessmentCertaintyTests: XCTestCase {

    // MARK: - No path invents a confidence

    /// The load-bearing property: there is no route from "the model said nothing" to a number.
    func testAbsentConfidenceStaysAbsentThroughEverySchema() throws {
        let firstAid = try FirstAidTriageSchema().makeCard(
            from: ["responsive": true, "breathing": "normal", "severe_bleeding": false,
                   "summary": "Casualty alert."], context: nil)
        XCTAssertNil(firstAid.confidence)

        let heca = SafetyAssessmentSchema().card(for: try SafetyReport.from(json: [
            "summary": "Trench beside a load.",
            "assessments": [["category": "excavation", "is_present": true, "has_indirect_control": true]]
        ]))
        XCTAssertNil(heca.confidence)
        XCTAssertTrue(heca.findings.allSatisfy { $0.confidence == nil })

        let instrument = try InstrumentReadingSchema().makeCard(
            from: ["readings": [["quantity": "pressure", "value": 100.0, "unit": "psi"]],
                   "summary": "One gauge."], context: nil)
        XCTAssertNil(instrument.confidence)

        // And nothing downstream fills it in either.
        for card in [firstAid, heca, instrument] {
            let qualified = AssessmentQualifier.qualify(card, quality: .qualified([]))
            XCTAssertNil(qualified.confidence, "\(card.kind) gained a confidence from nowhere")
            XCTAssertNil(qualified.certainty, "\(card.kind) gained a certainty band from nowhere")
        }
    }

    /// A decoded payload with no `confidence` key decodes to nil at every level.
    func testDecodingNeverDefaultsConfidenceToOne() throws {
        let card = try AssessmentJSON.decode(AssessmentCard.self, from: [
            "kind": "k", "title": "T",
            "findings": [["label": "thing", "severity": "caution"]],
            "readings": [["quantity": "temp", "value": 5.0, "unit": "°C"]],
        ])
        XCTAssertNil(card.confidence)
        XCTAssertNil(card.findings.first?.confidence)
        XCTAssertNil(card.readings.first?.confidence)
    }

    /// A reading whose confidence was never reported is re-captured, not trusted.
    func testUnreportedReadingConfidenceIsTreatedAsUnestablished() throws {
        let card = try InstrumentReadingSchema().makeCard(
            from: ["readings": [["quantity": "brix", "value": 12.0, "unit": "°Bx"]]], context: nil)
        XCTAssertTrue(card.stillNeeded.contains { $0.contains("brix") && $0.contains("not reported") })
    }

    // MARK: - Input quality

    func testClearFrameQualifiesWithNoReasons() {
        let verdict = InputQualityPolicy.evaluate(
            InputQualityIndicators(sharpness: 400, meanLuminance: 130))
        XCTAssertEqual(verdict, .qualified([]))
        XCTAssertFalse(verdict.isAbstention)
    }

    func testMildBlurQualifiesButNamesTheReason() {
        let verdict = InputQualityPolicy.evaluate(
            InputQualityIndicators(sharpness: 50, meanLuminance: 130))
        XCTAssertFalse(verdict.isAbstention)
        XCTAssertEqual(verdict.reasons, [InputQualityPolicy.blurReason])
    }

    func testSevereBlurAbstains() {
        let verdict = InputQualityPolicy.evaluate(
            InputQualityIndicators(sharpness: 5, meanLuminance: 130))
        XCTAssertTrue(verdict.isAbstention)
        XCTAssertTrue(verdict.reasons.contains(InputQualityPolicy.blurReason))
    }

    func testNearDarknessAbstains() {
        let verdict = InputQualityPolicy.evaluate(
            InputQualityIndicators(sharpness: 400, meanLuminance: 10))
        XCTAssertTrue(verdict.isAbstention)
        XCTAssertTrue(verdict.reasons.contains(InputQualityPolicy.darkReason))
    }

    /// Neither limitation is severe on its own; together they are not an assessment.
    func testTwoMildLimitationsAbstainTogether() {
        let verdict = InputQualityPolicy.evaluate(
            InputQualityIndicators(sharpness: 60, meanLuminance: 55))
        XCTAssertTrue(verdict.isAbstention)
        XCTAssertEqual(verdict.reasons.count, 2)
    }

    func testUnmeasuredFrameIsNeitherGoodNorBad() {
        XCTAssertEqual(InputQualityPolicy.evaluate(InputQualityIndicators()), .qualified([]))
    }

    func testModelReportedPartialViewIsAReason() {
        let indicators = InputQualityIndicators.fromModelPayload([
            "partial_view": true, "view_limitations": ["the far side of the trench was out of frame"],
        ])
        XCTAssertTrue(indicators.modelReportedPartialView)
        let verdict = InputQualityPolicy.evaluate(indicators)
        XCTAssertTrue(verdict.reasons.contains(InputQualityPolicy.partialViewReason))
        XCTAssertTrue(verdict.reasons.contains("the far side of the trench was out of frame"))
    }

    func testModelPayloadWithoutLimitFieldsClaimsNothing() {
        let indicators = InputQualityIndicators.fromModelPayload(["summary": "fine"])
        XCTAssertFalse(indicators.modelReportedPartialView)
        XCTAssertFalse(indicators.modelReportedOcclusion)
        XCTAssertTrue(indicators.modelReportedLimitations.isEmpty)
    }

    // MARK: - Band thresholds

    func testBandThresholds() {
        XCTAssertEqual(CertaintyPolicy.band(modelConfidence: 0.95, quality: .qualified([]), summary: "ok"), .confident)
        XCTAssertEqual(CertaintyPolicy.band(modelConfidence: 0.85, quality: .qualified([]), summary: "ok"), .confident)
        XCTAssertEqual(CertaintyPolicy.band(modelConfidence: 0.84, quality: .qualified([]), summary: "ok"), .likely)
        XCTAssertEqual(CertaintyPolicy.band(modelConfidence: 0.60, quality: .qualified([]), summary: "ok"), .likely)
        XCTAssertEqual(CertaintyPolicy.band(modelConfidence: 0.59, quality: .qualified([]), summary: "ok"), .uncertain)
        XCTAssertEqual(CertaintyPolicy.band(modelConfidence: 0.0, quality: .qualified([]), summary: "ok"), .uncertain)
    }

    func testNoReportedConfidenceMeansNoBand() {
        XCTAssertNil(CertaintyPolicy.band(modelConfidence: nil, quality: .qualified([]), summary: "very clear"))
    }

    func testAnyLimitationCapsTheBandAtLikely() {
        XCTAssertEqual(
            CertaintyPolicy.band(modelConfidence: 0.99,
                                 quality: .qualified([InputQualityPolicy.partialViewReason]),
                                 summary: "ok"),
            .likely)
    }

    func testAbstentionCapsTheBandAtUncertain() {
        XCTAssertEqual(
            CertaintyPolicy.band(modelConfidence: 0.99,
                                 quality: .abstain([InputQualityPolicy.darkReason]),
                                 summary: "ok"),
            .uncertain)
    }

    /// The model hedging in prose outranks the number it attached to the prose.
    func testHedgedSummaryCapsTheBandAtUncertain() {
        XCTAssertEqual(
            CertaintyPolicy.band(modelConfidence: 0.99, quality: .qualified([]),
                                 summary: "I'm not sure what this equipment is."),
            .uncertain)
        // A summary that merely mentions uncertainty about the scene is not a hedge.
        XCTAssertEqual(
            CertaintyPolicy.band(modelConfidence: 0.99, quality: .qualified([]),
                                 summary: "The worker is not sure-footed on the ladder."),
            .confident)
    }

    // MARK: - Abstention on the card

    func testAbstentionReplacesAnUnearnedAllClear() {
        let card = AssessmentCard(kind: "safety_assessment", title: "Safety", tier: .ok,
                                  summary: "Nothing found.")
        let out = AssessmentQualifier.qualify(card, quality: .abstain([InputQualityPolicy.darkReason]))
        XCTAssertEqual(out.tier, .unknown)
        XCTAssertEqual(out.limitations, [InputQualityPolicy.darkReason])
        XCTAssertNotNil(out.recommendedAction)
        XCTAssertTrue(out.stillNeeded.contains { $0.lowercased().contains("re-capture") })
    }

    /// Abstention must never bury a hazard the model did see.
    func testAbstentionDoesNotMaskARealFinding() {
        let card = AssessmentCard(kind: "safety_assessment", title: "Safety", tier: .critical,
                                  summary: "Unshored trench.",
                                  findings: [AssessmentFinding(label: "Excavation", severity: .critical)])
        let out = AssessmentQualifier.qualify(card, quality: .abstain([InputQualityPolicy.blurReason]))
        XCTAssertEqual(out.tier, .critical)
        XCTAssertEqual(out.limitations, [InputQualityPolicy.blurReason])
    }

    // MARK: - First aid abstains rather than clearing a casualty

    func testFirstAidAbstainsWhenVitalsWereNotObservable() throws {
        let card = try FirstAidTriageSchema().makeCard(
            from: ["breathing": "unknown", "severe_bleeding": false, "summary": ""], context: nil)
        XCTAssertEqual(card.tier, .unknown)
        XCTAssertNotEqual(card.tier, .ok, "an unobserved casualty must not read as OK")
        XCTAssertTrue(card.recommendedAction?.lowercased().contains("emergency") ?? false)
        XCTAssertFalse(card.limitations.isEmpty)
        XCTAssertTrue(card.stillNeeded.contains { $0.lowercased().contains("breathing") })
    }

    func testFirstAidStillClearsAnActuallyObservedCasualty() throws {
        let card = try FirstAidTriageSchema().makeCard(
            from: ["responsive": true, "breathing": "normal", "severe_bleeding": false,
                   "summary": "Alert and breathing normally."], context: nil)
        XCTAssertEqual(card.tier, .ok)
        XCTAssertTrue(card.limitations.isEmpty)
    }

    func testFirstAidUnobservedVitalsDoNotMaskAVisibleInjury() throws {
        let card = try FirstAidTriageSchema().makeCard(
            from: ["breathing": "unknown", "severe_bleeding": true, "summary": "Bleeding heavily."],
            context: nil)
        XCTAssertEqual(card.tier, .critical)
        XCTAssertTrue(card.recommendedAction?.lowercased().contains("pressure") ?? false)
    }

    // MARK: - Rendered strings

    func testPresentationRendersBandWhenPresent() {
        let card = AssessmentCard(kind: "first_aid_triage", title: "Triage", tier: .caution,
                                  summary: "s", confidence: 0.7, certainty: .likely)
        XCTAssertEqual(AssessmentPresentation(card).certaintyText, "Certainty: Likely")
    }

    func testPresentationSaysNotEstablishedWhenAbsent() {
        let card = AssessmentCard(kind: "first_aid_triage", title: "Triage", tier: .caution, summary: "s")
        let p = AssessmentPresentation(card)
        XCTAssertEqual(p.certaintyText, "Certainty not established")
        XCTAssertNil(p.limitationsText)
    }

    func testPresentationAlwaysCarriesLimitationsAndEscalation() {
        let card = AssessmentCard(kind: "first_aid_triage", title: "Triage", tier: .caution,
                                  summary: "s", limitations: ["only part of the scene was visible"])
        let p = AssessmentPresentation(card)
        XCTAssertEqual(p.limitationsText, "Limited view: only part of the scene was visible.")
        XCTAssertTrue(p.escalationText.contains("first aider"))
        XCTAssertTrue(p.spokenSummary.contains("only part of the scene was visible"))
        XCTAssertTrue(p.spokenSummary.contains("first aider"))
    }

    /// The spoken/HUD path may not state a percentage the model did not produce.
    func testSpokenSummaryStatesNoUnproducedPercentage() {
        let card = AssessmentCard(kind: "safety_assessment", title: "Safety", tier: .ok, summary: "Clear.")
        let spoken = AssessmentPresentation(card).spokenSummary
        XCTAssertFalse(spoken.contains("%"))
        XCTAssertFalse(spoken.contains("100"))
        XCTAssertTrue(spoken.contains("Certainty not established"))
        XCTAssertTrue(spoken.contains("inspector"))
    }

    func testEscalationLinePerVertical() {
        XCTAssertTrue(AssessmentEscalation.line(forKind: "first_aid_triage").contains("emergency services"))
        XCTAssertTrue(AssessmentEscalation.line(forKind: "safety_assessment").contains("inspector"))
        XCTAssertTrue(AssessmentEscalation.line(forKind: "instrument_reading").contains("qualified person"))
    }

    // MARK: - PDF caveat

    @MainActor
    func testSafetyPDFCarriesTheCaveatAndEscalation() throws {
        let report = try SafetyReport.from(json: [
            "summary": "Unshored trench.",
            "partial_view": true,
            "assessments": [["category": "excavation", "is_present": true, "has_indirect_control": true]],
        ])
        XCTAssertEqual(report.limitations, [InputQualityPolicy.partialViewReason])

        let text = SafetyReportPDF.bodyTextForTesting(report)
        XCTAssertTrue(text.contains("single camera view"))
        XCTAssertTrue(text.contains("Certainty: not established"))
        XCTAssertTrue(text.contains(InputQualityPolicy.partialViewReason))
        XCTAssertTrue(text.contains("qualified safety inspector"))
        XCTAssertFalse(text.contains("Confidence 100%"))

        // And the rendered document is still a valid PDF.
        let data = SafetyReportPDF.data(for: report)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
    }
}
