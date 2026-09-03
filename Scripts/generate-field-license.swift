#!/usr/bin/env swift
import Foundation
import CryptoKit

// Mints a signed Field Assist license code.
//
//   ./Scripts/generate-field-license.swift "<Licensee Name>" [expiresISO8601]
//       [--tier team|enterprise] [--plan pilot|team|enterprise] [--seats N] [--reference PO-123] [--days 90]
//       [--pack hvac_rtu ...]   vault packs the licence includes, by licence key (Plan EG)
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
    var tier: String?
    var plan: String?
    var seats: Int?
    var reference: String?
    var packs: [String]?
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

let usage = """
usage: generate-field-license.swift "<Licensee>" [expiresISO8601]
         [--tier team|enterprise] [--plan pilot|team|enterprise]
         [--seats N] [--reference TEXT] [--days N] [--pack KEY ...]

  Positional expiry and --days are alternatives; --days counts from now.
  Prints the code on stdout and the decoded payload on stderr for a final look.
"""

var positional: [String] = []
var tier: String?
var plan: String?
var seats: Int?
var reference: String?
var days: Int?
var packs: [String] = []
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iterator.next() {
    func value(_ flag: String) -> String {
        guard let v = iterator.next() else { fail("\(flag) needs a value\n\(usage)") }
        return v
    }
    switch arg {
    case "--tier":
        let v = value(arg)
        guard ["team", "enterprise"].contains(v) else { fail("--tier must be team or enterprise (solo is a store product, never a code)") }
        tier = v
    case "--plan":
        let v = value(arg)
        guard ["pilot", "team", "enterprise"].contains(v) else { fail("--plan must be pilot, team, or enterprise") }
        plan = v
    case "--seats":
        guard let n = Int(value(arg)), n > 0 else { fail("--seats must be a positive integer") }
        seats = n
    case "--reference":
        reference = value(arg)
    case "--pack":
        packs.append(value(arg))
    case "--days":
        guard let n = Int(value(arg)), n > 0 else { fail("--days must be a positive integer") }
        days = n
    case "-h", "--help":
        print(usage); exit(0)
    default:
        if arg.hasPrefix("--") { fail("unknown flag \(arg)\n\(usage)") }
        positional.append(arg)
    }
}

guard let licensee = positional.first, !licensee.isEmpty else { fail(usage) }
var expires: Date?
if positional.count >= 2 {
    guard let parsed = ISO8601DateFormatter().date(from: positional[1]) else {
        fail("Could not parse expiry '\(positional[1])' (use ISO-8601, e.g. 2027-01-01T00:00:00Z)")
    }
    expires = parsed
}
if let days {
    guard expires == nil else { fail("give either a positional expiry or --days, not both") }
    expires = Date().addingTimeInterval(TimeInterval(days) * 86_400)
}
if plan == "pilot" && expires == nil { fail("a pilot code must expire — pass --days or an expiry") }
if plan == "enterprise" && tier == nil { tier = "enterprise" }

guard let keyData = Data(base64Encoded: resolvePrivateKey()) else {
    fail("Signing key is not valid base64.")
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let payload = LicensePayload(feature: "field_assist", licensee: licensee, issued: Date(), expires: expires,
                                 tier: tier, plan: plan, seats: seats, reference: reference,
                                 packs: packs.isEmpty ? nil : packs)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = try encoder.encode(payload)
    let signature = try privateKey.signature(for: payloadData)

    print("\(payloadData.base64EncodedString()).\(signature.base64EncodedString())")

    // Decoded payload on stderr so the vendor can eyeball what was signed before sending it.
    let pretty = JSONEncoder()
    pretty.dateEncodingStrategy = .iso8601
    pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let shown = String(data: try pretty.encode(payload), encoding: .utf8) {
        FileHandle.standardError.write(Data(("signed payload:\n" + shown + "\n").utf8))
    }
} catch {
    fail("Failed to sign: \(error)")
}
