import Foundation
import CryptoKit

/// One coaching step, as the expert writes it in Assisting mode (Plan KM §5, P3).
///
/// **Human advice, kept as written.** An instruction, and optionally a reading to take (what, and
/// in what unit) and a "stop if". The text is tidied only where tidying cannot change a word —
/// control characters dropped, line breaks and runs of spaces made single spaces, the ends trimmed
/// — and never shortened: a step over its limit is refused by name, so the technician's assistant
/// always has the whole step to read, exactly as the expert wrote it.
struct CoachingStep: Codable, Equatable, Hashable, Identifiable, Sendable {

    static let instructionLimit = 500
    static let quantityLimit = 80
    static let unitLimit = 24
    static let stopIfLimit = 300
    static let maxSteps = 30

    /// A reading the step asks for: "inducer pressure switch", in "inWC".
    struct Reading: Codable, Equatable, Hashable, Sendable {
        let quantity: String
        let unit: String?

        init(quantity: String, unit: String? = nil) {
            self.quantity = CoachingText.clean(quantity)
            self.unit = CoachingText.nonEmpty(unit)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(quantity: try c.decode(String.self, forKey: .quantity),
                      unit: try c.decodeIfPresent(String.self, forKey: .unit))
        }

        /// "inducer pressure switch, in inWC".
        var phrase: String { unit.map { "\(quantity), in \($0)" } ?? quantity }
    }

    let id: String
    let instruction: String
    let reading: Reading?
    let stopIf: String?

    init(id: String = UUID().uuidString, instruction: String, reading: Reading? = nil, stopIf: String? = nil) {
        self.id = id
        self.instruction = CoachingText.clean(instruction)
        self.reading = reading.flatMap { $0.quantity.isEmpty ? nil : $0 }
        self.stopIf = CoachingText.nonEmpty(stopIf)
    }

    /// The step from what the editor's fields hold: an empty reading or stop-if is none.
    init(id: String = UUID().uuidString, instruction: String, readingQuantity: String?, readingUnit: String?,
         stopIf: String?) {
        let quantity = CoachingText.nonEmpty(readingQuantity)
        self.init(id: id, instruction: instruction,
                  reading: quantity.map { Reading(quantity: $0, unit: readingUnit) }, stopIf: stopIf)
    }

    private enum CodingKeys: String, CodingKey { case id, instruction, reading, stopIf }

    /// Decoding tidies exactly as the editor does, so a file's step is the step it would have been
    /// had it been typed here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  instruction: try c.decode(String.self, forKey: .instruction),
                  reading: try c.decodeIfPresent(Reading.self, forKey: .reading),
                  stopIf: try c.decodeIfPresent(String.self, forKey: .stopIf))
    }

    /// Why this step cannot be sent, or nil.
    var problem: String? {
        if instruction.isEmpty { return "a step has no instruction" }
        if instruction.count > Self.instructionLimit {
            return "a step is longer than \(Self.instructionLimit) characters"
        }
        if let reading {
            if reading.quantity.count > Self.quantityLimit {
                return "a reading's name is longer than \(Self.quantityLimit) characters"
            }
            if let unit = reading.unit, unit.count > Self.unitLimit {
                return "a reading's unit is longer than \(Self.unitLimit) characters"
            }
        }
        if let stopIf, stopIf.count > Self.stopIfLimit {
            return "a stop-if is longer than \(Self.stopIfLimit) characters"
        }
        if !CoachingText.isSafeIdentifier(id) { return "a step's id isn't one this app writes" }
        return nil
    }
}

/// The tidying every coaching field goes through. Pure.
enum CoachingText {
    /// Control characters dropped, every run of white space (line breaks included) one space, the
    /// ends trimmed. Nothing else: no word is changed, added or removed.
    static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            scalars.append(scalar)
            lastWasSpace = false
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = clean(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Letters, digits and hyphens, 1–64 of them: what this app's ids are made of.
    static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }
}

/// The expert's coaching reply (Plan KM §5, P3): the steps they wrote for **one** handover, sent
/// back the way the time reply goes.
///
/// **One of the `.ogcase` family**, like the time reply: the same zip, the same manifest name
/// (`handover.json`), type `openglasses.handover`, version 1, kind `coaching`, and nothing else in
/// the file. It carries:
/// - the handover id and every generation the expert opened;
/// - **the expert's identity**, exactly as the time reply carries it (the list entry the handover
///   was addressed to, and their card's id, number and handle when they have a card);
/// - the steps, in order.
///
/// It carries no rate (decision 6) and nothing of the job beyond its reference. The technician's
/// phone loads the steps only when the reply answers a handover it sent, on a job still open, from
/// the expert it went to (`CoachingReplyMatch`); anything else is a file it didn't ask for.
struct ExpertCoachingReply: Codable, Equatable, Sendable {

    static let kind = "coaching"

    let type: String
    let version: Int
    let kind: String

    /// The same steps for the same handover give the same id, so sending them twice is one reply.
    let coachingId: String
    let handoverId: String
    let jobReference: String?
    let organisation: String
    /// In order, once each.
    let generationsSeen: [Int]
    let steps: [CoachingStep]
    let expert: ExpertTimeReply.Expert
    let createdAt: Date

    enum Refusal: Error, Equatable {
        case noSteps
        case tooManySteps
        /// Step `number` (from 1) and why.
        case step(Int, String)

        var message: String {
            switch self {
            case .noSteps: return "Add a step first."
            case .tooManySteps: return "Coaching can have at most \(CoachingStep.maxSteps) steps."
            case .step(let number, let why): return "Step \(number): \(why)."
            }
        }
    }

    /// The reply for the steps the expert wrote on a handover they hold. Pure.
    static func build(for held: HeldHandover, steps: [CoachingStep], card: ExpertCard?,
                      now: Date) -> Result<ExpertCoachingReply, Refusal> {
        if let refusal = problem(steps) { return .failure(refusal) }
        let handover = held.handover
        return .success(ExpertCoachingReply(
            type: ExpertHandover.typeIdentifier, version: ExpertHandover.version, kind: kind,
            coachingId: coachingId(handoverId: handover.handoverId, steps: steps),
            handoverId: handover.handoverId, jobReference: handover.job.reference,
            organisation: handover.organisation.name,
            generationsSeen: Array(Set(held.generationsSeen)).sorted(),
            steps: steps,
            expert: ExpertTimeReply.Expert(listId: handover.expert.id, listName: handover.expert.name,
                                           cardId: card?.cardId, phone: card?.phone,
                                           faceTimeHandle: card?.faceTimeHandle),
            createdAt: now))
    }

    static func problem(_ steps: [CoachingStep]) -> Refusal? {
        if steps.isEmpty { return .noSteps }
        if steps.count > CoachingStep.maxSteps { return .tooManySteps }
        for (index, step) in steps.enumerated() {
            if let why = step.problem { return .step(index + 1, why) }
        }
        return nil
    }

    /// A digest of the handover and the steps' words: the same steps give the same id.
    static func coachingId(handoverId: String, steps: [CoachingStep]) -> String {
        var text = handoverId
        for step in steps {
            text += "\u{1F}" + step.instruction + "\u{1E}" + (step.reading?.quantity ?? "") + "\u{1E}"
                + (step.reading?.unit ?? "") + "\u{1E}" + (step.stopIf ?? "")
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "coach-" + String(digest.prefix(32))
    }

    /// What the expert reads before they send it.
    var summary: String {
        let count = steps.count == 1 ? "1 step" : "\(steps.count) steps"
        let updates = generationsSeen.map(String.init).joined(separator: ", ")
        return generationsSeen.count == 1 ? "\(count), for update \(updates)." : "\(count), for updates \(updates)."
    }
}

/// The coaching reply as a file: a stored zip holding only `handover.json`, kind `coaching`.
enum ExpertCoachingReplyFile {

    enum ReadError: Error, Equatable {
        case notAZip
        case tooLarge
        case missingManifest
        case unreadableManifest
        case notCoaching
        case unsupportedVersion(Int)
        /// Anything but the manifest: a reply carries nothing else.
        case unexpectedEntry(String)
        /// The steps aren't ones this app would have written.
        case badSteps
    }

    /// Thirty steps at their limits is under 40 KB of JSON.
    static let maximumBytes = 128 * 1024

    static func write(_ reply: ExpertCoachingReply) throws -> Data {
        let json = try ExpertHandoverFile.encoder().encode(reply)
        return StoredZipWriter.zip([(ExpertHandoverFile.manifestName, json)])
    }

    static func read(_ data: Data) -> Result<ExpertCoachingReply, ReadError> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard let archive = ZipArchiveReader(data: data) else { return .failure(.notAZip) }
        for name in archive.entryNames.sorted() where name != ExpertHandoverFile.manifestName {
            return .failure(.unexpectedEntry(name))
        }
        guard let json = archive.entryData(named: ExpertHandoverFile.manifestName, maximumUncompressedSize: maximumBytes) else {
            return .failure(.missingManifest)
        }
        guard let header = ExpertHandoverFile.header(of: json) else { return .failure(.unreadableManifest) }
        guard header.type == ExpertHandover.typeIdentifier, header.kind == ExpertCoachingReply.kind else {
            return .failure(.notCoaching)
        }
        guard header.version == ExpertHandover.version else { return .failure(.unsupportedVersion(header.version)) }
        guard let reply = try? ExpertHandoverFile.decoder().decode(ExpertCoachingReply.self, from: json) else {
            return .failure(.unreadableManifest)
        }
        guard ExpertCoachingReply.problem(reply.steps) == nil, CoachingText.isSafeIdentifier(reply.coachingId),
              Set(reply.steps.map(\.id)).count == reply.steps.count else {
            return .failure(.badSteps)
        }
        return .success(reply)
    }

    /// "job-4471-coaching.ogcase": the job, never a name.
    static func fileName(_ reply: ExpertCoachingReply) -> String {
        let reference = reply.jobReference.map { raw in
            String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
        }
        return (reference.map { "job-\($0)-" } ?? "job-") + "coaching." + ExpertHandoverFile.fileExtension
    }

    static func describe(_ error: ReadError) -> String {
        switch error {
        case .unsupportedVersion:
            return "Those coaching steps were made by a newer version of the app. Update the app to open them."
        case .tooLarge:
            return "That coaching file is larger than this app opens."
        case .notAZip, .missingManifest, .unreadableManifest, .notCoaching, .unexpectedEntry, .badSteps:
            return "That file isn't coaching this app can read, so nothing was loaded."
        }
    }
}
