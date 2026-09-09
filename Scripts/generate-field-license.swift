#!/usr/bin/env swift
import Foundation
import CryptoKit

// Mints a signed Field Assist license code.
//
//   ./Scripts/generate-field-license.swift "<Licensee Name>" [expiresISO8601]
//       [--key-file <path|->]   where to read the signing key from (see below)
//       [--tier team|enterprise] [--plan pilot|team|enterprise] [--seats N] [--reference PO-123] [--days 90]
//       [--pack hvac_rtu ...]   vault packs the licence includes, by licence key (Plan EG)
//
//   ./Scripts/generate-field-license.swift keygen <privateKeyFile>
//       One-off keypair generation. Writes the PRIVATE key to <privateKeyFile> with mode 0600
//       (refusing to overwrite an existing file) and prints ONLY the public key and the path.
//
// The signing PRIVATE key is the vendor secret and must NEVER be committed or shipped, and is
// NEVER printed: it is written to a file at generation and read back from there. Never paste a
// private key into a terminal, a chat, or a log — a key that has been printed must be rotated.
// The script resolves it, in order, from:
//   1. --key-file <path>, or --key-file - to read it from stdin, else
//   2. $FIELD_ASSIST_SIGNING_KEY (base64), else
//   3. secrets/field-assist-signing-key.txt (gitignored — see secrets/*.example).
// A key given as a command-line ARGUMENT is refused outright, whatever flag it is behind:
// arguments are visible in `ps`, recorded in shell history, echoed by CI logs and captured in
// crash reports. --key-file names a path; it never carries key material. The environment
// variable is kept for the unattended case and is the weaker of the two — prefer a file.
// The app embeds only the matching PUBLIC key (LicenseService.productionPublicKeyBase64).
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

/// Refuse a private key handed in on the command line, whatever the flag or position.
///
/// A process's arguments are not private: `ps` shows them to anyone on the machine, the shell
/// writes them to its history file, CI logs echo them, and a crash report captures them. A key
/// that has taken any of those routes is compromised and must be rotated — so the tool refuses
/// the shape rather than trusting whoever is at the keyboard to remember.
///
/// Precise, not a guess: an argument is rejected only if it is not an existing path AND decodes
/// from base64 to exactly 32 bytes, which is a Curve25519 raw key and very little else. Nothing
/// about the value is echoed — not a prefix, not a length.
func refuseInlineKey(_ arguments: [String]) {
    let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    for argument in arguments.dropFirst() {
        guard argument.count >= 40,
              !FileManager.default.fileExists(atPath: argument),
              argument.allSatisfy({ base64Alphabet.contains($0) }),
              let decoded = Data(base64Encoded: argument),
              decoded.count == 32 else { continue }
        fail("""
        error: a private key was passed on the command line. Refusing to use it.

          Command-line arguments are visible in `ps`, recorded in shell history, printed by CI
          logs and captured in crash reports. Treat that key as compromised: mint a new one, and
          re-issue anything the old one signed.

          Pass a file instead — the key never becomes an argument:

            --key-file secrets/field-assist-signing-key.txt
            --key-file -            # read the key from stdin
        """)
    }
}

/// Read a key file (or stdin when the path is `-`) and return its key line.
///
/// Never includes key material in an error, and warns if the file is readable beyond its owner —
/// a key the rest of the machine can read has already leaked to anyone with an account on it.
func keyFromKeyFile(_ path: String) -> String {
    let contents: String
    if path == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { fail("stdin was not UTF-8 text") }
        contents = text
    } else {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("can't read key file \(path)")
        }
        if let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber,
           mode.intValue & 0o077 != 0 {
            let notice = "warning: \(path) is readable beyond its owner "
                + "(mode \(String(mode.intValue, radix: 8))). Run: chmod 600 \(path)\n"
            FileHandle.standardError.write(Data(notice.utf8))
        }
        contents = text
    }
    guard let line = contents
        .split(separator: "\n")
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
        fail("no key line in \(path == "-" ? "stdin" : path)")
    }
    return line
}

/// Resolve the private key from --key-file, then env, then the gitignored secrets file (looked up
/// relative to the script's location and the current directory).
func resolvePrivateKey(keyFile: String?) -> String {
    if let keyFile { return keyFromKeyFile(keyFile) }
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
    No signing key found. In order of preference:
      --key-file <path>                 a key file, or `-` to read it from stdin
      $FIELD_ASSIST_SIGNING_KEY         base64, for the unattended case
      secrets/field-assist-signing-key.txt   (copy secrets/field-assist-signing-key.txt.example)
    Mint one with: ./Scripts/generate-field-license.swift keygen secrets/field-assist-signing-key.txt
    """)
}

/// Mint a keypair, write the private half to `path` with mode 0600, and print ONLY the public key.
func writeKeygen(to path: String) -> Never {
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) already exists — refusing to overwrite an existing key. Move it aside first.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let contents = """
    # OpenGlasses Field Assist licence signing key.
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
    exit(0)
}

refuseInlineKey(CommandLine.arguments)

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "keygen" {
    guard CommandLine.arguments.count == 3 else { fail("usage: generate-field-license.swift keygen <privateKeyFile>") }
    writeKeygen(to: CommandLine.arguments[2])
}

let usage = """
usage: generate-field-license.swift "<Licensee>" [expiresISO8601]
         [--key-file <path|->]
         [--tier team|enterprise] [--plan pilot|team|enterprise]
         [--seats N] [--reference TEXT] [--days N] [--pack KEY ...]
       generate-field-license.swift keygen <privateKeyFile>

  --key-file names a PATH (or `-` for stdin). A key passed as an argument is refused:
  arguments reach `ps`, shell history, CI logs and crash reports.
  Positional expiry and --days are alternatives; --days counts from now.
  Prints the code on stdout and the decoded payload on stderr for a final look.
  keygen writes the private key to a 0600 file and prints only the public half.
"""

var positional: [String] = []
var tier: String?
var plan: String?
var seats: Int?
var reference: String?
var days: Int?
var packs: [String] = []
var keyFile: String?
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
    case "--key-file":
        keyFile = value(arg)
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

guard let keyData = Data(base64Encoded: resolvePrivateKey(keyFile: keyFile)) else {
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
