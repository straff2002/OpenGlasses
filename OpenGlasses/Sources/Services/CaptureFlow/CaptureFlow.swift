import Foundation

/// How a `FlowStep` collects its value (Plan U). Voice bindings are validated deterministically;
/// the camera bindings (barcode/photo/ocr) are sourced by the corresponding tools and the resolved
/// value is handed to the runner.
enum BindingType: String, Codable {
    case voice
    case voiceNumber = "voice_number"
    case enumChoice = "enum"
    case barcodeOrVoice = "barcode_or_voice"
    case photo
    case ocrText = "ocr_text"
}

/// The input binding for a step — its type plus any type-specific config.
struct FieldBinding: Codable, Equatable {
    let type: BindingType
    let unit: String?        // voice_number, e.g. "psig"
    let options: [String]?   // enum

    init(type: BindingType, unit: String? = nil, options: [String]? = nil) {
        self.type = type
        self.unit = unit
        self.options = options
    }
}

/// Completion criteria checked before a step is accepted.
struct Completion: Codable, Equatable {
    let minLen: Int?         // min_len — minimum trimmed length for voice
    let range: [Double]?     // [min, max] — for voice_number

    enum CodingKeys: String, CodingKey {
        case minLen = "min_len"
        case range
    }
}

/// One step of a capture flow: a prompt, an input binding, an optional completion check, and
/// whether it's required for a valid record.
struct FlowStep: Codable, Identifiable, Equatable {
    let field: String
    let prompt: String
    let binding: FieldBinding
    let required: Bool
    let completion: Completion?

    var id: String { field }

    enum CodingKeys: String, CodingKey {
        case field, prompt, binding, required, completion
    }

    init(field: String, prompt: String, binding: FieldBinding, required: Bool = false, completion: Completion? = nil) {
        self.field = field
        self.prompt = prompt
        self.binding = binding
        self.required = required
        self.completion = completion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field)
        prompt = try c.decode(String.self, forKey: .prompt)
        binding = try c.decode(FieldBinding.self, forKey: .binding)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        completion = try c.decodeIfPresent(Completion.self, forKey: .completion)
    }
}

/// A gate evaluated before the flow starts (e.g. "you must be inside the work zone").
struct FlowPrecondition: Codable, Equatable {
    let type: String          // "inside_region"
    let region: String?
    let message: String?
}

/// A declarative, typed capture template loaded from `vault/flows/*.json` (Plan U) — the field
/// analogue of an action-form. One flow can run across asset types it `appliesTo`.
struct CaptureFlow: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let appliesTo: [String]
    let steps: [FlowStep]
    let preconditions: [FlowPrecondition]

    enum CodingKeys: String, CodingKey {
        case id, title, steps, preconditions
        case appliesTo = "applies_to"
    }

    init(id: String, title: String, appliesTo: [String] = [], steps: [FlowStep], preconditions: [FlowPrecondition] = []) {
        self.id = id
        self.title = title
        self.appliesTo = appliesTo
        self.steps = steps
        self.preconditions = preconditions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        appliesTo = try c.decodeIfPresent([String].self, forKey: .appliesTo) ?? []
        steps = try c.decode([FlowStep].self, forKey: .steps)
        preconditions = try c.decodeIfPresent([FlowPrecondition].self, forKey: .preconditions) ?? []
    }

    /// Field names this flow captures — used by `FieldResolver` for cross-pack binding.
    var fieldNames: Set<String> { Set(steps.map(\.field)) }
}
