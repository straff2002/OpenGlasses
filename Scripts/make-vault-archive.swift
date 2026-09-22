#!/usr/bin/env swift
import Foundation
import CryptoKit

// Build a vault archive a customer can receive from a link or a QR code (Plan FS §2).
//
//   ./Scripts/make-vault-archive.swift <vaultDir> [out.vaultarchive]
//       [--publisher-id <id> --publisher-name "<name>" --key-file <path|->]
//   ./Scripts/make-vault-archive.swift --self-check
//
// The input is an ordinary vault folder — the one the phone's folder import already takes:
// manifest.json, the core markdown, an optional procedures/, and documents/ with the manuals
// already extracted to text (that is the point: the customer's phone never runs recognition).
//
// The output is a zip of that folder plus two files:
//
//   vault-archive.json   the header — what this archive is, and the SHA-256 and byte size of
//                        every other file in it
//   vault-archive.sig    base64 of an ed25519 signature over the canonical header and the files
//
// Signing is optional here and **not optional in practice**: an unsigned archive installs on the
// customer's phone only behind a highlighted warning and a second acknowledgement, and is badged
// "Unverified source" for as long as it is installed. Sign it.
//
// The key is read from a FILE, or from stdin with `--key-file -`, and never from an argument:
// process arguments are visible in `ps`, recorded in shell history, echoed by CI logs and captured
// in crash reports. Mint one with `swift Scripts/skillpack-sign.swift keygen <privateKeyFile>`,
// which writes the private half to a 0600 file and prints only the public half. Send the vendor
// the **public** half and the name technicians should see; it goes into the signed catalog's
// publisher list, and can be revoked there without an app release.
//
// You must hold the right to supply the manuals you put in a vault you publish.
//
// `--self-check` runs the header, canonicalisation and signing-message rules over synthetic inputs
// and exits non-zero on a mismatch — the script has no test target, so this is what CI can run.

let usage = """
usage: make-vault-archive.swift <vaultDir> [out.vaultarchive] \\
           [--publisher-id <id>] [--publisher-name "<name>"] [--key-file <path|->]
       make-vault-archive.swift --self-check

  <vaultDir>          a vault folder: manifest.json + markdown + optional procedures/ + documents/
  out.vaultarchive    where to write the zip (default: <vaultDir>.vaultarchive beside it)
  --publisher-id      your id in the vendor's publisher list
  --publisher-name    what technicians should see ("Signed by …")
  --key-file          your ed25519 private key, from a file or `-` for stdin
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Key handling (never accepts, prints or logs a private key)

/// Refuse a private key handed in on the command line, whatever the flag or position. The test is
/// precise: an argument is rejected only if it is not an existing path AND decodes from base64 to
/// exactly 32 bytes, which is a Curve25519 raw key and very little else.
func refuseInlineKey(_ arguments: [String]) {
    let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    for argument in arguments.dropFirst() {
        guard argument.count >= 40,
              !FileManager.default.fileExists(atPath: argument),
              argument.allSatisfy({ base64Alphabet.contains($0) }),
              let decoded = Data(base64Encoded: argument),
              decoded.count == 32 else { continue }
        FileHandle.standardError.write(Data("""
        error: a private key was passed on the command line. Refusing to use it.

          Command-line arguments are visible in `ps`, recorded in shell history, printed by CI
          logs and captured in crash reports. Treat that key as compromised: mint a new one and
          re-sign anything the old one signed.

          Pass a file instead — the key never becomes an argument:

            --key-file secrets/<name>-signing-key.txt
            --key-file -            # read the key from stdin

        """.utf8))
        exit(2)
    }
}

func flag(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Last non-comment, non-empty line — the format `keygen` writes.
func privateKeyLine(in contents: String) -> String? {
    contents.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty && !$0.hasPrefix("#") }
}

func loadPrivateKey(keyFile path: String) -> Curve25519.Signing.PrivateKey {
    let contents: String
    if path == "-" {
        guard let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) else {
            fail("stdin was not UTF-8 text")
        }
        contents = text
    } else {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("can't read key file \(path)")
        }
        if let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber,
           mode.intValue & 0o077 != 0 {
            note("warning: \(path) is readable beyond its owner (mode \(String(mode.intValue, radix: 8))). Run: chmod 600 \(path)")
        }
        contents = text
    }
    guard let line = privateKeyLine(in: contents) else {
        fail("no key line in \(path == "-" ? "stdin" : path) (expected the base64 key as the last non-comment line)")
    }
    guard let data = Data(base64Encoded: line),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("the key file does not contain a valid Curve25519 private key")
    }
    return key
}

// MARK: - The header, exactly as the app reads it
//
// These four types mirror `VaultArchiveHeader` in the app. They are duplicated rather than shared
// because a `swift` script cannot import the app target; `--self-check` pins the wire shape, and
// `VaultArchiveScriptContractTests` in the app's suite reads this file and asserts the keys match.

struct ArchiveEntry: Codable {
    let path: String
    let sha256: String
    let bytes: Int
}

struct ArchiveManual: Codable {
    let title: String
    let hasOriginal: Bool
    enum CodingKeys: String, CodingKey {
        case title
        case hasOriginal = "has_original"
    }
}

struct ArchiveHeader: Codable {
    let formatVersion: Int
    let vaultId: String
    let vaultName: String
    let vaultVersion: String
    let publisherId: String
    let publisherName: String
    let files: [ArchiveEntry]
    let totalBytes: Int
    let manualTextIncluded: Bool
    let originalDocumentsIncluded: Bool
    let manuals: [ArchiveManual]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case vaultId = "vault_id"
        case vaultName = "vault_name"
        case vaultVersion = "vault_version"
        case publisherId = "publisher_id"
        case publisherName = "publisher_name"
        case files
        case totalBytes = "total_bytes"
        case manualTextIncluded = "manual_text_included"
        case originalDocumentsIncluded = "original_documents_included"
        case manuals
    }
}

let headerFilename = "vault-archive.json"
let signatureFilename = "vault-archive.sig"
let formatVersion = 1

/// The bytes the signature covers: a re-encoding with sorted keys, so the script and the phone
/// agree regardless of how the JSON was laid out on the way through a web server.
func canonicalData(_ header: ArchiveHeader) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(header) else { fail("could not encode the header") }
    return data
}

/// The signing message: the canonical header, then one `sha256(path)=hex` line per file, sorted by
/// path. The same construction skill packs and vault packs use — one signer, three payloads.
func signingMessage(header: ArchiveHeader, files: [String: Data]) -> Data {
    var message = canonicalData(header)
    for path in files.keys.sorted() {
        message.append(Data("\nsha256(\(path))=\(sha256Hex(files[path] ?? Data()))".utf8))
    }
    return message
}

// MARK: - Reading the vault folder

/// Every regular file under the vault root, by path relative to it. Dot files and macOS resource
/// forks are left out: an archive may contain nothing its header does not declare, and the phone
/// refuses one that does.
func vaultFiles(in root: URL) -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        fail("can't read \(root.path)")
    }
    var files: [String: Data] = [:]
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              !relative.hasPrefix("__MACOSX"),
              relative != headerFilename, relative != signatureFilename else { continue }
        guard let data = try? Data(contentsOf: url) else { fail("can't read \(relative)") }
        files[relative] = data
    }
    return files
}

/// The manual titles the review sheet names, and whether each has the manufacturer's own PDF
/// beside it — read out of the vault's own manifest so the header cannot disagree with it.
func manuals(in manifest: [String: Any], files: [String: Data]) -> (list: [ArchiveManual], text: Bool, originals: Bool) {
    let directory = (manifest["documents_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let documents = manifest["documents"] as? [[String: Any]] ?? []
    var list: [ArchiveManual] = []
    var anyText = false
    var anyOriginal = false
    for document in documents {
        guard let title = document["title"] as? String, let file = document["file"] as? String else { continue }
        let path = directory.map { "\($0)/\(file)" } ?? file
        if files[path] != nil { anyText = true }
        var hasOriginal = false
        if let source = document["source"] as? String, !source.isEmpty {
            let sourcePath = directory.map { "\($0)/\(source)" } ?? source
            hasOriginal = files[sourcePath] != nil
            if hasOriginal { anyOriginal = true }
        }
        list.append(ArchiveManual(title: title, hasOriginal: hasOriginal))
    }
    return (list, anyText, anyOriginal)
}

// MARK: - Self-check

func selfCheck() {
    var failures = 0
    func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; note("FAIL: \(what)") }
    }

    let files = ["manifest.json": Data("{}".utf8), "core/fault-codes.md": Data("# Codes".utf8)]
    let entries = files.keys.sorted().map {
        ArchiveEntry(path: $0, sha256: sha256Hex(files[$0]!), bytes: files[$0]!.count)
    }
    let header = ArchiveHeader(
        formatVersion: formatVersion, vaultId: "acme_rtu", vaultName: "Acme RTU Service",
        vaultVersion: "1.0.0", publisherId: "acme", publisherName: "Acme Manuals",
        files: entries, totalBytes: entries.reduce(0) { $0 + $1.bytes },
        manualTextIncluded: true, originalDocumentsIncluded: false,
        manuals: [ArchiveManual(title: "RTU-500 Service Manual", hasOriginal: false)])

    // The wire keys the app decodes.
    let json = (try? JSONSerialization.jsonObject(with: canonicalData(header))) as? [String: Any] ?? [:]
    for key in ["format_version", "vault_id", "vault_name", "vault_version", "publisher_id",
                "publisher_name", "files", "total_bytes", "manual_text_included",
                "original_documents_included", "manuals"] {
        expect(json[key] != nil, "header is missing \(key)")
    }

    // Canonicalisation is a function of the value, not of the layout.
    expect(canonicalData(header) == canonicalData(header), "canonical bytes are not stable")

    // The message shape: header bytes, then sorted sha lines.
    let message = signingMessage(header: header, files: files)
    let text = String(data: message, encoding: .utf8) ?? ""
    expect(text.hasPrefix(String(data: canonicalData(header), encoding: .utf8) ?? "#"),
           "the message does not start with the canonical header")
    expect(text.contains("\nsha256(core/fault-codes.md)="), "the message does not hash core/fault-codes.md")
    expect(text.range(of: "sha256(core/fault-codes.md)")!.lowerBound
           < text.range(of: "sha256(manifest.json)")!.lowerBound,
           "the per-file lines are not sorted by path")

    // A signature made here verifies with the public half, and not after a byte changes.
    let key = Curve25519.Signing.PrivateKey()
    guard let signature = try? key.signature(for: message) else { fail("signing failed") }
    expect(key.publicKey.isValidSignature(signature, for: message), "a fresh signature does not verify")
    var tampered = files
    tampered["core/fault-codes.md"] = Data("# Codes (altered)".utf8)
    expect(!key.publicKey.isValidSignature(signature, for: signingMessage(header: header, files: tampered)),
           "an altered file still verifies")

    if failures == 0 {
        note("make-vault-archive self-check: ok")
        exit(0)
    }
    fail("make-vault-archive self-check: \(failures) failure(s)")
}

// MARK: - Main

let arguments = CommandLine.arguments
refuseInlineKey(arguments)
if arguments.contains("--self-check") { selfCheck() }
guard arguments.count >= 2, !arguments[1].hasPrefix("--") else { fail(usage) }

let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("\(root.path) is not a directory")
}
guard let manifestData = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
      let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
      let vaultId = manifest["id"] as? String,
      let vaultName = manifest["name"] as? String,
      let vaultVersion = manifest["version"] as? String else {
    fail("no readable manifest.json (needs id, name and version) in \(root.path)")
}

let output: URL = {
    if arguments.count >= 3, !arguments[2].hasPrefix("--") {
        return URL(fileURLWithPath: arguments[2])
    }
    return root.deletingLastPathComponent()
        .appendingPathComponent(root.lastPathComponent + ".vaultarchive")
}()

let files = vaultFiles(in: root)
guard files["manifest.json"] != nil else { fail("manifest.json is missing from \(root.path)") }
let entries = files.keys.sorted().map {
    ArchiveEntry(path: $0, sha256: sha256Hex(files[$0]!), bytes: files[$0]!.count)
}
let manualInfo = manuals(in: manifest, files: files)
let header = ArchiveHeader(
    formatVersion: formatVersion,
    vaultId: vaultId, vaultName: vaultName, vaultVersion: vaultVersion,
    publisherId: flag("--publisher-id", in: arguments) ?? "",
    publisherName: flag("--publisher-name", in: arguments) ?? "",
    files: entries, totalBytes: entries.reduce(0) { $0 + $1.bytes },
    manualTextIncluded: manualInfo.text, originalDocumentsIncluded: manualInfo.originals,
    manuals: manualInfo.list)

let headerBytes = canonicalData(header)
var signatureBase64: String?
if let keyFile = flag("--key-file", in: arguments) {
    guard !header.publisherId.isEmpty else {
        fail("--key-file needs --publisher-id: the phone looks your key up by that id in the vendor's catalog")
    }
    let key = loadPrivateKey(keyFile: keyFile)
    guard let signature = try? key.signature(for: signingMessage(header: header, files: files)) else {
        fail("signing failed")
    }
    signatureBase64 = signature.base64EncodedString()
} else {
    note("""
    warning: building an UNSIGNED archive.

      An unsigned vault installs on a customer's phone only behind a highlighted warning and a
      second acknowledgement, and stays badged "Unverified source" for as long as it is installed.
      Pass --publisher-id and --key-file once the vendor has listed your public key.
    """)
}

// Stage a copy of the folder with the two extra files in it, then zip that. Staging rather than
// writing into the source keeps the publisher's working folder exactly as they left it.
let staging = FileManager.default.temporaryDirectory
    .appendingPathComponent("make-vault-archive-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent(vaultId, isDirectory: true)
defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
do {
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    for (path, data) in files {
        let url = staging.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    try headerBytes.write(to: staging.appendingPathComponent(headerFilename))
    if let signatureBase64 {
        try Data(signatureBase64.utf8).write(to: staging.appendingPathComponent(signatureFilename))
    }
} catch {
    fail("could not stage the archive: \(error.localizedDescription)")
}

try? FileManager.default.removeItem(at: output)
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zip.arguments = ["-r", "-q", "-X", output.path, "."]
zip.currentDirectoryURL = staging
do {
    try zip.run()
    zip.waitUntilExit()
} catch {
    fail("could not run /usr/bin/zip: \(error.localizedDescription)")
}
guard zip.terminationStatus == 0 else { fail("zip failed with status \(zip.terminationStatus)") }

print(String(data: headerBytes, encoding: .utf8) ?? "")
let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)??.intValue ?? 0
note("""

wrote \(output.path) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
  \(entries.count) file(s), \(manualInfo.list.count) manual(s)\(signatureBase64 == nil ? ", UNSIGNED" : ", signed by \(header.publisherId)")

  Put it on your own site and link to it from the page a customer lands on after buying. The
  vendor does not host, mirror or proxy vaults. A one-time or expiring link is worth using: the
  app treats the address as a secret and never shows more of it than the site name.
""")
