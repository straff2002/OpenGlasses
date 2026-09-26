#!/usr/bin/env swift
import Foundation
import CryptoKit
import CommonCrypto
import CoreImage

// Mint an OpenGlasses organisation profile (Plan CT) — the document hosted at the URL an
// organisation's QR code or enrolment link points at — or a revocation of one.
//
//   make <input.json> <output.txt> [--key-file <path|->] [--key-id <id>]
//       Reads the profile as JSON (fields below), checks it against the app's allow-list and the
//       direction each setting may move, and writes the signed document. Refuses rather than
//       letting the phone drop an entry: an organisation should find out here, not at enrolment.
//   revoke <profileId> <output.txt> [--key-file <path|->] [--key-id <id>]
//       A whole-link revocation: host it at the profile's URL in place of the profile and every
//       phone enrolled from that link erases the organisation's content when it next checks in.
//       To revoke ONE phone on a shared link, add its enrolment id to `revokedEnrolmentIds` in
//       the input and re-`make` the profile instead.
//   keygen <privateKeyFile>
//       One-off: the private half to a 0600 file, the public half printed — it goes in
//       ProfileVerification.productionKeys under a new key id. Never the licence key.
//   admin-card <card.png>
//       Plan CT 3b, once per organisation: a new admin card. The secret goes into the QR in the PNG
//       and nowhere else; the digest printed goes into every profile for that organisation as
//       `adminCard`. A lost or photographed card is a new card and re-minted profiles.
//   make … --admin-passcode
//       Plan CT 3b: prompt (echo off, twice) for the organisation's administrator passcode and
//       carry a PBKDF2 verifier of it — never the passcode — with a fresh salt. At least eight
//       characters and not all digits. Never taken as an argument.
//
// Input fields:
//   profileId, organizationName, leaseDays (7–365)                                    required
//   policyExpiry (ISO 8601), eraseAfterLapseDays, undeliveredEraseDays (1–365),
//   licenceCode, vaultPack {packId, documentsSource}, skillPacks [..],
//   revokedEnrolmentIds [..], settings {<SettingKey>: {value, disposition}},
//   aiModel {provider, model, baseURL, name}  (the provider and model only — never a key),
//   edition ("fieldAssist"), adminCard (the digest `admin-card` printed)                    optional
//
// The signature covers "openglasses.org-profile.v1\n" (or "…org-revocation.v1\n") followed by the
// payload bytes, which are shipped as-is — so the encoding here only has to be valid, not
// canonical. The structs, the allow-list and the directions below must stay identical to
// ConfigProfile, ProfileRevocation and SettingKey in the app (OpenGlasses/Sources/Services/OrgProfile).
//
// The private key is read from a FILE (or stdin with `--key-file -`), else from
// secrets/org-profile-signing-key.txt (gitignored), and never taken as an argument.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Mirrors of the app's types

enum ProfileValue: Codable, Equatable {
    case bool(Bool)
    case string(String)
    case strings([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) { self = .bool(flag) }
        else if let text = try? container.decode(String.self) { self = .string(text) }
        else if let list = try? container.decode([String].self) { self = .strings(list) }
        else { throw DecodingError.typeMismatch(ProfileValue.self, .init(codingPath: decoder.codingPath, debugDescription: "not a flag, string or string list")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .string(let text): try container.encode(text)
        case .strings(let list): try container.encode(list)
        }
    }
}

struct RawSetting: Codable { let value: ProfileValue; let disposition: String }
struct VaultPackReference: Codable { let packId: String; let documentsSource: String? }
struct AIModel: Codable { let provider: String; let model: String; let baseURL: String?; let name: String? }
struct PasscodeVerifier: Codable { let salt: String; let iterations: Int; let hash: String }

/// Mirrors AdminSecrets in the app (OpenGlasses/Sources/Services/OrgProfile/AdminSecrets.swift).
enum AdminSecrets {
    static let iterations = 210_000
    static let cardPrefix = "og-admin:"
    static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func pbkdf2(_ passcode: String, salt: Data, iterations: Int) -> Data {
        let password = Data(passcode.utf8)
        var derived = Data(count: 32)
        let status: Int32 = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { fail("error: PBKDF2 failed") }
        return derived
    }

    static func verifier(for passcode: String) -> PasscodeVerifier {
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let hash = pbkdf2(passcode, salt: salt, iterations: iterations)
        return PasscodeVerifier(salt: salt.base64EncodedString(), iterations: iterations,
                                hash: hash.base64EncodedString())
    }

    /// 26 Crockford characters: 130 random bits.
    static func newCardSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<26).map { _ in crockford[Int.random(in: 0..<32, using: &generator)] })
    }

    static func cardDigest(secret: String) -> String {
        SHA256.hash(data: Data(("openglasses.admin-card.v1\n" + secret).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Read a passcode from the terminal with echo off, twice, and hold it to the app's floor.
func promptPasscode() -> String {
    guard let first = getpass("Administrator passcode: ").map({ String(cString: $0) }),
          let second = getpass("Again: ").map({ String(cString: $0) }) else {
        fail("error: could not read the passcode from the terminal")
    }
    guard first == second else { fail("error: the two entries differ") }
    guard first.count >= 8 else { fail("error: the passcode must be at least eight characters") }
    guard !first.allSatisfy({ $0.isNumber }) else { fail("error: the passcode must not be all digits") }
    return first
}

/// LLMProvider's raw values in the app (OpenGlasses/Sources/Services/LLMService.swift).
let knownProviders: Set<String> = ["anthropic", "openai", "chatgpt", "gemini", "geminiVertex", "groq", "deepseek",
                                   "mistral", "zai", "qwen", "minimax", "xai", "openrouter", "custom", "local",
                                   "appleOnDevice"]

struct Input: Codable {
    let profileId: String
    let organizationName: String
    let leaseDays: Int
    let policyExpiry: String?
    let eraseAfterLapseDays: Int?
    let undeliveredEraseDays: Int?
    let licenceCode: String?
    let vaultPack: VaultPackReference?
    let skillPacks: [String]?
    let revokedEnrolmentIds: [String]?
    let settings: [String: RawSetting]?
    let aiModel: AIModel?
    let edition: String?
    let adminCard: String?
}

struct ConfigProfile: Codable {
    let format: String
    let schemaVersion: Int
    let keyId: String
    let profileId: String
    let organizationName: String
    let issued: Date
    let policyExpiry: Date?
    let leaseDays: Int
    let eraseAfterLapseDays: Int?
    let undeliveredEraseDays: Int?
    let licenceCode: String?
    let vaultPack: VaultPackReference?
    let skillPacks: [String]?
    let revokedEnrolmentIds: [String]?
    let aiModel: AIModel?
    let edition: String?
    let adminPasscode: PasscodeVerifier?
    let adminCard: String?
    let settings: [String: RawSetting]
}

struct ProfileRevocation: Codable {
    let format: String
    let keyId: String
    let profileId: String
    let issued: Date
}

/// SettingKey, by kind. "owned" ignores the disposition; "ceiling:<Bool>" may only be pinned that
/// way; "default:<type>" is a starting value.
let allowList: [String: String] = [
    "organizationDisplayName": "owned:string",
    "organizationJobSigningKey": "owned:string",
    "organizationJobReportChannel": "owned:string",
    "organizationReportRecipients": "owned:strings",
    "organizationAllowsUnsignedVaults": "ceiling:false",
    "organizationRequiresSignedJobFiles": "ceiling:true",
    "organizationRequiresCustomerSignOff": "ceiling:true",
    "privacyFilterEnabled": "ceiling:true",
    "remoteInvokeObserveEnabled": "ceiling:false",
    "remoteInvokeOutputEnabled": "ceiling:false",
    "remoteInvokeCaptureEnabled": "ceiling:false",
    "mcpServerEnabled": "ceiling:false",
    "agentModeEnabled": "ceiling:false",
    "fieldAssistEnabled": "default:bool",
    "fieldAssistDefaultVaultId": "default:string",
    "fieldAssistDefaultMode": "default:string",
    "supportReportEmail": "default:string",
]

func typeName(_ value: ProfileValue) -> String {
    switch value {
    case .bool: return "bool"
    case .string: return "string"
    case .strings: return "strings"
    }
}

func check(_ input: Input) {
    if !(7...365).contains(input.leaseDays) { fail("error: leaseDays must be 7–365 (got \(input.leaseDays))") }
    for (field, days) in [("eraseAfterLapseDays", input.eraseAfterLapseDays), ("undeliveredEraseDays", input.undeliveredEraseDays)] {
        if let days, !(1...365).contains(days) { fail("error: \(field) must be 1–365 (got \(days))") }
    }
    if input.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fail("error: organizationName is empty")
    }
    if let expiry = input.policyExpiry {
        guard let date = ISO8601DateFormatter().date(from: expiry) else {
            fail("error: policyExpiry is not ISO 8601 (e.g. 2027-09-30T00:00:00Z)")
        }
        if date < Date() { fail("error: policyExpiry is in the past") }
    }
    if let edition = input.edition, edition != "fieldAssist" {
        fail("error: edition \(edition) is not one this app knows (fieldAssist)")
    }
    if let card = input.adminCard {
        guard card.count == 64, card.allSatisfy({ $0.isHexDigit }) else {
            fail("error: adminCard must be the 64-character digest `admin-card` printed")
        }
    }
    if input.edition == nil && (input.adminCard != nil || adminPasscodeRequested) {
        fail("error: an admin card or passcode only applies with an edition")
    }
    if let model = input.aiModel {
        guard knownProviders.contains(model.provider) else {
            fail("error: aiModel.provider \(model.provider) is not one of \(knownProviders.sorted().joined(separator: ", "))")
        }
        if model.model.trimmingCharacters(in: .whitespaces).isEmpty { fail("error: aiModel.model is empty") }
        if let base = model.baseURL {
            guard ["custom", "openrouter"].contains(model.provider) else {
                fail("error: aiModel.baseURL is only for custom and openrouter")
            }
            guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                fail("error: aiModel.baseURL must be https with no credentials or fragment")
            }
        } else if model.provider == "custom" {
            fail("error: a custom aiModel needs its baseURL")
        }
    }
    for (key, setting) in input.settings ?? [:] {
        guard let kind = allowList[key] else {
            fail("error: \(key) is not a setting a profile may set (see SettingKey)")
        }
        let parts = kind.split(separator: ":").map(String.init)
        switch parts[0] {
        case "owned":
            if typeName(setting.value) != parts[1] { fail("error: \(key) takes a \(parts[1])") }
        case "ceiling":
            guard setting.disposition == "ceiling" else { fail("error: \(key) may only be a ceiling") }
            guard case .bool(let flag) = setting.value else { fail("error: \(key) takes a bool") }
            if String(flag) != parts[1] { fail("error: \(key) may only be pinned to \(parts[1])") }
        default:
            guard setting.disposition == "default" else { fail("error: \(key) may only be a default") }
            if typeName(setting.value) != parts[1] { fail("error: \(key) takes a \(parts[1])") }
        }
    }
    if case .string(let key)? = input.settings?["organizationJobSigningKey"]?.value {
        guard let data = Data(base64Encoded: key),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil else {
            fail("error: organizationJobSigningKey is not a Curve25519 public key (use make-job-file.swift keygen)")
        }
    }
}

// MARK: - Keys

/// Refuse a private key handed in on the command line, whatever its position (W06.4). An argument
/// is rejected only if it is not an existing path and decodes from base64 to exactly 32 bytes;
/// nothing about it is echoed.
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
          `keygen`, add its public half under a new key id, and re-issue every profile.

          Pass a file instead: --key-file <path>, or --key-file - to read it from stdin.
        """)
    }
}

func readKey(_ path: String?) -> Curve25519.Signing.PrivateKey {
    let text: String
    if path == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = path.map { [$0] } ?? [
            scriptDir.deletingLastPathComponent().appendingPathComponent("secrets/org-profile-signing-key.txt").path,
            FileManager.default.currentDirectoryPath + "/secrets/org-profile-signing-key.txt",
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let contents = try? String(contentsOfFile: found, encoding: .utf8) else {
            fail("error: no signing key. Pass --key-file <path>, or put it at secrets/org-profile-signing-key.txt")
        }
        if let mode = (try? FileManager.default.attributesOfItem(atPath: found)[.posixPermissions]) as? NSNumber,
           mode.intValue & 0o077 != 0 {
            FileHandle.standardError.write(Data("warning: \(found) is readable beyond its owner. Run: chmod 600 \(found)\n".utf8))
        }
        text = contents
    }
    // First non-comment, non-empty line: the key files `keygen` writes carry a comment header.
    guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
          let data = Data(base64Encoded: line),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("error: the key file does not hold a Curve25519 private key")
    }
    return key
}

func sign(_ payload: Data, domain: String, key: Curve25519.Signing.PrivateKey) -> String {
    guard let signature = try? key.signature(for: Data(domain.utf8) + payload) else { fail("error: signing failed") }
    return "\(payload.base64EncodedString()).\(signature.base64EncodedString())"
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// Whole seconds, so what is signed reads back as exactly what was shown.
func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

// MARK: - Main

let arguments = CommandLine.arguments
refuseInlineKey(arguments)

var positional: [String] = []
var keyFile: String?
var keyId = "og-profile-2026-09"
var adminPasscodeRequested = false
var iterator = arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--admin-passcode":
        adminPasscodeRequested = true
    case "--key-file":
        guard let path = iterator.next() else { fail("error: --key-file needs a path") }
        keyFile = path
    case "--key-id":
        guard let id = iterator.next() else { fail("error: --key-id needs a value") }
        keyId = id
    default: positional.append(argument)
    }
}

let usage = """
usage: make-org-profile.swift make <input.json> <output.txt> [--key-file <path|->] [--key-id <id>] [--admin-passcode]
       make-org-profile.swift admin-card <card.png>
       make-org-profile.swift revoke <profileId> <output.txt> [--key-file <path|->] [--key-id <id>]
       make-org-profile.swift keygen <privateKeyFile>
"""

switch positional.first ?? "" {
case "keygen":
    guard positional.count == 2 else { fail(usage) }
    let path = positional[1]
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) already exists — refusing to overwrite an existing key. Move it aside first.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let contents = """
    # OpenGlasses organisation-profile signing key (Plan CT). Not the licence key.
    # Curve25519 signing PRIVATE key (base64, raw representation).
    # Generated \(ISO8601DateFormatter().string(from: Date())).
    # Vendor secret: never commit it, never paste it into a terminal, a chat, or a log.
    \(key.rawRepresentation.base64EncodedString())

    """
    guard FileManager.default.createFile(atPath: path, contents: Data(contents.utf8),
                                         attributes: [.posixPermissions: 0o600]) else {
        fail("could not write \(path)")
    }
    print("private key written (mode 0600): \(path)")
    print("public  (embed in app under a new key id):  \(key.publicKey.rawRepresentation.base64EncodedString())")

case "admin-card":
    guard positional.count == 2 else { fail(usage) }
    let path = positional[1]
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) already exists — refusing to overwrite another card")
    }
    let secret = AdminSecrets.newCardSecret()
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { fail("error: no QR generator") }
    filter.setValue(Data((AdminSecrets.cardPrefix + secret).utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let qr = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        fail("error: could not render the card")
    }
    do {
        try CIContext().writePNGRepresentation(of: qr, to: URL(fileURLWithPath: path),
                                               format: .RGBA8, colorSpace: colorSpace)
    } catch {
        fail("error: could not write \(path): \(error)")
    }
    print("admin card written: \(path)")
    print("adminCard (put this in every profile for the organisation): \(AdminSecrets.cardDigest(secret: secret))")
    FileHandle.standardError.write(Data("""
    The card's secret is in the PNG and nowhere else. Print it or send it to the administrator,
    then delete the file. A lost or photographed card is a new card and re-minted profiles.

    """.utf8))

case "make":
    guard positional.count == 3 else { fail(usage) }
    guard let raw = FileManager.default.contents(atPath: positional[1]) else { fail("error: cannot read \(positional[1])") }
    let input: Input
    do { input = try JSONDecoder().decode(Input.self, from: raw) } catch { fail("error: the input is not a profile: \(error)") }
    check(input)
    let key = readKey(keyFile)
    let profile = ConfigProfile(
        format: "openglasses.org-profile", schemaVersion: 1, keyId: keyId,
        profileId: input.profileId, organizationName: input.organizationName, issued: now(),
        policyExpiry: input.policyExpiry.flatMap { ISO8601DateFormatter().date(from: $0) },
        leaseDays: input.leaseDays, eraseAfterLapseDays: input.eraseAfterLapseDays,
        undeliveredEraseDays: input.undeliveredEraseDays, licenceCode: input.licenceCode,
        vaultPack: input.vaultPack, skillPacks: input.skillPacks,
        revokedEnrolmentIds: input.revokedEnrolmentIds, aiModel: input.aiModel,
        edition: input.edition,
        adminPasscode: adminPasscodeRequested ? AdminSecrets.verifier(for: promptPasscode()) : nil,
        adminCard: input.adminCard?.lowercased(),
        settings: input.settings ?? [:])
    guard let payload = try? encoder.encode(profile) else { fail("error: could not encode the profile") }
    let document = sign(payload, domain: "openglasses.org-profile.v1\n", key: key)
    guard FileManager.default.createFile(atPath: positional[2], contents: Data((document + "\n").utf8)) else {
        fail("error: could not write \(positional[2])")
    }
    FileHandle.standardError.write(payload + Data("\n".utf8))
    print("profile written: \(positional[2]) — host it at the URL the QR code or link points to")

case "revoke":
    guard positional.count == 3 else { fail(usage) }
    let key = readKey(keyFile)
    let revocation = ProfileRevocation(format: "openglasses.org-revocation", keyId: keyId,
                                       profileId: positional[1], issued: now())
    guard let payload = try? encoder.encode(revocation) else { fail("error: could not encode the revocation") }
    let document = sign(payload, domain: "openglasses.org-revocation.v1\n", key: key)
    guard FileManager.default.createFile(atPath: positional[2], contents: Data((document + "\n").utf8)) else {
        fail("error: could not write \(positional[2])")
    }
    print("revocation written: \(positional[2]) — host it at the profile's URL in place of the profile")

default:
    fail(usage)
}
