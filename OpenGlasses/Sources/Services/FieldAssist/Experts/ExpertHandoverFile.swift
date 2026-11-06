import Foundation

/// The `.ogcase` file (Plan KM P1): a handover as one document the expert's app opens.
///
/// **A zip with stored entries**, not a directory package. Messages, Mail, WhatsApp and AirDrop all
/// carry one file; a package directory has to be zipped by whoever sends it, and some routes do not.
/// The pictures are already JPEGs, so nothing is gained by compressing them again, and a stored zip
/// is something this app can write without a library and read with the strict reader it already
/// has (`ZipArchiveReader`).
///
/// It holds exactly:
/// - `handover.json` — the `ExpertHandover`, type `openglasses.handover`, version 1;
/// - `photos/NN.jpg` — one per photo the JSON lists, each already blurred.
///
/// Nothing else is written and **the reader accepts nothing else**: a missing `handover.json`, a
/// wrong type or version, an entry the JSON does not name, a photo it names that is missing, or any
/// path that tries to leave the package is a refusal, by name. The app writes this file, unlike
/// `.ogjob`, which it only ever receives. It carries no signature: a handover is a document, not a
/// key (§7), and opening one grants nothing.
///
/// The expert's time reply (Plan KM P2, `ExpertTimeReplyFile`) and coaching reply (P3,
/// `ExpertCoachingReplyFile`) are the same family: the same zip and manifest name, kinds `time` and
/// `coaching`, each read by its own reader. `received(_:)` reads the kind first.
enum ExpertHandoverFile {

    static let fileExtension = "ogcase"
    /// Declared in `Info.plist` beside the job file, opened as a copy.
    static let utiIdentifier = "com.openglasses.app.handover"
    static let mimeType = "application/vnd.openglasses.handover+zip"
    static let manifestName = "handover.json"
    static let photosFolder = "photos"

    /// Generous for a handful of 1,280-pixel JPEGs, and a hard ceiling on what a reader inflates.
    static let maximumBytes = 40 * 1024 * 1024
    static let maximumPhotos = 40

    static func photoEntryName(index: Int) -> String {
        String(format: "%@/%02d.jpg", photosFolder, index + 1)
    }

    /// Whether a URL a share or a file open handed the app is a handover file.
    static func isHandoverFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    // MARK: - Writing

    enum WriteError: Error, Equatable {
        /// The JSON lists a photo whose JPEG was not handed in.
        case missingPhoto(String)
        case tooManyPhotos
        case encodingFailed
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The file's bytes. `photos` maps each `ExpertHandover.Photo.file` to its JPEG.
    static func write(_ handover: ExpertHandover, photos: [String: Data]) throws -> Data {
        guard handover.photos.count <= maximumPhotos else { throw WriteError.tooManyPhotos }
        guard let json = try? encoder().encode(handover) else { throw WriteError.encodingFailed }
        var entries: [(name: String, data: Data)] = [(manifestName, json)]
        for photo in handover.photos {
            guard let data = photos[photo.file] else { throw WriteError.missingPhoto(photo.file) }
            entries.append((photo.file, data))
        }
        return StoredZipWriter.zip(entries)
    }

    // MARK: - Reading

    enum ReadError: Error, Equatable {
        case notAZip
        case tooLarge
        case missingManifest
        case unreadableManifest
        case notAHandover
        case unsupportedVersion(Int)
        case unsafeEntryPath(String)
        /// An entry the JSON does not name.
        case unexpectedEntry(String)
        /// A photo the JSON names that is not in the file.
        case missingPhoto(String)
        case tooManyPhotos
    }

    struct Opened: Equatable {
        let handover: ExpertHandover
        /// Each photo's JPEG, by its entry name.
        let photos: [String: Data]
    }

    /// Read and check a handover file. Pure; refuses anything that is not exactly what `write`
    /// produces.
    static func read(_ data: Data) -> Result<Opened, ReadError> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard let archive = ZipArchiveReader(data: data) else { return .failure(.notAZip) }
        let names = archive.entryNames
        // Every name is checked before anything is read: a hostile entry fails the file whole.
        for name in names.sorted() {
            guard VaultArchiveReader.isSafeRelativePath(name) else { return .failure(.unsafeEntryPath(name)) }
        }
        guard names.contains(manifestName),
              let json = archive.entryData(named: manifestName, maximumUncompressedSize: maximumBytes) else {
            return .failure(.missingManifest)
        }
        // The type and version first, so a newer file says so rather than "unreadable".
        guard let header = header(of: json) else { return .failure(.unreadableManifest) }
        guard header.type == ExpertHandover.typeIdentifier, header.kind == ExpertHandover.kind else {
            return .failure(.notAHandover)
        }
        guard header.version == ExpertHandover.version else { return .failure(.unsupportedVersion(header.version)) }
        guard let handover = try? decoder().decode(ExpertHandover.self, from: json) else {
            return .failure(.unreadableManifest)
        }
        guard handover.photos.count <= maximumPhotos else { return .failure(.tooManyPhotos) }
        let listed = Set(handover.photos.map(\.file))
        for name in names.sorted() where name != manifestName && !listed.contains(name) {
            return .failure(.unexpectedEntry(name))
        }
        var photos: [String: Data] = [:]
        var total = json.count
        for photo in handover.photos {
            guard photo.file.hasPrefix(photosFolder + "/"), VaultArchiveReader.isSafeRelativePath(photo.file) else {
                return .failure(.unsafeEntryPath(photo.file))
            }
            guard names.contains(photo.file),
                  let bytes = archive.entryData(named: photo.file, maximumUncompressedSize: maximumBytes) else {
                return .failure(.missingPhoto(photo.file))
            }
            total += bytes.count
            guard total <= maximumBytes else { return .failure(.tooLarge) }
            photos[photo.file] = bytes
        }
        return .success(Opened(handover: handover, photos: photos))
    }

    // MARK: - Opening one on this phone

    /// What an `.ogcase` handed to the app turned out to be (Plan KM P2, P3). The family has three
    /// kinds this version reads: a **handover**, which goes to Assisting mode, and an expert's
    /// **time reply** or **coaching reply**, which go to the job that sent the handover — and only
    /// if this phone sent it. The kind is read before anything else, and each is then read by its
    /// own strict reader.
    enum Received: Equatable {
        case handover(Opened)
        case timeReply(ExpertTimeReply)
        case coachingReply(ExpertCoachingReply)
        /// Refused, in the words a notice shows.
        case refused(String)
    }

    /// Read the file iOS handed over, remove the copy it put in the inbox, and say what it is.
    /// Nothing is kept or applied here.
    @MainActor
    static func receive(_ url: URL) -> Received {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defer { discardInboxCopy(url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maximumBytes, let data = try? Data(contentsOf: url) else { return .refused(describe(.tooLarge)) }
        return received(data)
    }

    /// The same, over bytes. Pure.
    static func received(_ data: Data) -> Received {
        let manifestKind = kind(of: data)
        if manifestKind == ExpertCoachingReply.kind {
            switch ExpertCoachingReplyFile.read(data) {
            case .success(let reply): return .coachingReply(reply)
            case .failure(let error): return .refused(ExpertCoachingReplyFile.describe(error))
            }
        }
        if manifestKind == ExpertTimeReply.kind {
            switch ExpertTimeReplyFile.read(data) {
            case .success(let reply): return .timeReply(reply)
            case .failure(let error): return .refused(ExpertTimeReplyFile.describe(error))
            }
        }
        switch read(data) {
        case .success(let opened): return .handover(opened)
        case .failure(let error): return .refused(describe(error))
        }
    }

    /// The manifest's kind, without reading the rest: nil when the bytes are not an `.ogcase`.
    static func kind(of data: Data) -> String? {
        guard data.count <= maximumBytes, let archive = ZipArchiveReader(data: data),
              let json = archive.entryData(named: manifestName, maximumUncompressedSize: maximumBytes) else { return nil }
        return header(of: json)?.kind
    }

    private static func discardInboxCopy(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The fields read before the whole value, so a version this build does not know is named.
    struct Header: Decodable, Equatable {
        let type: String
        let version: Int
        let kind: String
    }

    static func header(of json: Data) -> Header? {
        try? decoder().decode(Header.self, from: json)
    }

    /// Why a file was refused, in the words a notice shows. Never a path from the file.
    static func describe(_ error: ReadError) -> String {
        switch error {
        case .notAZip, .unreadableManifest, .missingManifest, .notAHandover:
            return "That file isn't a job handover this app can read."
        case .unsupportedVersion:
            return "That handover was made by a newer version of the app. Update the app to open it."
        case .tooLarge, .tooManyPhotos:
            return "That handover is larger than this app opens."
        case .unsafeEntryPath, .unexpectedEntry, .missingPhoto:
            return "That handover holds something it shouldn't, so it wasn't opened."
        }
    }
}

// MARK: - A stored-entry zip writer

/// The smallest zip this app needs to write: stored (uncompressed) entries, no extra fields, no
/// ZIP64. What `ZipArchiveReader` reads back strictly.
enum StoredZipWriter {
    static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        var body = Data()
        var central = Data()
        var offsets: [Int] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            offsets.append(body.count)
            body.appendLE(UInt32(0x0403_4B50))
            body.appendLE(UInt16(20))                     // version needed
            body.appendLE(UInt16(0x0800))                 // flags: UTF-8 names
            body.appendLE(UInt16(0))                      // stored
            body.appendLE(UInt16(0)); body.appendLE(UInt16(0x21)) // time, date (1980-01-01)
            body.appendLE(crc)
            body.appendLE(UInt32(entry.data.count))
            body.appendLE(UInt32(entry.data.count))
            body.appendLE(UInt16(name.count)); body.appendLE(UInt16(0))
            body.append(name)
            body.append(entry.data)
        }
        for (index, entry) in entries.enumerated() {
            let name = Data(entry.name.utf8)
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0x21))
            central.appendLE(crc32(entry.data))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))   // extra, comment
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))   // disk, internal attrs
            central.appendLE(UInt32(0))                                // external attrs
            central.appendLE(UInt32(offsets[index]))
            central.append(name)
        }
        var out = body
        out.append(central)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(body.count))
        out.appendLE(UInt16(0))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}
