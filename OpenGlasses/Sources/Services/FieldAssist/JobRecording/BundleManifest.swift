import CryptoKit
import Foundation

/// The manifest of a recorded-job bundle (Contracts/recorded-session.md §3): the one signed
/// statement of exactly which bytes the bundle is.
///
/// A manifest has **one spelling** — its members in the contract's order, no white space, whole
/// numbers in plain decimal, and no text that needs an escape — and that spelling is what the
/// phone's application key signs. `payload()` writes it; `init(payload:)` reads only it, so a
/// payload with a member missing, added, repeated, out of order or written another way is not a
/// manifest.
///
/// Pure: it lists what it is handed. It reads no file, holds no key, and signs nothing.
struct BundleManifest: Equatable, Sendable {
    /// The bytes that come before a manifest's payload when it is signed.
    static let signingDomain = Data("Avenkin.RecordingBundle.v1\0".utf8)
    static let kind = "avenkin.recording-bundle"
    static let timelinePath = "timeline.json"
    static let transcriptPath = "transcript.json"
    static let maximumEnvelopeBytes = 1 << 20
    static let maximumChunkBytes: Int64 = 64 << 20
    static let maximumChunks = 4_096
    static let maximumParts = 256
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let containers = ["mp4", "m4a"]

    enum Role: String, Sendable {
        case timeline, transcript, media
    }

    enum Track: String, Sendable {
        case video, audio
    }

    /// One file of the bundle. A media file sits at `media/<its sha256>.chunk`.
    struct File: Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
        let role: String
    }

    /// One continuous piece of one track: its chunks joined in order are `bytes` long and have
    /// this digest.
    struct Part: Equatable, Sendable {
        let partID: String
        let track: String
        let container: String
        let chunks: [String]
        let bytes: Int64
        let sha256: String
    }

    /// The binding a bundle is sealed under.
    struct Binding: Equatable, Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let phoneTransportID: String
    }

    /// A media part as the recorder hands it over: its plan, and what it is.
    struct PlannedPart: Equatable, Sendable {
        let partID: String
        let track: Track
        let container: String
        let plan: ChunkPlan
    }

    let bundleID: String
    let binding: Binding
    let jobSessionID: String
    /// Empty when the job has no number.
    let jobNumber: String
    let createdAt: Int64
    let blurred: Bool
    let droppedFrames: Int64
    let consentAt: Int64
    let chunkBytes: Int64
    let files: [File]
    let parts: [Part]

    /// Lower-case hex SHA-256 of exact bytes.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Building

    /// The manifest of a bundle: the two JSON files as they will be sent, and each media part's
    /// plan. Nil unless the result is one the contract allows — every plan cut at `chunkBytes`,
    /// every identifier in form, consent given before sealing.
    init?(bundleID: String, binding: Binding, jobSessionID: String, jobNumber: String?, createdAt: Int64,
          blurred: Bool, droppedFrames: Int64, consentAt: Int64, chunkBytes: Int64,
          timeline: Data, transcript: Data, parts planned: [PlannedPart]) {
        guard planned.allSatisfy({ $0.plan.chunkBytes == chunkBytes && $0.plan.isWellFormed }) else { return nil }
        var files = [
            File(path: Self.timelinePath, bytes: Int64(timeline.count), sha256: Self.digest(timeline),
                 role: Role.timeline.rawValue),
            File(path: Self.transcriptPath, bytes: Int64(transcript.count), sha256: Self.digest(transcript),
                 role: Role.transcript.rawValue),
        ]
        // Identical chunks are one file, in the bundle as within a part.
        var listed: Set<String> = []
        for part in planned {
            for chunk in part.plan.chunks where listed.insert(chunk.sha256).inserted {
                files.append(File(path: chunk.path, bytes: chunk.bytes, sha256: chunk.sha256, role: Role.media.rawValue))
            }
        }
        self.init(bundleID: bundleID, binding: binding, jobSessionID: jobSessionID, jobNumber: jobNumber ?? "",
                  createdAt: createdAt, blurred: blurred, droppedFrames: droppedFrames, consentAt: consentAt,
                  chunkBytes: chunkBytes, files: files,
                  parts: planned.map {
                      Part(partID: $0.partID, track: $0.track.rawValue, container: $0.container,
                           chunks: $0.plan.chunks.map(\.sha256), bytes: $0.plan.bytes, sha256: $0.plan.sha256)
                  })
        guard isValid else { return nil }
    }

    private init(bundleID: String, binding: Binding, jobSessionID: String, jobNumber: String, createdAt: Int64,
                 blurred: Bool, droppedFrames: Int64, consentAt: Int64, chunkBytes: Int64,
                 files: [File], parts: [Part]) {
        self.bundleID = bundleID
        self.binding = binding
        self.jobSessionID = jobSessionID
        self.jobNumber = jobNumber
        self.createdAt = createdAt
        self.blurred = blurred
        self.droppedFrames = droppedFrames
        self.consentAt = consentAt
        self.chunkBytes = chunkBytes
        self.files = files
        self.parts = parts
    }

    // MARK: - The one spelling

    /// The exact bytes the phone's application key signs, or nil for a manifest the contract does
    /// not allow.
    func payload() -> Data? {
        guard isValid else { return nil }
        func text(_ value: String) -> String { "\"\(value)\"" }
        let fileList = files.map {
            #"{"path":\#(text($0.path)),"bytes":\#($0.bytes),"sha256":\#(text($0.sha256)),"role":\#(text($0.role))}"#
        }
        let partList = parts.map { part in
            #"{"partID":\#(text(part.partID)),"track":\#(text(part.track)),"container":\#(text(part.container)),"#
                + #""chunks":[\#(part.chunks.map(text).joined(separator: ","))],"bytes":\#(part.bytes),"sha256":\#(text(part.sha256))}"#
        }
        let members = [
            #""version":1"#, #""kind":\#(text(Self.kind))"#, #""bundleID":\#(text(bundleID))"#,
            #""organizationID":\#(text(binding.organizationID))"#, #""enrolmentID":\#(text(binding.enrolmentID))"#,
            #""officeID":\#(text(binding.officeID))"#, #""generation":\#(binding.generation)"#,
            #""phoneTransportID":\#(text(binding.phoneTransportID))"#, #""jobSessionID":\#(text(jobSessionID))"#,
            #""jobNumber":\#(text(jobNumber))"#, #""createdAt":\#(createdAt)"#,
            #""timelineVersion":1"#, #""transcriptVersion":1"#, #""blurred":\#(blurred)"#,
            #""droppedFrames":\#(droppedFrames)"#, #""consentAt":\#(consentAt)"#, #""chunkBytes":\#(chunkBytes)"#,
            #""files":[\#(fileList.joined(separator: ","))]"#, #""parts":[\#(partList.joined(separator: ","))]"#,
        ]
        let bytes = Data(("{" + members.joined(separator: ",") + "}").utf8)
        return bytes.count <= Self.maximumEnvelopeBytes / 2 ? bytes : nil
    }

    /// SHA-256 of the payload: what the office's receipt names.
    func payloadSHA256() -> String? { payload().map(Self.digest) }

    /// Reads a manifest from its one spelling, and from nothing else. The signer signs only bytes
    /// this accepts.
    init?(payload: Data) {
        guard !payload.isEmpty, payload.count <= Self.maximumEnvelopeBytes / 2,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        func text(_ source: [String: Any], _ key: String) -> String? { source[key] as? String }
        func whole(_ source: [String: Any], _ key: String) -> Int64? {
            guard let number = source[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) else { return nil }
            return number.int64Value
        }
        guard whole(object, "version") == 1, text(object, "kind") == Self.kind,
              whole(object, "timelineVersion") == 1, whole(object, "transcriptVersion") == 1,
              let bundleID = text(object, "bundleID"), let organizationID = text(object, "organizationID"),
              let enrolmentID = text(object, "enrolmentID"), let officeID = text(object, "officeID"),
              let generation = whole(object, "generation"), let phoneTransportID = text(object, "phoneTransportID"),
              let jobSessionID = text(object, "jobSessionID"), let jobNumber = text(object, "jobNumber"),
              let createdAt = whole(object, "createdAt"),
              let flag = object["blurred"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let droppedFrames = whole(object, "droppedFrames"), let consentAt = whole(object, "consentAt"),
              let chunkBytes = whole(object, "chunkBytes"),
              let fileObjects = object["files"] as? [[String: Any]],
              let partObjects = object["parts"] as? [[String: Any]] else { return nil }
        var files: [File] = []
        for item in fileObjects {
            guard let path = text(item, "path"), let bytes = whole(item, "bytes"),
                  let sha256 = text(item, "sha256"), let role = text(item, "role") else { return nil }
            files.append(File(path: path, bytes: bytes, sha256: sha256, role: role))
        }
        var parts: [Part] = []
        for item in partObjects {
            guard let partID = text(item, "partID"), let track = text(item, "track"),
                  let container = text(item, "container"), let chunks = item["chunks"] as? [String],
                  let bytes = whole(item, "bytes"), let sha256 = text(item, "sha256") else { return nil }
            parts.append(Part(partID: partID, track: track, container: container, chunks: chunks,
                              bytes: bytes, sha256: sha256))
        }
        self.init(bundleID: bundleID,
                  binding: Binding(organizationID: organizationID, enrolmentID: enrolmentID, officeID: officeID,
                                   generation: generation, phoneTransportID: phoneTransportID),
                  jobSessionID: jobSessionID, jobNumber: jobNumber, createdAt: createdAt, blurred: flag.boolValue,
                  droppedFrames: droppedFrames, consentAt: consentAt, chunkBytes: chunkBytes,
                  files: files, parts: parts)
        // Written again it must be the same bytes: that is what refuses a member added, repeated,
        // out of order or spelt another way.
        guard self.payload() == payload else { return nil }
    }

    /// The envelope as it is published: the exact payload and the signature over
    /// `signingDomain + payload`, each in standard base64.
    static func sealed(payload: Data, signature: Data) -> Data? {
        guard BundleManifest(payload: payload) != nil, signature.count == 64 else { return nil }
        let envelope = Data(#"{"payload":"\#(payload.base64EncodedString())","signature":"\#(signature.base64EncodedString())"}"#.utf8)
        return envelope.count <= maximumEnvelopeBytes ? envelope : nil
    }

    // MARK: - The rules

    /// Whether this manifest lists exactly a bundle, by the contract's rules.
    var isValid: Bool {
        guard Self.hex(bundleID, count: 32),
              [binding.organizationID, binding.enrolmentID, binding.officeID, jobSessionID].allSatisfy(Self.identifier),
              Self.instant(binding.generation), Self.deviceID(binding.phoneTransportID),
              Self.plain(jobNumber, maximum: 80), Self.instant(createdAt),
              droppedFrames >= 0, droppedFrames <= Self.maximumSafeInteger, blurred || droppedFrames == 0,
              Self.instant(consentAt), consentAt <= createdAt,
              chunkBytes > 0, chunkBytes <= Self.maximumChunkBytes,
              files.count >= 2, files.count <= Self.maximumChunks + 2, parts.count <= Self.maximumParts else {
            return false
        }
        // Every file once, at the one path its role and digest give it.
        var media: [String: Int64] = [:]
        var paths: Set<String> = []
        for file in files {
            guard Self.hex(file.sha256, count: 64), Self.instant(file.bytes),
                  paths.insert(file.path).inserted else { return false }
            switch Role(rawValue: file.role) {
            case .timeline?: guard file.path == Self.timelinePath else { return false }
            case .transcript?: guard file.path == Self.transcriptPath else { return false }
            case .media?:
                guard file.path == ChunkPlan.path(sha256: file.sha256), file.bytes <= chunkBytes else { return false }
                media[file.sha256] = file.bytes
            case nil: return false
            }
        }
        guard paths.contains(Self.timelinePath), paths.contains(Self.transcriptPath) else { return false }
        // Every part is made of listed chunks, each full but the last, and every chunk is in a part.
        var used: Set<String> = []
        var names: Set<String> = []
        for part in parts {
            guard Self.identifier(part.partID), names.insert(part.partID).inserted,
                  Track(rawValue: part.track) != nil, Self.containers.contains(part.container),
                  Self.hex(part.sha256, count: 64), Self.instant(part.bytes), !part.chunks.isEmpty else { return false }
            var total: Int64 = 0
            for (index, digest) in part.chunks.enumerated() {
                guard let size = media[digest], index == part.chunks.count - 1 || size == chunkBytes else { return false }
                used.insert(digest)
                total += size
            }
            guard total == part.bytes else { return false }
        }
        return used.count == media.count
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func identifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 80, value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    /// Printable ASCII that needs no escape, so it has one spelling. Empty is plain.
    private static func plain(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && value.utf8.allSatisfy {
            $0 >= 0x20 && $0 < 0x7F && ![0x22, 0x5C, 0x3C, 0x3E, 0x26].contains($0)
        }
    }

    private static func instant(_ value: Int64) -> Bool { value > 0 && value <= maximumSafeInteger }

    private static func deviceID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 8 && groups.allSatisfy { group in
            group.utf8.count == 7 && group.utf8.allSatisfy { (65...90).contains($0) || (50...55).contains($0) }
        }
    }
}
