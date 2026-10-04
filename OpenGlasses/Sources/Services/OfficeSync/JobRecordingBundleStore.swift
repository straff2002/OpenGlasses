import CryptoKit
import Foundation

/// A recorded job's bundle on the phone (Contracts/recorded-session.md §3), and the phone's own
/// record of where it stands with the office.
///
/// A bundle lives with its job, under the job's own folder, and goes when the job goes:
///
/// ```
/// <job>/recording/bundle/
///   timeline.json  transcript.json      the two files the manifest lists
///   media/<sha256>.chunk                each media part, cut into chunks named by digest
///   manifest.json  manifest.signature   the manifest's one spelling and the phone's signature
///   receipts/<status>.envelope.json     what the office said, exactly as it said it
///   record.json                         this phone's record of the bundle
/// ```
///
/// Sealing cuts each recorded part into chunks, lists exactly those files in a manifest, and has
/// the phone application key sign it. From then on nothing in the bundle changes. **Nothing here
/// removes media by itself**: `trimMedia` and `delete` are called by the sync service, on the
/// retention rules or the technician's say.
struct JobRecordingBundleStore: Sendable {

    /// Where the bundle stands, as it is kept on disk.
    enum Stage: Codable, Equatable, Sendable {
        /// Sealed and not yet all served: waiting, or on its way.
        case sealed
        /// Every file has been served. The office has not said it has the bundle.
        case delivered
        /// The office's verified receipt says it holds the bundle.
        case acknowledged
        /// Acknowledged, and the media since removed from the phone.
        case trimmed
        /// The office refused it, with its reason.
        case failed(String)
        /// Too long without a receipt. Nothing is removed; the technician is asked.
        case expired
    }

    struct Chunk: Codable, Equatable, Sendable {
        let sha256: String
        let bytes: Int64
    }

    /// What came of a recording at the office, when it has said.
    struct Outcome: Codable, Equatable, Sendable {
        /// `reviewed`, `published` or `rejected`.
        let status: String
        let vaultID: String
        let vaultVersion: String
        let at: Int64
    }

    struct Record: Codable, Equatable, Sendable, Identifiable {
        let bundleID: String
        let sessionID: String
        let manifestSHA256: String
        /// The generation of the binding the manifest was sealed under: a receipt names it.
        let generation: Int64
        /// Every file the manifest lists, and the media among them.
        let totalBytes: Int64
        let mediaBytes: Int64
        let chunkBytes: Int64
        /// The media chunks, in the order they are sent.
        let chunks: [Chunk]
        let sealedAt: Date
        var stage: Stage
        /// Whether the manifest has been handed to the transport since the bundle was sealed or
        /// last offered again.
        var transferStarted = false
        /// How many chunks have been handed to the transport.
        var publishedChunks = 0
        /// Bytes the office no longer needs, as the transport last counted them.
        var sentBytes: Int64 = 0
        /// When it was sealed — or, if the technician has since chosen to keep waiting, when they did.
        var waitingSince: Date
        var acknowledgedAt: Date?
        var outcome: Outcome?
        /// Digests of the office's messages already acted on, so one is acted on once.
        var seenReceipts: [String] = []

        var id: String { bundleID }
    }

    /// One recorded part as the recorder left it.
    struct PartFile: Sendable {
        let partID: String
        let track: BundleManifest.Track
        let container: String
        let file: URL
    }

    struct SealInput: Sendable {
        let bundleID: String
        let sessionID: String
        let jobNumber: String?
        let binding: BundleManifest.Binding
        let consentAt: Date
        let blurred: Bool
        let droppedFrames: Int64
        var chunkBytes: Int64 = ChunkPlan.proposedChunkBytes
        let timeline: Data
        let transcript: Data
        let parts: [PartFile]
    }

    enum Failure: Error, Equatable {
        /// The session identifier or bundle identifier is not one a path may be built from.
        case notAnIdentifier
        /// A recorded part could not be read, or has nothing in it.
        case unreadablePart
        /// What was handed over does not make a manifest the contract allows.
        case notABundle
        /// The signer returned something that is not this manifest's signature.
        case notSigned
    }

    /// The folder every job's own folder is in.
    let sessionsRoot: URL

    // MARK: - Where things are

    func bundleDirectory(sessionID: String) -> URL {
        sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("recording", isDirectory: true)
            .appendingPathComponent("bundle", isDirectory: true)
    }

    func timelineFile(_ record: Record) -> URL {
        bundleDirectory(sessionID: record.sessionID).appendingPathComponent(BundleManifest.timelinePath)
    }

    func transcriptFile(_ record: Record) -> URL {
        bundleDirectory(sessionID: record.sessionID).appendingPathComponent(BundleManifest.transcriptPath)
    }

    func chunkFile(_ record: Record, sha256: String) -> URL {
        bundleDirectory(sessionID: record.sessionID).appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("\(sha256).chunk")
    }

    /// The manifest's exact bytes and the phone's signature over them.
    func manifest(_ record: Record) throws -> (payload: Data, signature: Data) {
        let directory = bundleDirectory(sessionID: record.sessionID)
        return (try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                try Data(contentsOf: directory.appendingPathComponent("manifest.signature")))
    }

    // MARK: - Sealing

    /// Cuts the recorded parts into chunks, lists the bundle in a manifest, has it signed, and
    /// writes the phone's record of it. The recorded part files are removed once the bundle is
    /// sealed: their chunks are the recording from then on.
    func seal(_ input: SealInput, now: Date, sign: (Data) async throws -> Data) async throws -> Record {
        guard Self.identifier(input.sessionID), Self.hex(input.bundleID, count: 32) else { throw Failure.notAnIdentifier }
        let directory = bundleDirectory(sessionID: input.sessionID)
        let media = directory.appendingPathComponent("media", isDirectory: true)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: media, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        do {
            try Self.write(input.timeline, to: directory.appendingPathComponent(BundleManifest.timelinePath))
            try Self.write(input.transcript, to: directory.appendingPathComponent(BundleManifest.transcriptPath))
            var planned: [BundleManifest.PlannedPart] = []
            for part in input.parts {
                let plan = try Self.cut(part.file, chunkBytes: input.chunkBytes, into: media)
                planned.append(.init(partID: part.partID, track: part.track, container: part.container, plan: plan))
            }
            guard let manifest = BundleManifest(
                bundleID: input.bundleID, binding: input.binding, jobSessionID: input.sessionID,
                jobNumber: input.jobNumber, createdAt: Int64(now.timeIntervalSince1970), blurred: input.blurred,
                droppedFrames: input.droppedFrames, consentAt: Int64(input.consentAt.timeIntervalSince1970),
                chunkBytes: input.chunkBytes, timeline: input.timeline, transcript: input.transcript,
                parts: planned), let payload = manifest.payload() else { throw Failure.notABundle }
            let signature = try await sign(payload)
            guard BundleManifest.sealed(payload: payload, signature: signature) != nil else { throw Failure.notSigned }
            try Self.write(payload, to: directory.appendingPathComponent("manifest.json"))
            try Self.write(signature, to: directory.appendingPathComponent("manifest.signature"))
            let chunks = manifest.files.filter { $0.role == BundleManifest.Role.media.rawValue }
            let record = Record(
                bundleID: input.bundleID, sessionID: input.sessionID, manifestSHA256: BundleManifest.digest(payload),
                generation: input.binding.generation, totalBytes: manifest.files.reduce(0) { $0 + $1.bytes },
                mediaBytes: chunks.reduce(0) { $0 + $1.bytes }, chunkBytes: input.chunkBytes,
                chunks: chunks.map { Chunk(sha256: $0.sha256, bytes: $0.bytes) }, sealedAt: now, stage: .sealed,
                waitingSince: now)
            try save(record)
            for part in input.parts { try? manager.removeItem(at: part.file) }
            return record
        } catch {
            // Half a bundle is no bundle: the recorded parts are still where they were.
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    /// Cuts one part into chunk files named by their digests, reading it in pieces so a part of
    /// any size is never held in memory.
    private static func cut(_ file: URL, chunkBytes: Int64, into media: URL) throws -> ChunkPlan {
        guard chunkBytes > 0, var builder = ChunkPlan.Builder(chunkBytes: chunkBytes),
              let source = try? FileHandle(forReadingFrom: file) else { throw Failure.unreadablePart }
        defer { try? source.close() }
        let manager = FileManager.default
        var staged: [URL] = []
        var current: FileHandle?
        var room: Int64 = 0
        func open() throws {
            let url = media.appendingPathComponent("cutting-\(UUID().uuidString).tmp")
            guard manager.createFile(atPath: url.path, contents: nil,
                                     attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else {
                throw Failure.unreadablePart
            }
            staged.append(url)
            current = try FileHandle(forWritingTo: url)
            room = chunkBytes
        }
        do {
            while let piece = try source.read(upToCount: 1 << 20), !piece.isEmpty {
                builder.append(piece)
                var rest = piece[...]
                while !rest.isEmpty {
                    if current == nil { try open() }
                    let take = rest.prefix(Int(min(room, Int64(rest.count))))
                    try current?.write(contentsOf: take)
                    room -= Int64(take.count)
                    rest = rest.dropFirst(take.count)
                    if room == 0 {
                        try current?.close()
                        current = nil
                    }
                }
            }
            try current?.close()
            guard let plan = builder.finish(), plan.chunks.count == staged.count else { throw Failure.unreadablePart }
            for (chunk, url) in zip(plan.chunks, staged) {
                let destination = media.appendingPathComponent("\(chunk.sha256).chunk")
                // Two chunks with the same bytes are one file.
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: url)
                } else {
                    try manager.moveItem(at: url, to: destination)
                }
            }
            return plan
        } catch {
            try? current?.close()
            for url in staged { try? manager.removeItem(at: url) }
            throw error
        }
    }

    // MARK: - The record

    /// Every bundle on this phone, oldest first.
    func records() -> [Record] {
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        return sessions.compactMap { sessionID -> Record? in
            guard Self.identifier(sessionID),
                  let data = try? Data(contentsOf: bundleDirectory(sessionID: sessionID).appendingPathComponent("record.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.sessionID == sessionID else { return nil }
            return record
        }.sorted { ($0.sealedAt, $0.bundleID) < ($1.sealedAt, $1.bundleID) }
    }

    func save(_ record: Record) throws {
        try Self.write(try JSONEncoder().encode(record),
                       to: bundleDirectory(sessionID: record.sessionID).appendingPathComponent("record.json"))
    }

    /// Keeps what the office said, exactly as it said it.
    func keepReceipt(_ record: Record, status: String, envelope: Data) throws {
        let receipts = bundleDirectory(sessionID: record.sessionID).appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try Self.write(envelope, to: receipts.appendingPathComponent("\(status).envelope.json"))
    }

    /// Removes the media and nothing else: the timeline, the transcript, the manifest, the
    /// receipts and the record stay with the job.
    func trimMedia(_ record: Record) throws {
        let media = bundleDirectory(sessionID: record.sessionID).appendingPathComponent("media", isDirectory: true)
        if FileManager.default.fileExists(atPath: media.path) { try FileManager.default.removeItem(at: media) }
    }

    /// Removes the whole recording for a job.
    func delete(_ record: Record) throws {
        let recording = bundleDirectory(sessionID: record.sessionID).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: recording.path) { try FileManager.default.removeItem(at: recording) }
    }

    /// The media held for recordings the office has not acknowledged.
    func unsyncedBytes() -> Int64 {
        records().filter { $0.acknowledgedAt == nil }.reduce(0) { $0 + $1.mediaBytes }
    }

    // MARK: - Small things

    private static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func identifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 80, value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    /// A new bundle identifier: 32 lower-case hexadecimal characters of the system's randomness.
    static func newBundleID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func defaultSessionsRoot() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FieldSessions", isDirectory: true)
    }
}
