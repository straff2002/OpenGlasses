import Foundation

/// The outcome of answering the current step.
enum AnswerOutcome: Equatable {
    case accepted(next: String)      // stored; here's the next prompt
    case rejected(reason: String)    // failed validation → re-prompt the same step
    case finished                    // that was the last step — call finish
}

enum FinishOutcome: Equatable {
    case completed(CaptureRecord)
    case missingRequired([String])   // required fields not captured
}

/// Drives a `CaptureFlow` step by step (Plan U): prompt → capture → validate → next, emitting a
/// structured `CaptureRecord`. Deterministic and dependency-light — voice / voice_number / enum
/// bindings are validated here; camera bindings store the value the sourcing tool resolved. Pure
/// enough to unit-test without a vault, session, mic, or camera.
@MainActor
final class CaptureFlowRunner {
    let flow: CaptureFlow
    private(set) var record: CaptureRecord
    private(set) var index = 0

    /// Current GPS for provenance / preconditions (injected; nil when unknown).
    private let location: () -> (lat: Double, lon: Double)?
    /// region id → inside? (nil = can't determine). Injected from the geofence layer.
    private let insideRegion: (String) -> Bool?

    init(flow: CaptureFlow,
         sessionId: String,
         assetId: String? = nil,
         location: @escaping () -> (lat: Double, lon: Double)? = { nil },
         insideRegion: @escaping (String) -> Bool? = { _ in nil }) {
        self.flow = flow
        self.record = CaptureRecord(flowId: flow.id, sessionId: sessionId, assetId: assetId)
        self.location = location
        self.insideRegion = insideRegion
    }

    var currentStep: FlowStep? { index < flow.steps.count ? flow.steps[index] : nil }
    var isComplete: Bool { index >= flow.steps.count }

    /// "Step n of N: <prompt>" for HUD/TTS, or a finish hint when past the last step.
    func prompt() -> String {
        guard let step = currentStep else { return "All steps captured — say finish to save." }
        return "Step \(index + 1) of \(flow.steps.count): \(step.prompt)"
    }

    func status() -> String {
        let captured = record.fields.map { "\($0.field)=\($0.value.display)" }
        let progress = "\(record.fields.count)/\(flow.steps.count) captured"
        return ([prompt(), progress] + (captured.isEmpty ? [] : ["So far: " + captured.joined(separator: ", ")]))
            .joined(separator: "\n")
    }

    /// Preconditions that aren't satisfied (e.g. outside the work zone). Empty ⇒ ok to proceed.
    /// Unknown (no location / can't determine) is treated as *not blocking* but is reported so the
    /// caller can warn — never a hard stop on missing GPS.
    func unmetPreconditions() -> [FlowPrecondition] {
        flow.preconditions.filter { pre in
            guard pre.type == "inside_region", let region = pre.region else { return false }
            return insideRegion(region) == false   // only a definite "outside" is unmet
        }
    }

    // MARK: - Capture

    /// Provide an answer for the current step. The runner validates per the binding + completion;
    /// on success it stores the typed value (with provenance) and advances.
    func answer(_ raw: String) -> AnswerOutcome {
        guard let step = currentStep else { return .finished }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        switch step.binding.type {
        case .voice, .ocrText, .barcodeOrVoice:
            if let min = step.completion?.minLen, trimmed.count < min {
                return .rejected(reason: "that seems too short — \(step.prompt)")
            }
            guard !trimmed.isEmpty else { return .rejected(reason: "I didn't catch that — \(step.prompt)") }
            let value: CaptureValue = step.binding.type == .barcodeOrVoice ? .code(trimmed) : .text(trimmed)
            return store(step, value, method: method(for: step.binding.type))

        case .voiceNumber:
            guard let n = Self.parseNumber(trimmed) else {
                return .rejected(reason: "I need a number for \(step.field) — \(step.prompt)")
            }
            if let range = step.completion?.range, range.count == 2, (n < range[0] || n > range[1]) {
                return .rejected(reason: "that's out of range (\(short(range[0]))–\(short(range[1]))) — read it again")
            }
            return store(step, .number(n, unit: step.binding.unit), method: "voice_number")

        case .enumChoice:
            guard let option = Self.resolveOption(trimmed, options: step.binding.options ?? []) else {
                let opts = (step.binding.options ?? []).joined(separator: ", ")
                return .rejected(reason: "say one of: \(opts)")
            }
            return store(step, .option(option), method: "enum")

        case .photo:
            // `raw` is the photo file path the camera tool resolved.
            guard !trimmed.isEmpty else { return .rejected(reason: "no photo captured — \(step.prompt)") }
            return store(step, .photo(path: trimmed), method: "photo")
        }
    }

    /// Advance without capturing (a required field left blank will block `finish`).
    func skip() -> AnswerOutcome {
        guard currentStep != nil else { return .finished }
        index += 1
        return isComplete ? .finished : .accepted(next: prompt())
    }

    /// Step back to the previous field (re-answering overwrites).
    func back() -> AnswerOutcome {
        index = max(0, index - 1)
        return .accepted(next: prompt())
    }

    /// Finalise: blocks only on missing **required** fields.
    func finish() -> FinishOutcome {
        let required = flow.steps.filter(\.required).map(\.field)
        let captured = Set(record.fields.map(\.field))
        let missing = required.filter { !captured.contains($0) }
        guard missing.isEmpty else { return .missingRequired(missing) }
        record.finishedAt = Date()
        return .completed(record)
    }

    // MARK: - Helpers

    private func store(_ step: FlowStep, _ value: CaptureValue, method: String) -> AnswerOutcome {
        let loc = location()
        record.set(step.field, value: value,
                   provenance: Provenance(method: method, lat: loc?.lat, lon: loc?.lon))
        index += 1
        return isComplete ? .finished : .accepted(next: prompt())
    }

    private func method(for type: BindingType) -> String {
        switch type {
        case .ocrText: return "ocr"
        case .barcodeOrVoice: return "barcode"
        default: return "voice"
        }
    }

    private func short(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    /// Pull the first number out of free speech ("about 118 psi" → 118).
    static func parseNumber(_ text: String) -> Double? {
        if let d = Double(text) { return d }
        guard let regex = try? NSRegularExpression(pattern: #"[-+]?[0-9]*\.?[0-9]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return Double(text[r])
    }

    /// Map a spoken phrase to one of `options` deterministically (exact, then substring either way).
    /// Returns nil on no match or ambiguity.
    static func resolveOption(_ phrase: String, options: [String]) -> String? {
        let p = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        if let exact = options.first(where: { $0.lowercased() == p }) { return exact }
        let contains = options.filter { p.contains($0.lowercased()) || $0.lowercased().contains(p) }
        return contains.count == 1 ? contains[0] : nil
    }
}
