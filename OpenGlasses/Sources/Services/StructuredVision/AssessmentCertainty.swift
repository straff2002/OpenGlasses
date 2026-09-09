import Foundation

/// How much the evidence actually supports the assessment (W08.2).
///
/// Deliberately a band rather than a number. The old card printed "Confidence 100%" for every
/// assessment because the schemas hard-coded 1.0 — a number nobody computed, presented with the
/// authority of one that somebody had. A band cannot be read as a measurement, and — this is the
/// point — it is *optional*: when the model reported no confidence, the card says the certainty was
/// not established rather than inventing a level for it.
enum CertaintyBand: String, Codable, CaseIterable, Comparable {
    case uncertain
    case likely
    case confident

    var rank: Int {
        switch self {
        case .uncertain: return 0
        case .likely: return 1
        case .confident: return 2
        }
    }

    static func < (lhs: CertaintyBand, rhs: CertaintyBand) -> Bool { lhs.rank < rhs.rank }

    /// The lower (more cautious) of two bands — how every cap in `CertaintyPolicy` is applied.
    static func capped(_ band: CertaintyBand, at ceiling: CertaintyBand) -> CertaintyBand {
        band.rank <= ceiling.rank ? band : ceiling
    }

    var displayLabel: String {
        switch self {
        case .uncertain: return String(localized: "Uncertain")
        case .likely: return String(localized: "Likely")
        case .confident: return String(localized: "Confident")
        }
    }
}

/// What the app can actually observe about the frame it sent, plus what the model said about its
/// own view of the scene. Pure data: the measuring is `ImageQualityProbe`'s job, the judging is
/// `InputQualityPolicy`'s, and neither is this.
struct InputQualityIndicators: Equatable {
    /// Laplacian variance from `ImageSharpness.score`. Higher is sharper. `nil` when not measured —
    /// which is not the same as "sharp", and is treated as neither evidence for nor against.
    var sharpness: Double?
    /// Mean grayscale luminance, 0–255. `nil` when not measured.
    var meanLuminance: Double?
    /// The model said it could see only part of the subject or scene.
    var modelReportedPartialView: Bool
    /// The model said something was blocking its view.
    var modelReportedOcclusion: Bool
    /// Any further limits the model named, in its own words.
    var modelReportedLimitations: [String]

    init(sharpness: Double? = nil,
         meanLuminance: Double? = nil,
         modelReportedPartialView: Bool = false,
         modelReportedOcclusion: Bool = false,
         modelReportedLimitations: [String] = []) {
        self.sharpness = sharpness
        self.meanLuminance = meanLuminance
        self.modelReportedPartialView = modelReportedPartialView
        self.modelReportedOcclusion = modelReportedOcclusion
        self.modelReportedLimitations = modelReportedLimitations
    }

    /// The model-side indicators carried in an assessment payload. The keys are declared by
    /// `AssessmentPrompt.viewLimitationsProperties`, so every vertical can report them and none has
    /// to; a payload without them yields an empty set rather than a claim of a clear view.
    static func fromModelPayload(_ json: [String: Any]) -> InputQualityIndicators {
        InputQualityIndicators(
            modelReportedPartialView: json["partial_view"] as? Bool ?? false,
            modelReportedOcclusion: json["view_obstructed"] as? Bool ?? false,
            modelReportedLimitations: (json["view_limitations"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
    }

    /// Merge measured indicators with model-reported ones.
    func merging(_ other: InputQualityIndicators) -> InputQualityIndicators {
        InputQualityIndicators(
            sharpness: sharpness ?? other.sharpness,
            meanLuminance: meanLuminance ?? other.meanLuminance,
            modelReportedPartialView: modelReportedPartialView || other.modelReportedPartialView,
            modelReportedOcclusion: modelReportedOcclusion || other.modelReportedOcclusion,
            modelReportedLimitations: modelReportedLimitations + other.modelReportedLimitations)
    }
}

/// Decides whether the input was good enough to assess at all (W08.2).
///
/// Pure and headless: it takes indicators and returns a verdict. Two outcomes only — the assessment
/// is qualified (usable, with any limitations named) or the app abstains (the frame did not support
/// an assessment and saying "OK" from it would be a fabrication).
///
/// The thresholds are conservative in the direction that matters. A frame is only called blurry when
/// the existing low-vision reading gate would call it blurry, and abstention needs a *severe*
/// failure — near-total blur, near-darkness — or two independent limitations at once. A usable frame
/// is not nagged about quality, and a hopeless one does not produce a green tick.
enum InputQualityPolicy {

    enum Verdict: Equatable {
        /// Assessable. `reasons` may still be non-empty: a usable frame with a named limitation.
        case qualified([String])
        /// Not assessable. `reasons` says why, in the wearer's words.
        case abstain([String])

        var reasons: [String] {
            switch self {
            case .qualified(let r), .abstain(let r): return r
            }
        }

        var isAbstention: Bool { if case .abstain = self { return true }; return false }
    }

    // MARK: - Thresholds

    /// Below this Laplacian variance the frame reads as blurry — the same threshold the low-vision
    /// reading path already uses, so "blurry" means one thing across the app.
    static let blurThreshold: Double = ImageSharpness.blurThreshold      // 90
    /// Below this there is essentially no detail left to assess.
    static let severeBlurThreshold: Double = 25
    /// Mean luminance (0–255) below which the scene is under-lit.
    static let lowLightThreshold: Double = 70
    /// Below this the frame is effectively dark.
    static let darkThreshold: Double = 35
    /// Above this the frame is blown out.
    static let overexposedThreshold: Double = 240

    // MARK: - Reasons

    static var blurReason: String { String(localized: "the image was too blurry to read reliably") }
    static var lowLightReason: String { String(localized: "the scene was poorly lit") }
    static var darkReason: String { String(localized: "the scene was too dark to see") }
    static var overexposedReason: String { String(localized: "the image was washed out by glare") }
    static var partialViewReason: String { String(localized: "only part of the scene was visible") }
    static var occlusionReason: String { String(localized: "something was blocking the view") }

    // MARK: - Evaluation

    static func evaluate(_ indicators: InputQualityIndicators) -> Verdict {
        var reasons: [String] = []
        var severe = false

        if let sharpness = indicators.sharpness {
            if sharpness < severeBlurThreshold {
                reasons.append(blurReason)
                severe = true
            } else if sharpness < blurThreshold {
                reasons.append(blurReason)
            }
        }
        if let luminance = indicators.meanLuminance {
            if luminance < darkThreshold {
                reasons.append(darkReason)
                severe = true
            } else if luminance < lowLightThreshold {
                reasons.append(lowLightReason)
            } else if luminance > overexposedThreshold {
                reasons.append(overexposedReason)
            }
        }
        if indicators.modelReportedPartialView { reasons.append(partialViewReason) }
        if indicators.modelReportedOcclusion { reasons.append(occlusionReason) }
        reasons += indicators.modelReportedLimitations

        // Two independent limitations at once is an unassessable frame even when neither alone is
        // severe: a dim, partly-blocked view of a job site is not a job-site assessment.
        return (severe || reasons.count >= 2) ? .abstain(reasons) : .qualified(reasons)
    }
}

/// Turns the model's own confidence, the input-quality verdict and the wording of the summary into a
/// certainty band — or into nothing at all (W08.2).
///
/// The single rule the whole type exists to enforce: **an absent confidence produces an absent
/// band**. There is no path from "the model said nothing" to "confident", which is exactly the path
/// the hard-coded `1.0` used to take.
enum CertaintyPolicy {

    /// At or above this reported confidence, and with a clean frame, the band is `confident`.
    static let confidentFloor: Double = 0.85
    /// At or above this, `likely`. Below it, `uncertain`.
    static let likelyFloor: Double = 0.60

    /// - Parameters:
    ///   - modelConfidence: what the model reported, or `nil` if it reported nothing.
    ///   - quality: the input-quality verdict for the frame that was assessed.
    ///   - summary: the model's own prose, checked for epistemic hedging.
    static func band(modelConfidence: Double?,
                     quality: InputQualityPolicy.Verdict,
                     summary: String) -> CertaintyBand? {
        guard let confidence = modelConfidence else { return nil }

        var band: CertaintyBand = confidence >= confidentFloor ? .confident
            : (confidence >= likelyFloor ? .likely : .uncertain)

        // Any named limitation caps the band: a partial view cannot support a confident call.
        if !quality.reasons.isEmpty {
            band = CertaintyBand.capped(band, at: .likely)
        }
        // An abstention caps it at the bottom. The band still exists because the model gave a
        // number; what it may not do is read as anything but uncertain.
        if quality.isAbstention {
            band = CertaintyBand.capped(band, at: .uncertain)
        }
        // The model hedging in its own summary outranks the number it attached to it.
        if hedges(summary) {
            band = CertaintyBand.capped(band, at: .uncertain)
        }
        return band
    }

    /// Reuses the existing hedge vocabulary. The question is deliberately empty: the freshness and
    /// personal-data arms of `UncertaintyDetector` are about re-asking the web, which has nothing to
    /// do with an image assessment, so only the hedging arm can fire here.
    static func hedges(_ summary: String) -> Bool {
        guard !summary.isEmpty else { return false }
        let verdict = UncertaintyDetector.assess(question: "", answer: summary)
        return verdict.reason == .hedged
    }
}

/// The human-escalation line every assessment carries (W08.2). Reuses the tone the first-aid
/// coaching path already speaks: name who to hand this to, without hedging about whether to.
enum AssessmentEscalation {
    static func line(forKind kind: String) -> String {
        switch kind {
        case "first_aid_triage":
            return String(localized: "Call emergency services. This does not replace a trained first aider.")
        case "safety_assessment":
            return String(localized: "Have a qualified safety inspector verify on site before work continues.")
        default:
            return String(localized: "Have a qualified person verify this before you act on it.")
        }
    }
}

/// Applies the uncertainty policy to a finished card: bands it, names its limitations, abstains when
/// the frame did not support the call, and attaches provenance (W08.2 + W08.3).
///
/// Pure, so the whole rule set is testable without a camera, a network or a device. Both assessment
/// services call it at the one point where the card, the frame and the model are all known.
enum AssessmentQualifier {

    static func qualify(_ card: AssessmentCard,
                        quality: InputQualityPolicy.Verdict,
                        provenance: AIProvenance? = nil) -> AssessmentCard {
        let band = CertaintyPolicy.band(modelConfidence: card.confidence,
                                        quality: quality,
                                        summary: card.summary)
        let limitations = card.limitations + quality.reasons

        var qualified = card.with(certainty: .some(band),
                                  limitations: limitations,
                                  provenance: .some(provenance ?? card.provenance))

        // Abstention may not mask a real finding: it only replaces an unearned all-clear.
        if quality.isAbstention && qualified.tier == .ok && qualified.findings.isEmpty {
            qualified = qualified.with(
                tier: .unknown,
                recommendedAction: .some(qualified.recommendedAction ?? AssessmentEscalation.line(forKind: card.kind)),
                stillNeeded: qualified.stillNeeded + [String(localized: "Re-capture with a clear, close view.")])
        }
        return qualified
    }
}
