#!/usr/bin/env swift
// Plan BX P2 — vendor-side skill-pack signing (run on macOS: `swift Scripts/skillpack-sign.swift …`).
//
// The private key NEVER enters the repo (the Field Assist licensing rule) and is NEVER printed:
// `keygen` writes it straight to a file with mode 0600 and prints only the PUBLIC half, which goes
// into `SkillPackSignature.productionPublicKeyBase64`. Keep the file wherever the Field Assist
// private key lives (`secrets/` is gitignored). Never paste a private key into a terminal, a chat,
// or a log — a key that has been printed is a key that must be rotated.
//
//   keygen <privateKeyFile>
//       Mints a keypair, writes the private half to <privateKeyFile> (0600, refuses to overwrite),
//       and prints ONLY the public key and the path.
//   sign-pack <packDir> <privateKey>
//       Signs <packDir>/skillpack.json + every other file in the directory (sorted, recursive).
//       Prints the pack signature to embed in the catalog entry's `packSignature`.
//   sign-catalog <indexJSON> <privateKey>
//       Wraps an index JSON file in the signed envelope the app fetches; prints the envelope.
//
// <privateKey> is either a PATH to a key file written by `keygen` (preferred — the key stays off
// the command line and out of shell history) or the base64 key itself.
//
// Message construction MUST match SkillPackSignature.signingMessage / SkillPackCatalog.parse —
// manifest bytes, then "\nsha256(<path>)=<hex>" per payload file sorted by path; catalog envelope
// is {"payload": base64(indexBytes), "signature": base64} with the signature over the raw bytes.

import Foundation
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Key handling (never prints a private key)

/// Last non-comment, non-empty line of a key file — the format `keygen` writes.
func privateKeyLine(inFile path: String) -> String? {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return contents
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Resolve a `<privateKey>` argument: a path to a key file, or the base64 key itself.
func resolvePrivateKey(_ argument: String) -> Curve25519.Signing.PrivateKey {
    var base64 = argument
    if FileManager.default.fileExists(atPath: argument) {
        guard let line = privateKeyLine(inFile: argument) else {
            fail("no key line in \(argument) (expected base64 after the '#' comment header)")
        }
        base64 = line
    }
    guard let data = Data(base64Encoded: base64),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("bad private key (pass a key file path or the base64 key)")
    }
    return key
}

/// Mint a keypair, write the private half to `path` with mode 0600, and print ONLY the public key.
func writeKeygen(to path: String, purpose: String) {
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) already exists — refusing to overwrite an existing key. Move it aside first.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let contents = """
    # \(purpose)
    # Curve25519 signing PRIVATE key (base64, raw representation).
    # Generated \(ISO8601DateFormatter().string(from: Date())).
    # Vendor secret: never commit it, never paste it into a terminal, a chat, or a log.
    \(key.rawRepresentation.base64EncodedString())

    """
    guard FileManager.default.createFile(
        atPath: path,
        contents: Data(contents.utf8),
        attributes: [.posixPermissions: 0o600]) else {
        fail("could not write \(path)")
    }
    print("private key written (mode 0600): \(path)")
    print("public  (embed in app):  \(key.publicKey.rawRepresentation.base64EncodedString())")
}

// MARK: - Commands

let usage = """
usage: skillpack-sign.swift keygen <privateKeyFile>
                          | sign-pack <packDir> <privateKey>
                          | sign-catalog <indexJSON> <privateKey>

  <privateKey> is a PATH to a key file written by `keygen` (preferred — keeps the key out of
  shell history) or the base64 key itself. `keygen` never prints the private half.
"""

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print(usage)
    exit(1)
}

switch arguments[1] {
case "keygen":
    guard arguments.count == 3 else { fail("keygen <privateKeyFile>") }
    writeKeygen(to: arguments[2], purpose: "OpenGlasses skill-pack / vault-pack catalog signing key.")

case "sign-pack":
    guard arguments.count == 4 else { fail("sign-pack <packDir> <privateKey>") }
    let packDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let key = resolvePrivateKey(arguments[3])
    let manifestURL = packDir.appendingPathComponent("skillpack.json")
    guard let manifestData = try? Data(contentsOf: manifestURL) else {
        fail("no skillpack.json in \(packDir.path)")
    }

    var message = manifestData
    let enumerator = FileManager.default.enumerator(
        at: packDir, includingPropertiesForKeys: [.isRegularFileKey])!
    var payloadPaths: [String] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let relative = url.path.replacingOccurrences(of: packDir.path + "/", with: "")
        guard relative != "skillpack.json" else { continue }
        payloadPaths.append(relative)
    }
    for path in payloadPaths.sorted() {
        let data = (try? Data(contentsOf: packDir.appendingPathComponent(path))) ?? Data()
        message.append(Data("\nsha256(\(path))=\(sha256Hex(data))".utf8))
    }
    guard let signature = try? key.signature(for: message) else { fail("signing failed") }
    print(signature.base64EncodedString())

case "sign-catalog":
    guard arguments.count == 4 else { fail("sign-catalog <indexJSON> <privateKey>") }
    guard let indexData = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else {
        fail("can't read \(arguments[2])")
    }
    let key = resolvePrivateKey(arguments[3])
    guard let signature = try? key.signature(for: indexData) else { fail("signing failed") }
    let envelope: [String: String] = [
        "payload": indexData.base64EncodedString(),
        "signature": signature.base64EncodedString(),
    ]
    let out = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    print(String(data: out, encoding: .utf8)!)

default:
    fail("unknown command '\(arguments[1])'\n\(usage)")
}
