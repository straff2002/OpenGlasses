#!/usr/bin/env swift
import Foundation
import CryptoKit

// Make an OpenGlasses job file (`.ogjob`, Plan FO §8) — for an office system, or a person, sending
// a technician their next job by email.
//
//   make <input.json> <output.ogjob> [--key-file <path|->]
//       Reads a job as JSON (the fields below, without `format`, `format_version` or
//       `signature`), checks it against the app's limits, and writes the job file. With
//       --key-file it is signed with the ORGANISATION's key; without, it is written unsigned and
//       the phone will say so.
//   keygen <privateKeyFile>
//       Mints an organisation key: the private half to a 0600 file, the public half printed —
//       that is what goes in the organisation's profile (Config.organizationJobSigningKey until
//       CT ships). Not the vendor's pack key; an office signs its own jobs.
//
// Input fields (all optional, at least one of job_reference / site / fault_report):
//   job_reference, site {customer, address, contact}, fault_report, equipment [{model, serial}],
//   scheduled_for (ISO 8601), notes, attachments [{name, reference}], issued_by
//
// The signature covers the canonical encoding of everything but `signature` — sorted keys,
// slashes unescaped — which is exactly what the app re-encodes to verify. This struct must stay
// field-for-field identical to `JobFile.Body` in the app.
//
// A private key is read from a FILE (or stdin with `--key-file -`) and never taken as an argument.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Site: Codable { let customer: String?; let address: String?; let contact: String? }
struct Equipment: Codable { let model: String?; let serial: String? }
struct Attachment: Codable { let name: String; let reference: String? }

struct Body: Codable {
    let format: String
    let formatVersion: Int
    let jobReference: String?
    let site: Site?
    let faultReport: String?
    let equipment: [Equipment]?
    let scheduledFor: String?
    let notes: String?
    let attachments: [Attachment]?
    let issuedBy: String?

    enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
        case jobReference = "job_reference"
        case site
        case faultReport = "fault_report"
        case equipment
        case scheduledFor = "scheduled_for"
        case notes, attachments
        case issuedBy = "issued_by"
    }
}

/// The job as the office writes it: the body without the two format fields.
struct Input: Codable {
    let jobReference: String?
    let site: Site?
    let faultReport: String?
    let equipment: [Equipment]?
    let scheduledFor: String?
    let notes: String?
    let attachments: [Attachment]?
    let issuedBy: String?

    enum CodingKeys: String, CodingKey {
        case jobReference = "job_reference"
        case site
        case faultReport = "fault_report"
        case equipment
        case scheduledFor = "scheduled_for"
        case notes, attachments
        case issuedBy = "issued_by"
    }
}

struct Signature: Codable { let algorithm: String; let value: String }

func canonical(_ body: Body) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(body) else { fail("error: could not encode the job") }
    return data
}

func readKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    let raw: Data
    if path == "-" {
        raw = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        guard let data = FileManager.default.contents(atPath: path) else { fail("error: cannot read key file") }
        raw = data
    }
    let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: text),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
        fail("error: the key file does not hold a Curve25519 private key")
    }
    return key
}

/// The limits the phone enforces, checked here so an office finds out before the technician does.
func check(_ input: Input) {
    func limit(_ value: String?, _ name: String, _ max: Int) {
        guard let value else { return }
        if value.count > max { fail("error: \(name) is longer than \(max) characters") }
        if value.range(of: "<[A-Za-z/!?]", options: .regularExpression) != nil
            || value.range(of: "&[A-Za-z0-9#]+;", options: .regularExpression) != nil {
            fail("error: \(name) contains markup; job files are plain text")
        }
    }
    limit(input.jobReference, "job_reference", 64)
    limit(input.site?.customer, "customer", 120)
    limit(input.site?.address, "address", 240)
    limit(input.site?.contact, "contact", 160)
    limit(input.faultReport, "fault_report", 1_000)
    limit(input.notes, "notes", 1_000)
    limit(input.issuedBy, "issued_by", 120)
    for unit in input.equipment ?? [] {
        limit(unit.model, "model", 64)
        limit(unit.serial, "serial", 64)
    }
    for attachment in input.attachments ?? [] {
        limit(attachment.name, "attachment name", 120)
        limit(attachment.reference, "attachment reference", 240)
        if attachment.reference?.lowercased().hasPrefix("data:") == true {
            fail("error: attachments are named, never embedded")
        }
    }
    if (input.equipment?.count ?? 0) > 10 { fail("error: more than 10 machines") }
    if (input.attachments?.count ?? 0) > 10 { fail("error: more than 10 attachments") }
    if let scheduled = input.scheduledFor, ISO8601DateFormatter().date(from: scheduled) == nil {
        fail("error: scheduled_for is not ISO 8601 (e.g. 2026-09-25T09:00:00Z)")
    }
    if input.jobReference == nil && input.site == nil && input.faultReport == nil {
        fail("error: a job needs at least a job_reference, a site or a fault_report")
    }
}

/// Refuse a private key handed in on the command line, whatever its position — the rule every
/// signing tool here follows (W06.4, see vaultpack-sign.swift). An argument is rejected only if it
/// is not an existing path and decodes from base64 to exactly 32 bytes; nothing about it is echoed.
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
          logs and captured in crash reports. Treat that key as compromised: mint a new one with
          `keygen` and put the new public half in the organisation's profile.

          Pass a file instead: --key-file <path>, or --key-file - to read it from stdin.
        """)
    }
}

let arguments = CommandLine.arguments
refuseInlineKey(arguments)
guard arguments.count >= 2 else {
    fail("usage: make-job-file.swift make <input.json> <output.ogjob> [--key-file <path|->]\n"
         + "       make-job-file.swift keygen <privateKeyFile>")
}

switch arguments[1] {
case "keygen":
    guard arguments.count == 3 else { fail("usage: make-job-file.swift keygen <privateKeyFile>") }
    let path = arguments[2]
    guard !FileManager.default.fileExists(atPath: path) else { fail("error: \(path) already exists") }
    let key = Curve25519.Signing.PrivateKey()
    let created = FileManager.default.createFile(
        atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600])
    guard created else { fail("error: could not write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "make":
    guard arguments.count == 4 || arguments.count == 6 else {
        fail("usage: make-job-file.swift make <input.json> <output.ogjob> [--key-file <path|->]")
    }
    guard let raw = FileManager.default.contents(atPath: arguments[2]),
          let input = try? JSONDecoder().decode(Input.self, from: raw) else {
        fail("error: cannot read the job JSON")
    }
    check(input)
    let body = Body(format: "openglasses.job", formatVersion: 1, jobReference: input.jobReference,
                    site: input.site, faultReport: input.faultReport, equipment: input.equipment,
                    scheduledFor: input.scheduledFor, notes: input.notes,
                    attachments: input.attachments, issuedBy: input.issuedBy)
    var document = (try? JSONSerialization.jsonObject(with: canonical(body))) as? [String: Any] ?? [:]
    if arguments.count == 6 {
        guard arguments[4] == "--key-file" else { fail("error: expected --key-file") }
        let key = readKey(arguments[5])
        guard let signature = try? key.signature(for: canonical(body)) else { fail("error: signing failed") }
        document["signature"] = ["algorithm": "ed25519", "value": signature.base64EncodedString()]
    }
    guard let out = try? JSONSerialization.data(withJSONObject: document,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        fail("error: could not write the job file")
    }
    guard out.count <= 64 * 1024 else { fail("error: the job file is over 64 KB") }
    guard FileManager.default.createFile(atPath: arguments[3], contents: out) else {
        fail("error: could not write \(arguments[3])")
    }
    print(arguments.count == 6 ? "signed job file written" : "UNSIGNED job file written — the phone will say so")

default:
    fail("unknown command \(arguments[1])")
}
