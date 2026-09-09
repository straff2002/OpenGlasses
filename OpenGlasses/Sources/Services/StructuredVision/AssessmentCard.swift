import Foundation

// Structured Vision Assessment — normalized result model (see docs/plans/structured-vision-assessment.md).
//
// A *schema* (one per vertical) maps its own private payload onto this normalized `AssessmentCard`.
// Everything downstream — the card view, the HUD, the audit log — consumes `AssessmentCard` and knows
// nothing about any vertical's payload type. These types are PURE and headless (no UIKit, no network,
// no MainActor) so the whole core is unit-testable without a device.

/// A normalized 3-level status every vertical maps onto. Semantic status colours (green/amber/red)
/// are applied by the view layer — distinct from the coral AI-attribution accent used on the chrome.
enum AssessmentTier: String, Codable, CaseIterable, Comparable {
    /// The assessment could not be established from what was visible. Ranked *below* `ok` so
    /// escalation never picks it over a real observation, and so a single real finding replaces it.
    case unknown
    case ok
    case caution
    case critical

    /// Escalation order — `backstop` may only raise a tier, never lower it.
    var rank: Int {
        switch self {
        case .unknown: return -1
        case .ok: return 0
        case .caution: return 1
        case .critical: return 2
        }
    }

    static func < (lhs: AssessmentTier, rhs: AssessmentTier) -> Bool { lhs.rank < rhs.rank }

    /// The higher (more severe) of two tiers.
    static func escalated(_ a: AssessmentTier, _ b: AssessmentTier) -> AssessmentTier { a.rank >= b.rank ? a : b }

    var displayLabel: String {
        switch self {
        case .unknown: return String(localized: "Not established")
        case .ok: return String(localized: "OK")
        case .caution: return String(localized: "Caution")
        case .critical: return String(localized: "Critical")
        }
    }

    /// SF Symbol hint for the view layer (kept here as pure presentation metadata, like `HUDIcon`).
    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// One observed issue in the scene.
struct AssessmentFinding: Codable, Identifiable, Equatable {
    let id: UUID
    let label: String          // "Suspected arterial bleeding"
    let detail: String?        // short note
    let severity: AssessmentTier
    /// 0.0–1.0 **as reported by the model**. `nil` means the model reported none, and nothing
    /// downstream may invent one: an absent confidence is not a confident finding.
    let confidence: Double?
    let region: [Double]?       // optional normalized [x, y, w, h] for an overlay

    init(id: UUID = UUID(), label: String, detail: String? = nil,
         severity: AssessmentTier = .caution, confidence: Double? = nil, region: [Double]? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.severity = severity
        self.confidence = confidence
        self.region = region
    }

    enum CodingKeys: String, CodingKey {
        case id, label, detail, severity, confidence, region
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decode(String.self, forKey: .label)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        severity = try c.decodeIfPresent(AssessmentTier.self, forKey: .severity) ?? .caution
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        region = try c.decodeIfPresent([Double].self, forKey: .region)
    }
}

/// A numeric value read off a physical instrument in-frame — the "read the instrument" capability.
/// `unit` is the unit *as displayed on the device*; `canonical`/`canonicalUnit` are filled
/// deterministically by `UnitNormalizer` so range checks, HUD, and audit records are unit-stable.
struct InstrumentReading: Codable, Identifiable, Equatable {
    let id: UUID
    let quantity: String        // "temperature", "pressure", "brix", "weight", "voltage", "flow", "spo2"…
    let instrument: String?     // "probe thermometer", "manifold gauge", "refractometer", "scale", "multimeter"
    let value: Double
    let unit: String            // AS DISPLAYED: "°F", "psig", "°Bx", "lb", "V"
    let canonical: Double?
    let canonicalUnit: String?
    /// 0.0–1.0 as reported by the model — low confidence drives a re-capture, never a silent
    /// guess. `nil` means the model reported none, which the reading policy treats the same way it
    /// treats a low one: unestablished, so re-capture rather than assume.
    let confidence: Double?
    let region: [Double]?        // normalized [x, y, w, h] of the display, for an overlay highlight

    init(id: UUID = UUID(), quantity: String, instrument: String? = nil,
         value: Double, unit: String, canonical: Double? = nil, canonicalUnit: String? = nil,
         confidence: Double? = nil, region: [Double]? = nil) {
        self.id = id
        self.quantity = quantity
        self.instrument = instrument
        self.value = value
        self.unit = unit
        self.canonical = canonical
        self.canonicalUnit = canonicalUnit
        self.confidence = confidence
        self.region = region
    }

    enum CodingKeys: String, CodingKey {
        case id, quantity, instrument, value, unit, canonical
        case canonicalUnit = "canonical_unit"
        case confidence, region
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        quantity = try c.decode(String.self, forKey: .quantity)
        instrument = try c.decodeIfPresent(String.self, forKey: .instrument)
        value = try c.decode(Double.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        canonical = try c.decodeIfPresent(Double.self, forKey: .canonical)
        canonicalUnit = try c.decodeIfPresent(String.self, forKey: .canonicalUnit)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        region = try c.decodeIfPresent([Double].self, forKey: .region)
    }

    /// Returns a copy with `canonical`/`canonicalUnit` filled from `UnitNormalizer`. If the unit is
    /// unrecognised the reading is returned unchanged (the displayed value is still preserved).
    func normalized() -> InstrumentReading {
        guard let c = UnitNormalizer.canonical(value: value, unit: unit) else { return self }
        return InstrumentReading(id: id, quantity: quantity, instrument: instrument, value: value, unit: unit,
                                 canonical: c.value, canonicalUnit: c.unit, confidence: confidence, region: region)
    }
}

/// What the generic renderer, HUD, and audit log consume. Schemas produce this.
struct AssessmentCard: Codable, Equatable {
    let kind: String                    // schema id, e.g. "instrument_reading"
    let title: String
    let subtitle: String?
    let tier: AssessmentTier
    let summary: String                 // 1–2 sentence plain-English
    let findings: [AssessmentFinding]
    let recommendedAction: String?
    let stillNeeded: [String]           // "what to check / capture next"
    let readings: [InstrumentReading]   // "read the instrument" — first-class
    /// The model's own overall confidence, 0.0–1.0. `nil` when it reported none — which is the
    /// common case, and is never silently promoted to certainty.
    let confidence: Double?
    /// The banded certainty the evidence actually supports, or `nil` for "not established".
    /// Produced by `AssessmentQualifier`, never by a schema and never by the view.
    let certainty: CertaintyBand?
    /// What limited this assessment — a partial field of view, a blurry or dark frame, an
    /// occlusion. Rendered on the card, spoken in the summary, printed in the PDF.
    let limitations: [String]
    /// Which model produced this, and when. Attached at the point the app knows the model.
    let provenance: AIProvenance?
    let disclaimer: String?             // e.g. advisory / not a medical device

    init(kind: String, title: String, subtitle: String? = nil, tier: AssessmentTier,
         summary: String, findings: [AssessmentFinding] = [], recommendedAction: String? = nil,
         stillNeeded: [String] = [], readings: [InstrumentReading] = [],
         confidence: Double? = nil, certainty: CertaintyBand? = nil,
         limitations: [String] = [], provenance: AIProvenance? = nil,
         disclaimer: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.tier = tier
        self.summary = summary
        self.findings = findings
        self.recommendedAction = recommendedAction
        self.stillNeeded = stillNeeded
        self.readings = readings
        self.confidence = confidence
        self.certainty = certainty
        self.limitations = limitations
        self.provenance = provenance
        self.disclaimer = disclaimer
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, subtitle, tier, summary, findings
        case recommendedAction = "recommended_action"
        case stillNeeded = "still_needed"
        case readings, confidence, certainty, limitations, provenance, disclaimer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        tier = try c.decodeIfPresent(AssessmentTier.self, forKey: .tier) ?? .caution
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        findings = try c.decodeIfPresent([AssessmentFinding].self, forKey: .findings) ?? []
        recommendedAction = try c.decodeIfPresent(String.self, forKey: .recommendedAction)
        stillNeeded = try c.decodeIfPresent([String].self, forKey: .stillNeeded) ?? []
        readings = try c.decodeIfPresent([InstrumentReading].self, forKey: .readings) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        certainty = try c.decodeIfPresent(CertaintyBand.self, forKey: .certainty)
        limitations = try c.decodeIfPresent([String].self, forKey: .limitations) ?? []
        provenance = try c.decodeIfPresent(AIProvenance.self, forKey: .provenance)
        disclaimer = try c.decodeIfPresent(String.self, forKey: .disclaimer)
    }

    /// One copy constructor for every "same card, one field different" case, so a new field on the
    /// card cannot be silently dropped by one of them.
    func with(tier: AssessmentTier? = nil,
              findings: [AssessmentFinding]? = nil,
              recommendedAction: String?? = nil,
              stillNeeded: [String]? = nil,
              readings: [InstrumentReading]? = nil,
              certainty: CertaintyBand?? = nil,
              limitations: [String]? = nil,
              provenance: AIProvenance?? = nil) -> AssessmentCard {
        AssessmentCard(kind: kind, title: title, subtitle: subtitle,
                       tier: tier ?? self.tier, summary: summary,
                       findings: findings ?? self.findings,
                       recommendedAction: recommendedAction ?? self.recommendedAction,
                       stillNeeded: stillNeeded ?? self.stillNeeded,
                       readings: readings ?? self.readings,
                       confidence: confidence,
                       certainty: certainty ?? self.certainty,
                       limitations: limitations ?? self.limitations,
                       provenance: provenance ?? self.provenance,
                       disclaimer: disclaimer)
    }

    /// Returns a copy with every reading run through `UnitNormalizer`.
    func normalizingReadings() -> AssessmentCard {
        with(readings: readings.map { $0.normalized() })
    }

    /// Returns a copy with the tier escalated to at least `tier` and, optionally, an overriding action.
    /// Used by `AssessmentSchema.backstop` — it may only raise severity, never lower it.
    func escalating(to floor: AssessmentTier, action: String? = nil,
                    appending need: String? = nil) -> AssessmentCard {
        // `.some(...)` is load-bearing: `with` takes a double optional so a caller can clear the
        // action, and without the explicit wrap `??` resolves against the outer optional and
        // silently drops the existing action.
        with(tier: AssessmentTier.escalated(tier, floor),
             recommendedAction: .some(action ?? recommendedAction),
             stillNeeded: need.map { stillNeeded + [$0] } ?? stillNeeded)
    }
}
