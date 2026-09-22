import CryptoKit
import Foundation
@testable import OpenGlasses

/// Real zip bytes for the vault-archive tests (Plan FS PR2).
///
/// Built here rather than checked in, so the reader is exercised against the actual format and a
/// fixture can be bent — one byte of one file changed, a path that escapes the root, a file the
/// header never declared — without a binary in the repository.
enum VaultArchiveFixture {

    /// A vault folder's files, the way an archive carries them.
    static func vaultFiles(vaultId: String = "acme_rtu",
                           manualText: String = "Fault QZ7731 is logged when the inducer stalls.",
                           manualTitle: String = "RTU-500 Service Manual") -> [String: Data] {
        let manifest = VaultManifest(
            id: vaultId, name: "Acme RTU Service", version: "1.0.0",
            files: ["fault-codes.md"], documentsDir: "documents",
            documents: [VaultDocument(file: "manual.txt", title: manualTitle, kind: "service_manual")],
            promptRules: ["Never fabricate a value.", "Cite the source file."])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return [
            "manifest.json": (try? encoder.encode(manifest)) ?? Data(),
            "fault-codes.md": Data("# Fault codes\n\nQZ7731 — inducer stalled.".utf8),
            "documents/manual.txt": Data(manualText.utf8),
        ]
    }

    /// The header those files produce, with the entry list and totals the app checks.
    static func header(for files: [String: Data], vaultId: String = "acme_rtu",
                       vaultName: String = "Acme RTU Service", vaultVersion: String = "1.0.0",
                       publisherId: String = "", publisherName: String = "",
                       manuals: [VaultArchiveHeader.Manual] = [.init(title: "RTU-500 Service Manual",
                                                                     hasOriginal: false)],
                       formatVersion: Int = VaultArchiveHeader.supportedFormatVersion)
    -> VaultArchiveHeader {
        let entries = files.keys.sorted().map {
            VaultArchiveHeader.Entry(path: $0,
                                     sha256: VaultArchiveReader.sha256Hex(files[$0] ?? Data()),
                                     bytes: files[$0]?.count ?? 0)
        }
        return VaultArchiveHeader(
            formatVersion: formatVersion, vaultId: vaultId, vaultName: vaultName,
            vaultVersion: vaultVersion, publisherId: publisherId, publisherName: publisherName,
            files: entries, totalBytes: entries.reduce(0) { $0 + $1.bytes },
            manualTextIncluded: true, originalDocumentsIncluded: false, manuals: manuals)
    }

    /// Zip the header, an optional detached signature, and the files.
    static func archive(header: VaultArchiveHeader, files: [String: Data],
                        signature: String? = nil,
                        extraEntries: [(name: String, data: Data)] = []) -> Data {
        var entries: [(name: String, data: Data)] = [
            (VaultArchiveHeader.filename, (try? header.canonicalData()) ?? Data()),
        ]
        if let signature {
            entries.append((VaultArchiveHeader.signatureFilename, Data(signature.utf8)))
        }
        for path in files.keys.sorted() { entries.append((path, files[path] ?? Data())) }
        entries.append(contentsOf: extraEntries)
        return zip(entries)
    }

    /// The whole thing, signed with a fresh publisher key. Returns the bytes and the publisher
    /// row that verifies them.
    static func signedArchive(publisherId: String = "acme", publisherName: String = "Acme Manuals",
                             files: [String: Data]? = nil,
                             status: VaultPublisher.Status = .active)
    -> (data: Data, publisher: VaultPublisher, files: [String: Data], header: VaultArchiveHeader) {
        let files = files ?? vaultFiles()
        let header = header(for: files, publisherId: publisherId, publisherName: publisherName)
        let key = Curve25519.Signing.PrivateKey()
        let signature = (try? VaultArchiveSignature.sign(
            header: header, files: files,
            privateKeyBase64: key.rawRepresentation.base64EncodedString())) ?? ""
        let publisher = VaultPublisher(id: publisherId, name: publisherName,
                                       publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                       status: status)
        return (archive(header: header, files: files, signature: signature), publisher, files, header)
    }

    // MARK: - A minimal stored-entry zip writer

    /// Uncompressed (method 0) entries — enough for the reader's whole read path.
    static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        var body = Data()
        var central = Data()
        var offsets: [Int] = []

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let checksum = crc32(entry.data)
            offsets.append(body.count)
            body.appendLE32(0x0403_4B50)
            body.appendLE16(20); body.appendLE16(0)
            body.appendLE16(0)
            body.appendLE16(0); body.appendLE16(0)
            body.appendLE32(checksum)
            body.appendLE32(UInt32(entry.data.count))
            body.appendLE32(UInt32(entry.data.count))
            body.appendLE16(UInt16(nameBytes.count)); body.appendLE16(0)
            body.append(nameBytes)
            body.append(entry.data)
        }
        for (index, entry) in entries.enumerated() {
            let nameBytes = Data(entry.name.utf8)
            central.appendLE32(0x0201_4B50)
            central.appendLE16(20); central.appendLE16(20)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0)
            central.appendLE32(crc32(entry.data))
            central.appendLE32(UInt32(entry.data.count))
            central.appendLE32(UInt32(entry.data.count))
            central.appendLE16(UInt16(nameBytes.count))
            central.appendLE16(0); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0)
            central.appendLE32(0)
            central.appendLE32(UInt32(offsets[index]))
            central.append(nameBytes)
        }
        var out = body
        out.append(central)
        out.appendLE32(0x0605_4B50)
        out.appendLE16(0); out.appendLE16(0)
        out.appendLE16(UInt16(entries.count)); out.appendLE16(UInt16(entries.count))
        out.appendLE32(UInt32(central.count))
        out.appendLE32(UInt32(body.count))
        out.appendLE16(0)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}
