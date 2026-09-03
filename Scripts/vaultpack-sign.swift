#!/usr/bin/env swift
import Foundation
import CryptoKit

// Vault pack signing (Plan EG). Same key and message shape as skillpack-sign.swift, with
// pack.json in the manifest position and every other file (manifest.json included) hashed.
//
//   sign-pack <vaultDir> <privateKeyBase64>       → prints the pack signature (base64)
//   sign-catalog <indexJSON> <privateKeyBase64>   → prints the signed catalog envelope
//
// The private key lives off-repo with the Field Assist licensing key and the skill-pack key.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: vaultpack-sign.swift sign-pack <vaultDir> <privateKey> | sign-catalog <indexJSON> <privateKey>")
}

switch arguments[1] {
case "sign-pack":
    guard arguments.count == 4 else { fail("sign-pack <vaultDir> <privateKeyBase64>") }
    let packDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
    guard let keyData = Data(base64Encoded: arguments[3]),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        fail("bad private key")
    }
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
    guard arguments.count == 4 else { fail("sign-catalog <indexJSON> <privateKeyBase64>") }
    guard let indexData = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else {
        fail("can't read \(arguments[2])")
    }
    guard let keyData = Data(base64Encoded: arguments[3]),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData),
          let signature = try? key.signature(for: indexData) else {
        fail("bad private key or signing failed")
    }
    let envelope: [String: String] = [
        "payload": indexData.base64EncodedString(),
        "signature": signature.base64EncodedString(),
    ]
    let out = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    print(String(data: out, encoding: .utf8)!)

default:
    fail("unknown command '\(arguments[1])'")
}
