#!/usr/bin/env swift
// Plan BX P2 — vendor-side skill-pack signing (run on macOS: `swift Scripts/skillpack-sign.swift …`).
//
// The private key NEVER enters the repo (the Field Assist licensing rule). Mint it once with
// `keygen`, keep it wherever the Field Assist private key lives, and paste the printed PUBLIC key
// into `SkillPackSignature.productionPublicKeyBase64`.
//
//   keygen
//       Prints a new Curve25519 keypair (base64).
//   sign-pack <packDir> <privateKeyBase64>
//       Signs <packDir>/skillpack.json + every other file in the directory (sorted, recursive).
//       Prints the pack signature to embed in the catalog entry's `packSignature`.
//   sign-catalog <indexJSON> <privateKeyBase64>
//       Wraps an index JSON file in the signed envelope the app fetches; prints the envelope.
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

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: skillpack-sign.swift keygen | sign-pack <packDir> <privateKey> | sign-catalog <indexJSON> <privateKey>")
    exit(1)
}

switch arguments[1] {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private (keep OFF-repo): \(key.rawRepresentation.base64EncodedString())")
    print("public  (embed in app):  \(key.publicKey.rawRepresentation.base64EncodedString())")

case "sign-pack":
    guard arguments.count == 4 else { fail("sign-pack <packDir> <privateKeyBase64>") }
    let packDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
    guard let keyData = Data(base64Encoded: arguments[3]),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        fail("bad private key")
    }
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
