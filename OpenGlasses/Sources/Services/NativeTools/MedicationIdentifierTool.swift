import Foundation

/// Reads a medication label through the glasses camera (on-device OCR) and cross-checks it against
/// the user's `medications.md` in the Personal Health Vault (Plan I = A1 OCR × B Health Vault).
///
/// Safety-first: this reports what the *label reads* and whether it matches the user's record — it
/// never asserts a clinical identity or interaction. Gated by the Medical Compliance unlock.
@MainActor
final class MedicationIdentifierTool: NativeTool {
    let name = "identify_medication"
    let description = """
    Read a medication label through the glasses camera and cross-check it against the user's recorded \
    medications. Use for "what's this pill/bottle?", "is this my medication?". Reports the label text \
    and whether it matches the user's record (medications.md) — it does not make clinical claims. \
    Requires the Medical Compliance subscription.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:],
        "required": [] as [String]
    ]

    private let cameraService: CameraService
    private let ocr: OCRService

    init(cameraService: CameraService, ocr: OCRService = OCRService()) {
        self.cameraService = cameraService
        self.ocr = ocr
    }

    func execute(args: [String: Any]) async throws -> String {
        guard VaultRegistry.shared.isUnlocked("health") else {
            return "Medication identification needs the Medical Compliance subscription (it reads your Health Vault)."
        }
        let data: Data?
        if let frame = cameraService.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.85) {
            data = jpeg
        } else {
            data = try? await cameraService.capturePhoto()
        }
        guard let data else {
            return "Couldn't capture an image. Hold the label steady in view and try again."
        }
        let ocrText = await ocr.recognizeText(in: data).text
        guard !ocrText.isEmpty else {
            return "I couldn't read the label. Try moving closer or improving the lighting."
        }

        let readout = Self.parseLabel(ocrText)
        guard !readout.names.isEmpty else {
            return "The label reads:\n\(ocrText)\n\n[I couldn't pick out a medication name. Read it to me or confirm, and I won't guess.]"
        }

        let medsText = VaultRegistry.shared.store(forId: "health")?.read("medications.md") ?? ""
        switch Self.crossCheck(readout: readout, medicationsMarkdown: medsText) {
        case .match(let name):
            let strength = readout.strengths.first.map { " (\($0))" } ?? ""
            return "The label reads \(name)\(strength), which matches your record. (Source: medications.md)"
        case .strengthMismatch(let name, let labelStrength, let recorded):
            return "The label reads \(name) \(labelStrength), but your record says \(recorded). Please confirm before taking. (Source: medications.md)"
        case .notListed:
            let label = readout.names.joined(separator: " ") + (readout.strengths.first.map { " " + $0 } ?? "")
            return "The label reads \(label). I don't see that in your recorded medications. Please verify with the label or your pharmacist — I won't guess interactions. (Source: medications.md)"
        }
    }

    // MARK: - Parsing (pure, testable)

    struct Readout: Equatable {
        let names: [String]
        let strengths: [String]
    }

    enum CrossCheck: Equatable {
        case match(name: String)
        case strengthMismatch(name: String, labelStrength: String, recorded: String)
        case notListed
    }

    private static let strengthUnits = ["mg", "mcg", "g", "ml", "iu"]
    private static let stopWords: Set<String> = ["tablet", "tablets", "capsule", "capsules", "take",
        "daily", "twice", "once", "with", "without", "food", "oral", "solution", "extended", "release",
        "each", "contains", "store", "keep", "warning", "refill", "before", "after", "pharmacy", "rx"]

    /// Extract candidate drug names (longish alpha tokens) and strength tokens (number+unit).
    static func parseLabel(_ text: String) -> Readout {
        let lower = text.lowercased()
        var strengths: [String] = []
        // Scan tokens for "<number><unit>" or "<number> <unit>".
        let tokens = lower.components(separatedBy: CharacterSet(charactersIn: " \n\t,;()"))
        var idx = 0
        while idx < tokens.count {
            let t = tokens[idx]
            if let range = t.range(of: #"^[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
                let number = String(t[range])
                let suffix = String(t[range.upperBound...])
                if strengthUnits.contains(suffix) {
                    strengths.append("\(number)\(suffix)")
                } else if suffix.isEmpty, idx + 1 < tokens.count, strengthUnits.contains(tokens[idx + 1]) {
                    strengths.append("\(number)\(tokens[idx + 1])")
                }
            }
            idx += 1
        }

        var names: [String] = []
        var seen = Set<String>()
        for token in text.components(separatedBy: CharacterSet(charactersIn: " \n\t,;()")) {
            let clean = token.trimmingCharacters(in: .punctuationCharacters)
            guard clean.count >= 4, clean.allSatisfy({ $0.isLetter }) else { continue }
            let key = clean.lowercased()
            guard !stopWords.contains(key), seen.insert(key).inserted else { continue }
            names.append(clean)
        }
        return Readout(names: names, strengths: Array(Set(strengths)).sorted())
    }

    /// Cross-check a label readout against the user's medications markdown.
    static func crossCheck(readout: Readout, medicationsMarkdown: String) -> CrossCheck {
        let medsLower = medicationsMarkdown.lowercased()
        guard let listed = readout.names.first(where: { medsLower.contains($0.lowercased()) }) else {
            return .notListed
        }
        // If the label carries a strength and none of the label strengths appear in the record, flag it.
        if !readout.strengths.isEmpty,
           !readout.strengths.contains(where: { medsLower.contains($0.lowercased()) }) {
            let recorded = recordedStrength(near: listed, in: medicationsMarkdown) ?? "a different strength (see record)"
            return .strengthMismatch(name: listed, labelStrength: readout.strengths[0], recorded: recorded)
        }
        return .match(name: listed)
    }

    /// Find a strength token on the line that mentions `name`, for mismatch reporting.
    private static func recordedStrength(near name: String, in markdown: String) -> String? {
        for line in markdown.lowercased().split(separator: "\n") where line.contains(name.lowercased()) {
            for token in line.components(separatedBy: CharacterSet(charactersIn: " \n\t,;()|")) {
                if let range = token.range(of: #"^[0-9]+(\.[0-9]+)?(mg|mcg|g|ml|iu)$"#, options: .regularExpression) {
                    return String(token[range])
                }
            }
        }
        return nil
    }
}
