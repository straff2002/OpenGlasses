#if DEBUG
import CryptoKit
import Foundation

/// A real vault archive, built in-process, for the UI-test run only (Plan FS PR2).
///
/// **This whole file is behind `#if DEBUG`, so a Release binary contains none of it.** It exists so
/// that the review sheet can be photographed in its signed and unverified states without a network,
/// a publisher or a bypass: the bytes it produces go through exactly the pipeline a real archive
/// does — the zip reader, the header, the per-file checksums, the signature and the publisher
/// lookup — because the only thing the test replaces is the transport.
///
/// It signs with a key minted at launch, so nothing here is or resembles a production key.
enum UITestVaultFixture {

    static let vaultId = "acme_rtu_demo"
    static let vaultName = "Acme RTU Service"
    static let publisherId = "acme.demo"
    static let publisherName = "Acme Manuals"
    static let host = "manuals.example.com"

    /// The vault folder's files, as an archive carries them.
    static func files() -> [String: Data] {
        let manifest = VaultManifest(
            id: vaultId, name: vaultName, version: "1.2.0",
            files: ["fault-codes.md"], documentsDir: "documents",
            documents: [VaultDocument(file: "rtu-500-service.txt", title: "RTU-500 Service Manual"),
                        VaultDocument(file: "rtu-750-install.txt", title: "RTU-750 Installation Guide")],
            promptRules: ["Never fabricate a value.", "Cite the source file and page."])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return [
            "manifest.json": (try? encoder.encode(manifest)) ?? Data(),
            "fault-codes.md": Data("# Fault codes\n\n## Acme RTU-500\n\nZX9 — low charge.".utf8),
            "documents/rtu-500-service.txt": Data(String(repeating: "Page 1\nService text.\n", count: 400).utf8),
            "documents/rtu-750-install.txt": Data(String(repeating: "Page 1\nInstall text.\n", count: 260).utf8),
        ]
    }

    /// The archive plus the publisher row that verifies it. `signed: false` leaves the signature
    /// out, which is what puts the review sheet into its unverified-source state.
    static func archive(signed: Bool) -> (data: Data, publishers: [VaultPublisher]) {
        let files = files()
        let entries = files.keys.sorted().map {
            VaultArchiveHeader.Entry(path: $0,
                                     sha256: VaultArchiveReader.sha256Hex(files[$0] ?? Data()),
                                     bytes: files[$0]?.count ?? 0)
        }
        let header = VaultArchiveHeader(
            vaultId: vaultId, vaultName: vaultName, vaultVersion: "1.2.0",
            publisherId: signed ? publisherId : "", publisherName: signed ? publisherName : "",
            files: entries, totalBytes: entries.reduce(0) { $0 + $1.bytes },
            manualTextIncluded: true, originalDocumentsIncluded: false,
            manuals: [.init(title: "RTU-500 Service Manual", hasOriginal: false),
                      .init(title: "RTU-750 Installation Guide", hasOriginal: false)])

        var members: [(String, Data)] = [
            (VaultArchiveHeader.filename, (try? header.canonicalData()) ?? Data()),
        ]
        var publishers: [VaultPublisher] = []
        if signed {
            let key = Curve25519.Signing.PrivateKey()
            let signature = (try? VaultArchiveSignature.sign(
                header: header, files: files,
                privateKeyBase64: key.rawRepresentation.base64EncodedString())) ?? ""
            members.append((VaultArchiveHeader.signatureFilename, Data(signature.utf8)))
            publishers = [VaultPublisher(id: publisherId, name: publisherName,
                                         publicKey: key.publicKey.rawRepresentation.base64EncodedString())]
        }
        for path in files.keys.sorted() { members.append((path, files[path] ?? Data())) }
        return (zip(members), publishers)
    }

    /// A receipt for a vault installed from a link, so the Custom Vaults row can be photographed
    /// with its badge.
    static func receipt(signed: Bool) -> VaultReceipt {
        VaultReceipt(publisherId: signed ? publisherId : nil,
                     publisherName: signed ? publisherName : nil,
                     verification: signed ? .signed : .unverified,
                     sourceHost: host, receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     archiveSHA256: "0000")
    }

    // MARK: - A minimal stored-entry zip writer

    private static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        var body = Data()
        var central = Data()
        var offsets: [Int] = []
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            offsets.append(body.count)
            body.appendLittleEndian(UInt32(0x0403_4B50))
            body.appendLittleEndian(UInt16(20)); body.appendLittleEndian(UInt16(0))
            body.appendLittleEndian(UInt16(0))
            body.appendLittleEndian(UInt16(0)); body.appendLittleEndian(UInt16(0))
            body.appendLittleEndian(crc32(entry.data))
            body.appendLittleEndian(UInt32(entry.data.count))
            body.appendLittleEndian(UInt32(entry.data.count))
            body.appendLittleEndian(UInt16(nameBytes.count)); body.appendLittleEndian(UInt16(0))
            body.append(nameBytes)
            body.append(entry.data)
        }
        for (index, entry) in entries.enumerated() {
            let nameBytes = Data(entry.name.utf8)
            central.appendLittleEndian(UInt32(0x0201_4B50))
            central.appendLittleEndian(UInt16(20)); central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0)); central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(crc32(entry.data))
            central.appendLittleEndian(UInt32(entry.data.count))
            central.appendLittleEndian(UInt32(entry.data.count))
            central.appendLittleEndian(UInt16(nameBytes.count))
            central.appendLittleEndian(UInt16(0)); central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0)); central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(0))
            central.appendLittleEndian(UInt32(offsets[index]))
            central.append(nameBytes)
        }
        var out = body
        out.append(central)
        out.appendLittleEndian(UInt32(0x0605_4B50))
        out.appendLittleEndian(UInt16(0)); out.appendLittleEndian(UInt16(0))
        out.appendLittleEndian(UInt16(entries.count)); out.appendLittleEndian(UInt16(entries.count))
        out.appendLittleEndian(UInt32(central.count))
        out.appendLittleEndian(UInt32(body.count))
        out.appendLittleEndian(UInt16(0))
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
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

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}
#endif
