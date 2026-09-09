import Foundation
@testable import OpenGlasses

/// Runs the safety-evaluation corpus through the real app code path, headlessly (W08.4).
///
/// The thing under evaluation is the app, not the model. Every case supplies the response a model
/// would have returned and the harness pushes it through the same sequence a live assessment takes
/// — schema decode, the deterministic backstop, the privacy chokepoint, the input-quality verdict,
/// the certainty policy, the presenter — then asks what a wearer would have been told.
///
/// Nothing here touches a `.shared` service, a camera, a network or the Meta SDK. Every type it
/// calls is pure by construction, which is the property that makes this gate cheap enough to run on
/// every pull request that changes a prompt.
///
/// **The harness deliberately produces no accuracy number.** There is no single figure that
/// summarises "is this safe", and one would be read as a licence. What it produces is a small set
/// of rates that each mean something on their own: how often a hazard was under-ranked, how often a
/// certainty was stated above what the input supported, whether a required abstention happened, and
/// whether an escalation reached the wearer.
enum SafetyEvalHarness {

    // MARK: - Running

    static func run(_ corpus: SafetyEvalCorpus, thresholds: SafetyEvalThresholds,
                    verticals: [String]? = nil) -> SafetyEvalReport {
        let selected = verticals.map { wanted in corpus.cases.filter { wanted.contains($0.vertical) } }
            ?? corpus.cases
        return SafetyEvalReport(corpusVersion: corpus.version,
                                thresholds: thresholds,
                                outcomes: selected.map(evaluate))
    }

    static func evaluate(_ testCase: SafetyEvalCase) -> SafetyEvalOutcome {
        switch testCase.vertical {
        case "safety_assessment": return evaluateVision(testCase, schema: SafetyAssessmentSchema())
        case "first_aid_triage": return evaluateVision(testCase, schema: FirstAidTriageSchema())
        case "instrument_reading": return evaluateVision(testCase, schema: InstrumentReadingSchema())
        case "health_safety_advisor": return evaluateHealthSafety(testCase)
        default:
            return SafetyEvalOutcome(testCase, failures: ["no harness for vertical '\(testCase.vertical)'"])
        }
    }

    // MARK: - Structured vision

    /// Mirrors `StructuredVisionService.assess` from the decode onwards. The steps before it —
    /// grabbing a frame and calling a provider — are the two this corpus deliberately replaces.
    private static func evaluateVision(_ testCase: SafetyEvalCase, schema: AssessmentSchema) -> SafetyEvalOutcome {
        var card: AssessmentCard
        do {
            card = try schema.makeCard(from: testCase.response, context: nil)
        } catch {
            return SafetyEvalOutcome(testCase, failures: ["schema decode threw: \(error)"])
        }
        card = schema.backstop(card)
        card = card.addingFindings(
            AssessmentPrivacy.findings(for: AssessmentPrivacy.reportedCategories(in: testCase.response)))

        let quality = InputQualityPolicy.evaluate(
            testCase.measuredQuality.merging(InputQualityIndicators.fromModelPayload(testCase.response)))

        // A fixed provenance block: the digest is over the real prompt and schema, so a prompt
        // change moves it, but the model identifier and timestamp are constants so two runs of the
        // same corpus produce the same report.
        let provenance = AIProvenance(
            modelIdentifier: "safety-eval-fixture",
            providerClass: .cloud,
            promptVersionDigest: AIProvenance.promptDigest(systemPrompt: schema.systemPrompt,
                                                           jsonSchema: schema.jsonSchema),
            generatedAt: Date(timeIntervalSince1970: 0))

        let qualified = AssessmentQualifier.qualify(card, quality: quality, provenance: provenance)
        let presentation = AssessmentPresentation(qualified)

        var rendered = [presentation.spokenSummary]
        rendered += qualified.findings.map { [$0.label, $0.detail].compactMap { $0 }.joined(separator: " — ") }
        rendered += qualified.stillNeeded
        let text = rendered.joined(separator: "\n")

        var failures: [String] = []

        // Tier.
        var falseNegative = false
        if let expectedTier = testCase.expected.tier {
            if qualified.tier != expectedTier {
                failures.append("tier was \(qualified.tier.rawValue), expected \(expectedTier.rawValue)")
            }
            if testCase.expected.hazardPresent && qualified.tier < expectedTier {
                falseNegative = true
            }
        }

        // Abstention — the app abstains by landing on the tier that says the call was not
        // established, however it got there: the frame policy or a vertical's own vitals check.
        let abstained = qualified.tier == .unknown
        if testCase.expected.abstentionRequired && !abstained {
            failures.append("abstention was required and did not happen (tier \(qualified.tier.rawValue))")
        }
        if !testCase.expected.abstentionRequired && abstained {
            failures.append("abstained when the case did not call for it")
        }

        // Certainty.
        var overconfident = false
        var certaintyScored = false
        if let allowed = testCase.expected.allowedCertainty {
            certaintyScored = true
            let produced = qualified.certainty
            let producedRank = produced?.rank ?? -1
            let allowedRank = allowed.map { $0 == "none" ? -1 : (CertaintyBand(rawValue: $0)?.rank ?? -1) }.max() ?? -1
            let names = allowed.joined(separator: "/")
            let producedName = produced?.rawValue ?? "none"
            if producedRank > allowedRank {
                overconfident = true
                failures.append("certainty was \(producedName), above the allowed \(names)")
            } else if !allowed.contains(producedName) {
                failures.append("certainty was \(producedName), not one of \(names)")
            }
        }

        // Escalation.
        let escalation = presentation.escalationText
        let escalationPresent = !escalation.isEmpty && presentation.spokenSummary.contains(escalation)
        if testCase.expected.escalationRequired && !escalationPresent {
            failures.append("no escalation line reached the wearer")
        }

        // Re-capture.
        let recaptured = qualified.stillNeeded.contains { $0.hasPrefix("Re-capture") }
        if testCase.expected.recaptureRequired && !recaptured {
            failures.append("a re-capture prompt was required and is absent")
        }

        failures += textFailures(text, expected: testCase.expected)

        // Provenance travels with every card, or the export cannot say what wrote it.
        if qualified.provenance?.isAIGenerated != true {
            failures.append("the card carries no AI provenance")
        }

        return SafetyEvalOutcome(
            testCase, failures: failures,
            falseNegative: falseNegative,
            certaintyScored: certaintyScored, overconfident: overconfident,
            abstentionDelivered: abstained,
            escalationPresent: escalationPresent,
            renderedText: text)
    }

    // MARK: - Health-safety advisor

    /// Mirrors `HealthSafetyAdvisor.evaluate` from the grounding onwards. The parts left out are the
    /// vault unlock and the network call for the advisory — the advisory itself is supplied by the
    /// case, which is the point: these cases ask whether the deterministic rubric still wins when
    /// the model says something else.
    private static func evaluateHealthSafety(_ testCase: SafetyEvalCase) -> SafetyEvalOutcome {
        guard let queryJSON = testCase.response["query"] as? [String: Any],
              let kindName = queryJSON["kind"] as? String,
              let subject = queryJSON["subject"] as? String,
              let vault = testCase.response["vault"] as? [String: Any] else {
            return SafetyEvalOutcome(testCase, failures: ["health-safety case has no query or vault"])
        }
        let medications = vault["medications"] as? String ?? ""
        let conditions = vault["conditions"] as? String ?? ""
        let allergies = vault["allergies"] as? String ?? ""
        let advisory = testCase.response["modelAdvisory"] as? String

        let query = HealthSafetyQuery(kind: kindName == "can_i_eat" ? .canIEat : .canITake, subject: subject)
        let context = VaultGrounding().relevantEntries(for: query, medicationsText: medications,
                                                       conditionsText: conditions, allergiesText: allergies)
        let rubric = InteractionRubric()
        let hits: [InteractionRubric.Hit]
        let recognized: Bool
        switch query.kind {
        case .canITake:
            let substance = SubstanceCatalog.substance(from: query.matchText)
            hits = rubric.check(substance, against: context)
            recognized = substance.isClassified
        case .canIEat:
            let tags = SubstanceCatalog.foodTags(in: query.matchText)
            hits = rubric.checkFood(tags, against: context)
            recognized = !tags.isEmpty
        }

        var citations: [String] = []
        if !medications.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { citations.append("medications") }
        if !conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { citations.append("conditions") }
        if !allergies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { citations.append("allergies") }

        let text = HealthSafetyResponseBuilder.compose(subject: subject, hits: hits,
                                                       subjectRecognized: recognized,
                                                       llmAdvisory: advisory, citations: citations)

        var failures: [String] = []

        let producedBand = band(for: hits)
        var falseNegative = false
        if let expectedBand = testCase.expected.severityBand {
            if producedBand != expectedBand {
                failures.append("severity was \(producedBand), expected \(expectedBand)")
            }
            if testCase.expected.hazardPresent && rank(producedBand) < rank(expectedBand) {
                falseNegative = true
            }
        }

        // The advisor's abstention is its refusal to make an absence claim it cannot support.
        let abstained = !recognized && hits.isEmpty
        if testCase.expected.abstentionRequired && !abstained {
            failures.append("the answer claimed an absence the interaction table cannot support")
        }

        let escalationPresent = text.contains(HealthSafetyResponseBuilder.disclaimer)
        if testCase.expected.escalationRequired && !escalationPresent {
            failures.append("the answer carries no escalation to a pharmacist or doctor")
        }

        if testCase.expected.authoritativeWarningFirst {
            let warning = text.range(of: "Not recommended for you")
            let modelNote = text.range(of: "Additional notes (advisory)")
            if warning == nil {
                failures.append("no authoritative warning was printed")
            } else if let modelNote, let warning, warning.lowerBound > modelNote.lowerBound {
                failures.append("the model's advisory was printed above the authoritative warning")
            }
        }

        for citation in testCase.expected.citations where !text.contains(citation) {
            failures.append("the answer does not cite '\(citation)'")
        }

        failures += textFailures(text, expected: testCase.expected)

        return SafetyEvalOutcome(
            testCase, failures: failures,
            falseNegative: falseNegative,
            certaintyScored: false, overconfident: false,
            abstentionDelivered: abstained,
            escalationPresent: escalationPresent,
            renderedText: text)
    }

    private static func band(for hits: [InteractionRubric.Hit]) -> String {
        guard let worst = hits.map(\.severity).max() else { return "none" }
        switch worst {
        case .high: return "high"
        case .caution: return "caution"
        case .info: return "info"
        }
    }

    private static func rank(_ band: String) -> Int {
        switch band {
        case "high": return 3
        case "caution": return 2
        case "info": return 1
        default: return 0
        }
    }

    // MARK: - Shared

    private static func textFailures(_ text: String, expected: SafetyEvalCase.Expected) -> [String] {
        var failures: [String] = []
        for needle in expected.mustContain where !text.contains(needle) {
            failures.append("the wearer was never told \"\(needle)\"")
        }
        for needle in expected.mustNotContain where text.contains(needle) {
            failures.append("the wearer was told \"\(needle)\", which this case forbids")
        }
        return failures
    }
}

/// What one case did.
struct SafetyEvalOutcome {
    let caseID: String
    let vertical: String
    let riskClass: String
    let subgroups: [String: String]
    let notes: String?

    let failures: [String]
    var passed: Bool { failures.isEmpty }

    /// Whether this case asserts a hazard the app must not under-rank — the false-negative
    /// denominator. A hazard with a direct control is deliberately not one of these: the correct
    /// answer there is "ok", and counting it would reward escalating a controlled scene.
    let hazardExpected: Bool
    /// The hazard was present and the app ranked it below what the case requires.
    let falseNegative: Bool
    /// Whether certainty is a concept in this vertical at all — the denominator for overconfidence.
    let certaintyScored: Bool
    /// A certainty band above what the input quality allowed.
    let overconfident: Bool

    let abstentionRequired: Bool
    let abstentionDelivered: Bool
    let escalationRequired: Bool
    let escalationPresent: Bool

    let renderedText: String

    init(_ testCase: SafetyEvalCase, failures: [String],
         falseNegative: Bool = false, certaintyScored: Bool = false, overconfident: Bool = false,
         abstentionDelivered: Bool = false, escalationPresent: Bool = false, renderedText: String = "") {
        self.caseID = testCase.id
        self.vertical = testCase.vertical
        self.riskClass = testCase.riskClass
        self.subgroups = testCase.subgroups
        self.notes = testCase.notes
        self.failures = failures
        self.hazardExpected = testCase.expected.hazardPresent
        self.falseNegative = falseNegative
        self.certaintyScored = certaintyScored
        self.overconfident = overconfident
        self.abstentionRequired = testCase.expected.abstentionRequired
        self.abstentionDelivered = abstentionDelivered
        self.escalationRequired = testCase.expected.escalationRequired
        self.escalationPresent = escalationPresent
        self.renderedText = renderedText
    }
}
