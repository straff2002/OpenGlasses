#!/usr/bin/env swift
import Foundation
import CryptoKit

// Mints a signed Field Assist license code.
//
//   ./Scripts/generate-field-license.swift "<Licensee Name>" [expiresISO8601]
//
// The signing PRIVATE key is the vendor secret and must NEVER be committed or shipped. The script
// resolves it, in order, from:
//   1. $FIELD_ASSIST_SIGNING_KEY (base64), else
//   2. secrets/field-assist-signing-key.txt (gitignored — see secrets/*.example).
// The app embeds only the matching PUBLIC key (LicenseService.productionPublicKeyBase64).
//
//   # one-off keypair generation:
//   swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey(); print("private:", k.rawRepresentation.base64EncodedString()); print("public:", k.publicKey.rawRepresentation.base64EncodedString())'
//
// Format (must match LicenseService): base64(payloadJSON) + "." + base64(Ed25519 signature),
// payload encoded with ISO-8601 dates and sorted keys.

struct LicensePayload: Codable {
    let feature: String
    let licensee: String
    let issued: Date
    let expires: Date?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// First non-comment, non-empty line of a key file.
func keyFromFile(_ url: URL) -> String? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return contents
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Resolve the private key from env, then the gitignored secrets file (looked up relative to the
/// script's location and the current directory).
func resolvePrivateKey() -> String {
    if let env = ProcessInfo.processInfo.environment["FIELD_ASSIST_SIGNING_KEY"], !env.isEmpty {
        return env
    }
    let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let candidates = [
        scriptDir.deletingLastPathComponent().appendingPathComponent("secrets/field-assist-signing-key.txt"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("secrets/field-assist-signing-key.txt"),
    ]
    for url in candidates {
        if let key = keyFromFile(url) { return key }
    }
    fail("""
    No signing key found. Provide it via $FIELD_ASSIST_SIGNING_KEY or create
    secrets/field-assist-signing-key.txt (copy secrets/field-assist-signing-key.txt.example).
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: generate-field-license.swift \"<Licensee>\" [expiresISO8601]")
}

let licensee = args[1]
var expires: Date?
if args.count >= 3 {
    guard let parsed = ISO8601DateFormatter().date(from: args[2]) else {
        fail("Could not parse expiry '\(args[2])' (use ISO-8601, e.g. 2027-01-01T00:00:00Z)")
    }
    expires = parsed
}

guard let keyData = Data(base64Encoded: resolvePrivateKey()) else {
    fail("Signing key is not valid base64.")
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let payload = LicensePayload(feature: "field_assist", licensee: licensee, issued: Date(), expires: expires)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = try encoder.encode(payload)
    let signature = try privateKey.signature(for: payloadData)

    print("\(payloadData.base64EncodedString()).\(signature.base64EncodedString())")
} catch {
    fail("Failed to sign: \(error)")
}
