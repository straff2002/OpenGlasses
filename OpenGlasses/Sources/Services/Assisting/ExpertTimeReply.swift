import Foundation

/// The expert's time reply (Plan KM §6, P2): sent back from Assisting mode when they tap Done.
///
/// **One of the `.ogcase` family**, not a new document type: the same zip, the same manifest name
/// (`handover.json`), type `openglasses.handover`, version 1, but kind `time`, and nothing else in
/// the file. The technician's phone opens it the way it opens any `.ogcase` and reads the kind
/// first; a handover goes to Assisting mode, a reply to the job that sent it.
///
/// It carries:
/// - the handover id, and **every generation the expert opened**;
/// - when they took it and when they were done, and the minutes on their clock — with the
///   minutes a relaunch could not count, said separately;
/// - the call minutes the expert's app saw, which is none in this version (the call is the
///   phone's, not the app's) — the field is there so the reconciliation (P4) has its place;
/// - a short note in the expert's words;
/// - **the expert's identity**: the list entry the handover was addressed to, by id and name as
///   the organisation's list has it, and the expert's card id, number and handle when they have
///   made a card — so the organisation's phone matches it to its entry exactly.
///
/// It carries no rate (decision 6) and nothing of the job beyond its reference.
struct ExpertTimeReply: Codable, Equatable, Sendable {

    static let kind = "time"
    static let noteLimit = 500

    let type: String
    let version: Int
    let kind: String

    let handoverId: String
    let jobReference: String?
    let organisation: String
    /// In order, once each.
    let generationsSeen: [Int]
    let acceptedAt: Date
    let doneAt: Date
    let minutes: Int
    /// Lost after the app was killed with the clock running.
    let uncountedMinutes: Int
    /// The call minutes the expert's app observed; nil in this version.
    let callMinutes: Int?
    let note: String?
    let expert: Expert
    let createdAt: Date

    struct Expert: Codable, Equatable, Sendable {
        /// The list entry the handover was addressed to (`ExpertHandover.expert.id`), echoed.
        let listId: String
        /// The name as the organisation's list has it.
        let listName: String
        /// The expert's card, when this phone has one.
        let cardId: String?
        let phone: String?
        let faceTimeHandle: String?
    }

    enum Refusal: Error, Equatable {
        /// The expert has not tapped Take this job.
        case notTaken
        /// The clock is still running or paused: Done comes first.
        case notDone
    }

    /// The reply for a handover the expert is done with. Pure.
    static func build(for held: HeldHandover, card: ExpertCard?, note: String?, now: Date) -> Result<ExpertTimeReply, Refusal> {
        guard let clock = held.clock else { return .failure(.notTaken) }
        guard let doneAt = clock.doneAt else { return .failure(.notDone) }
        let handover = held.handover
        return .success(ExpertTimeReply(
            type: ExpertHandover.typeIdentifier, version: ExpertHandover.version, kind: kind,
            handoverId: handover.handoverId, jobReference: handover.job.reference,
            organisation: handover.organisation.name,
            generationsSeen: Array(Set(held.generationsSeen)).sorted(),
            acceptedAt: clock.acceptedAt, doneAt: doneAt,
            minutes: clock.minutes(at: doneAt), uncountedMinutes: clock.uncountedMinutes,
            callMinutes: nil, note: cleanedNote(note),
            expert: Expert(listId: handover.expert.id, listName: handover.expert.name,
                           cardId: card?.cardId, phone: card?.phone, faceTimeHandle: card?.faceTimeHandle),
            createdAt: now))
    }

    static func cleanedNote(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(noteLimit))
    }

    /// What the expert reads before they send it, in the words the sheet shows.
    var summary: String {
        var parts: [String] = []
        parts.append(minutes == 1 ? "1 minute on the job." : "\(minutes) minutes on the job.")
        if uncountedMinutes > 0 {
            parts.append(uncountedMinutes == 1
                         ? "1 minute wasn't counted after the app closed."
                         : "\(uncountedMinutes) minutes weren't counted after the app closed.")
        }
        let updates = generationsSeen.map(String.init).joined(separator: ", ")
        parts.append(generationsSeen.count == 1 ? "You saw update \(updates)." : "You saw updates \(updates).")
        return parts.joined(separator: " ")
    }
}

/// The reply as a file: a stored zip holding only `handover.json`, kind `time`.
enum ExpertTimeReplyFile {

    enum ReadError: Error, Equatable {
        case notAZip
        case tooLarge
        case missingManifest
        case unreadableManifest
        case notAReply
        case unsupportedVersion(Int)
        /// Anything but the manifest: a reply carries nothing else.
        case unexpectedEntry(String)
    }

    /// One manifest of a few hundred bytes; anything near this is not a reply.
    static let maximumBytes = 64 * 1024

    static func write(_ reply: ExpertTimeReply) throws -> Data {
        let json = try ExpertHandoverFile.encoder().encode(reply)
        return StoredZipWriter.zip([(ExpertHandoverFile.manifestName, json)])
    }

    static func read(_ data: Data) -> Result<ExpertTimeReply, ReadError> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard let archive = ZipArchiveReader(data: data) else { return .failure(.notAZip) }
        for name in archive.entryNames.sorted() where name != ExpertHandoverFile.manifestName {
            return .failure(.unexpectedEntry(name))
        }
        guard let json = archive.entryData(named: ExpertHandoverFile.manifestName, maximumUncompressedSize: maximumBytes) else {
            return .failure(.missingManifest)
        }
        guard let header = ExpertHandoverFile.header(of: json) else { return .failure(.unreadableManifest) }
        guard header.type == ExpertHandover.typeIdentifier, header.kind == ExpertTimeReply.kind else {
            return .failure(.notAReply)
        }
        guard header.version == ExpertHandover.version else { return .failure(.unsupportedVersion(header.version)) }
        guard let reply = try? ExpertHandoverFile.decoder().decode(ExpertTimeReply.self, from: json) else {
            return .failure(.unreadableManifest)
        }
        return .success(reply)
    }

    /// "job-4471-time-reply.ogcase": the job, never a name.
    static func fileName(_ reply: ExpertTimeReply) -> String {
        let reference = reply.jobReference.map { raw in
            String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
        }
        return (reference.map { "job-\($0)-" } ?? "job-") + "time-reply." + ExpertHandoverFile.fileExtension
    }

    static func describe(_ error: ReadError) -> String {
        switch error {
        case .unsupportedVersion:
            return "That reply was made by a newer version of the app. Update the app to open it."
        case .tooLarge:
            return "That reply is larger than this app opens."
        case .notAZip, .missingManifest, .unreadableManifest, .notAReply, .unexpectedEntry:
            return "That file isn't an expert's reply this app can read."
        }
    }
}
