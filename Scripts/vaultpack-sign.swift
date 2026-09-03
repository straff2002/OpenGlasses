#!/usr/bin/env swift
import Foundation
import CryptoKit

// Vault pack signing (Plan EG). Same key and message shape as skillpack-sign.swift, with
// pack.json in the manifest position and every other file (manifest.json included) hashed.
//
//   sign-pack <vaultDir> <privateKey>       → prints the pack signature (base64)
//   sign-catalog <indexJSON> <privateKey>   → prints the signed catalog envelope
//
// <privateKey> is either a PATH to a key file (preferred — the key stays off the command line and
// out of shell history) or the base64 key itself. Mint the key with
// `swift Scripts/skillpack-sign.swift keygen <privateKeyFile>`, which writes the private half to a
// 0600 file and prints only the public half. A private key is never printed; a key that has been
// printed is a key that must be rotated.
//
// The private key lives off-repo with the Field Assist licensing key and the skill-pack key.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Last non-comment, non-empty line of a key file — the format `skillpack-sign.swift keygen` writes.
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

let usage = """
usage: vaultpack-sign.swift sign-pack <vaultDir> <privateKey>
                          | sign-catalog <indexJSON> <privateKey>

  <privateKey> is a PATH to a key file (preferred) or the base64 key itself.
"""

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail(usage) }

switch arguments[1] {
case "sign-pack":
    guard arguments.count == 4 else { fail("sign-pack <vaultDir> <privateKey>") }
    let packDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let key = resolvePrivateKey(arguments[3])
    guard let packData = try? Data(contentsOf: packDir.appendingPathComponent("pack.json")) else {
        fail("no pack.json in \(packDir.path)")
    }
    guard FileManager.default.fileExists(atPath: packDir.appendingPathComponent("manifest.json").path) else {
        fail("no manifest.json in \(packDir.path)")
    }
    if FileManager.default.fileExists(atPath: packDir.appendingPathComponent("documents").path) {
        fail("a pack must not ship a documents/ folder — customers load their own manuals")
    }
    var message = packData
    let enumerator = FileManager.default.enumerator(at: packDir, includingPropertiesForKeys: [.isRegularFileKey])!
    var payloadPaths: [String] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let relative = url.path.replacingOccurrences(of: packDir.path + "/", with: "")
        guard relative != "pack.json", !relative.hasPrefix(".") else { continue }
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
