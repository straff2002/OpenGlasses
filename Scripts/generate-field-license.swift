#!/usr/bin/env swift
import Foundation
import CryptoKit

// Mints a signed Field Assist license code.
//
//   ./Scripts/generate-field-license.swift <privateKeyBase64> "<Licensee Name>" [expiresISO8601]
//
// The private key is the vendor secret and must NEVER be committed or shipped in the app. The app
// embeds only the matching public key (LicenseService.productionPublicKeyBase64). Generate a keypair
// once with `print-keypair` below and keep the private key in a password manager / CI secret.
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

let args = CommandLine.arguments
guard args.count >= 3, let keyData = Data(base64Encoded: args[1]) else {
    FileHandle.standardError.write(Data("usage: generate-field-license.swift <privateKeyBase64> \"<Licensee>\" [expiresISO8601]\n".utf8))
    exit(1)
}

let licensee = args[2]
var expires: Date?
if args.count >= 4 {
    let iso = ISO8601DateFormatter()
    guard let parsed = iso.date(from: args[3]) else {
        FileHandle.standardError.write(Data("Could not parse expiry '\(args[3])' (use ISO-8601, e.g. 2027-01-01T00:00:00Z)\n".utf8))
        exit(1)
    }
    expires = parsed
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let payload = LicensePayload(feature: "field_assist", licensee: licensee, issued: Date(), expires: expires)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = try encoder.encode(payload)
    let signature = try privateKey.signature(for: payloadData)

    let code = "\(payloadData.base64EncodedString()).\(signature.base64EncodedString())"
    print(code)
} catch {
    FileHandle.standardError.write(Data("Failed to sign: \(error)\n".utf8))
    exit(1)
}
