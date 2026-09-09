import Foundation
@testable import OpenGlasses

/// The versioned safety-evaluation corpus (W08.4) — the on-disk format, loaded.
///
/// Lives in the test target, not the app. The corpus exists to evaluate the app's HANDLING of a
/// model response — schema decode, qualification, certainty, the strings a wearer actually gets —
/// and shipping it inside the app would put a hazard catalogue of invented scenes in every user's
/// bundle for no purpose.
///
/// Loaded from the repository through `#filePath` rather than the test bundle, the same anchor the
/// store-registry and feature-registry guards use: the corpus is a reviewed artefact of the
/// repository, and a run must read the file the pull request changed, not a copy the last build
/// happened to embed.
enum SafetyEvalCorpusLoader {

    /// `<repo>/OpenGlassesTests/Fixtures/SafetyEvalCorpus`.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)          // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()          // <repo>/OpenGlassesTests
            .appendingPathComponent("Fixtures/SafetyEvalCorpus", isDirectory: true)
    }

    static func object(at name: String) throws -> [String: Any] {
        let url = directory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafetyEvalError.malformed("\(name): top level is not a JSON object")
        }
        return object
    }

    static func load() throws -> SafetyEvalCorpus {
        let manifest = try object(at: "corpus.json")
        guard let version = manifest["corpus_version"] as? String,
              let schemaVersion = manifest["schema_version"] as? String,
              let licence = manifest["licence"] as? String, !licence.isEmpty,
              let files = manifest["case_files"] as? [String],
              let verticals = manifest["verticals"] as? [String],
              let riskClasses = manifest["risk_classes"] as? [String],
              let dimensions = manifest["subgroup_dimensions"] as? [String: [String]] else {
            throw SafetyEvalError.malformed("corpus.json is missing a required field")
        }

        var cases: [SafetyEvalCase] = []
        for file in files {
            let payload = try object(at: file)
            guard let raw = payload["cases"] as? [[String: Any]] else {
                throw SafetyEvalError.malformed("\(file): no `cases` array")
            }
            cases += try raw.map { try SafetyEvalCase(json: $0) }
        }

        return SafetyEvalCorpus(schemaVersion: schemaVersion, version: version, licence: licence,
                                verticals: verticals, riskClasses: riskClasses,
                                subgroupDimensions: dimensions, cases: cases)
    }

    static func loadThresholds() throws -> SafetyEvalThresholds {
        let payload = try object(at: "thresholds.json")
        guard let status = payload["status"] as? String, !status.isEmpty,
              let byClass = payload["riskClasses"] as? [String: [String: Any]],
              let gating = payload["gating"] as? [String: Any],
              let blocking = gating["blockingRiskClasses"] as? [String] else {
            throw SafetyEvalError.malformed("thresholds.json is missing a required field")
        }
        var limits: [String: SafetyEvalThresholds.Limits] = [:]
        for (name, values) in byClass {
            guard let fn = values["maxFalseNegativeRate"] as? Double,
                  let oc = values["maxOverconfidenceRate"] as? Double,
                  let ab = values["minAbstentionWhenRequiredRate"] as? Double,
                  let es = values["minEscalationPresentRate"] as? Double else {
                throw SafetyEvalError.malformed("thresholds.json: risk class '\(name)' is incomplete")
            }
            limits[name] = .init(maxFalseNegativeRate: fn, maxOverconfidenceRate: oc,
                                 minAbstentionWhenRequiredRate: ab, minEscalationPresentRate: es)
        }
        return SafetyEvalThresholds(status: status, byRiskClass: limits, blockingRiskClasses: Set(blocking))
    }
}

enum SafetyEvalError: Error, LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self { case .malformed(let m): return "Safety eval corpus: \(m)" }
    }
}

struct SafetyEvalCorpus {
    let schemaVersion: String
    let version: String
    let licence: String
    let verticals: [String]
    let riskClasses: [String]
    /// dimension name → the declared values. A case may only use declared values, and every
    /// declared value must be used: an undeclared tag is a typo, and a declared-but-unused one is a
    /// coverage claim the corpus does not meet.
    let subgroupDimensions: [String: [String]]
    let cases: [SafetyEvalCase]

    func cases(inVertical vertical: String) -> [SafetyEvalCase] {
        cases.filter { $0.vertical == vertical }
    }
}

struct SafetyEvalThresholds {
    struct Limits {
        let maxFalseNegativeRate: Double
        let maxOverconfidenceRate: Double
        let minAbstentionWhenRequiredRate: Double
        let minEscalationPresentRate: Double
    }
    /// Carried into every report so a reader cannot mistake these for approved numbers.
    let status: String
    let byRiskClass: [String: Limits]
    let blockingRiskClasses: Set<String>
}

/// One evaluation case: a model response fixture plus what the app is required to do with it.
struct SafetyEvalCase {
    let id: String
    let vertical: String
    let riskClass: String
    let notes: String?
    /// The JSON the structured-vision layer would have received, or — for the health-safety
    /// advisor, which never sees a frame — the query, the vault text and the model's advisory.
    let response: [String: Any]
    /// What the app could measure about the frame it sent. Supplied directly rather than measured
    /// from an image: these cases are about what the policy does with an indicator, and a corpus of
    /// real frames is separate work that this one does not claim to have done.
    let measuredQuality: InputQualityIndicators
    let expected: Expected
    let subgroups: [String: String]

    struct Expected {
        let tier: AssessmentTier?
        /// Health-safety only: high / caution / info / none.
        let severityBand: String?
        let hazardPresent: Bool
        let abstentionRequired: Bool
        let escalationRequired: Bool
        /// Permitted certainty outcomes, where "none" means the band must be absent. `nil` means
        /// certainty is not a concept in this vertical and is not scored.
        let allowedCertainty: [String]?
        let recaptureRequired: Bool
        let mustContain: [String]
        let mustNotContain: [String]
        let authoritativeWarningFirst: Bool
        let citations: [String]
    }

    init(json: [String: Any]) throws {
        guard let id = json["id"] as? String,
              let vertical = json["vertical"] as? String,
              let riskClass = json["riskClass"] as? String,
              let response = json["response"] as? [String: Any],
              let expected = json["expected"] as? [String: Any],
              let subgroups = json["subgroups"] as? [String: String] else {
            throw SafetyEvalError.malformed("a case is missing a required field: \(json["id"] ?? "<no id>")")
        }
        self.id = id
        self.vertical = vertical
        self.riskClass = riskClass
        self.notes = json["notes"] as? String
        self.response = response
        self.subgroups = subgroups

        let quality = json["inputQuality"] as? [String: Any] ?? [:]
        self.measuredQuality = InputQualityIndicators(sharpness: quality["sharpness"] as? Double,
                                                      meanLuminance: quality["meanLuminance"] as? Double)

        self.expected = Expected(
            tier: (expected["tier"] as? String).flatMap(AssessmentTier.init(rawValue:)),
            severityBand: expected["severityBand"] as? String,
            hazardPresent: expected["hazardPresent"] as? Bool ?? false,
            abstentionRequired: expected["abstentionRequired"] as? Bool ?? false,
            escalationRequired: expected["escalationRequired"] as? Bool ?? true,
            allowedCertainty: expected["allowedCertainty"] as? [String],
            recaptureRequired: expected["recaptureRequired"] as? Bool ?? false,
            mustContain: expected["mustContain"] as? [String] ?? [],
            mustNotContain: expected["mustNotContain"] as? [String] ?? [],
            authoritativeWarningFirst: expected["authoritativeWarningFirst"] as? Bool ?? false,
            citations: expected["citations"] as? [String] ?? [])
    }
}
