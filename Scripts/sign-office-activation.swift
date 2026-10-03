#!/usr/bin/env swift
import Foundation
import CryptoKit

// Answer an Avenkin Office activation request by hand — the offline route of office first-use
// setup, and what the licence activation service will do once it exists.
//
//   ./Scripts/sign-office-activation.swift <request.json> <reply.json>
//       [--key-file <path|->]   the PROFILE signing key, passed through to make-org-profile.swift
//       [--key-id <id>]         the key id the profile is signed under, passed through likewise
//
// The office's administrator saves <request.json> in step 3 of setup ("Save request file…") and
// sends it to the vendor. This script checks it, signs the organisation profile it asks for with
// make-org-profile.swift, and writes <reply.json>, which the administrator loads with "Load your
// supplier's reply…". The reply holds the signed profile and the licence code; neither is secret.
//
// Checked before anything is signed:
//   - the file is an activation request this script reads (format, version, size);
//   - the licence code in it verifies under the vendor's licence key, is a Field Assist licence
//     and has not expired;
//   - the licence was issued for desktop activation (it names an organisation and a profile), and
//     the request names the same two identifiers. The identifiers are trusted from the licence,
//     never from the request.
// The settings themselves are checked by make-org-profile.swift, which refuses rather than
// signing something a phone would drop.
//
// NOT checked here: whether this licence has already activated a different office. The service
// will keep that ledger; by hand, the vendor is the ledger. The summary printed before signing
// shows the licensee, the organisation and the office's administrator key for that reason.
//
// The profile signing key is never read by this script: --key-file is handed to
// make-org-profile.swift, which reads it from a file or stdin and never from an argument.
//
//   --licence-public-key-file <path>   verify the licence under another key (base64, raw). For
//       rehearsals with a test licence only; a reply made this way names a licence no phone accepts.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage: sign-office-activation.swift <request.json> <reply.json> [--key-file <path|->] [--key-id <id>]
"""

/// The vendor's licence PUBLIC key (LicenseService.productionPublicKeyBase64).
let productionLicencePublicKey = "i8ppcyB20u6FfNRworl5GPX2Z/k4+xBuhzIgBE7Kj2Q="
let requestFormat = "avenkin.office-activation-request"
let requestVersion = 1
let maximumRequestBytes = 65_536
let licenceFeature = "field_assist"

// MARK: - Arguments

var positional: [String] = []
var passThrough: [String] = []
var licencePublicKeyFile: String?
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--key-file", "--key-id":
        guard let value = iterator.next() else { fail("error: \(argument) needs a value") }
        passThrough += [argument, value]
    case "--licence-public-key-file":
        guard let value = iterator.next() else { fail("error: \(argument) needs a path") }
        licencePublicKeyFile = value
    default:
        if argument.hasPrefix("--") { fail("error: unknown option \(argument)\n\(usage)") }
        positional.append(argument)
    }
}
guard positional.count == 2 else { fail(usage) }
let requestPath = positional[0]
let replyPath = positional[1]
guard !FileManager.default.fileExists(atPath: replyPath) else {
    fail("error: \(replyPath) already exists; choose another name rather than replacing a reply")
}

// MARK: - The request

guard let raw = FileManager.default.contents(atPath: requestPath) else { fail("error: cannot read \(requestPath)") }
guard raw.count <= maximumRequestBytes else { fail("error: not an activation request: too large") }
guard let request = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
      request["format"] as? String == requestFormat,
      request["version"] as? Int == requestVersion,
      let requestId = request["requestId"] as? String,
      let profileRequest = request["profileRequest"] as? [String: Any] else {
    fail("error: \(requestPath) is not an activation request this script reads")
}
guard let profileId = profileRequest["profileId"] as? String,
      let organizationName = profileRequest["organizationName"] as? String,
      let authority = profileRequest["officeAuthority"] as? [String: Any],
      let organizationID = authority["organizationID"] as? String,
      let administratorPublicKey = authority["administratorPublicKey"] as? String,
      let licenceCode = profileRequest["licenceCode"] as? String else {
    fail("error: the request does not name its profile, organisation, office key and licence")
}

// MARK: - The licence

let licenceKeyText: String
if let path = licencePublicKeyFile {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("error: cannot read \(path)") }
    licenceKeyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    FileHandle.standardError.write(Data("warning: verifying the licence under a key from \(path), not the vendor's. Rehearsal only.\n".utf8))
} else {
    licenceKeyText = productionLicencePublicKey
}
guard let licenceKeyData = Data(base64Encoded: licenceKeyText),
      let licenceKey = try? Curve25519.Signing.PublicKey(rawRepresentation: licenceKeyData) else {
    fail("error: the licence public key is not a Curve25519 public key")
}
let parts = licenceCode.split(separator: ".", omittingEmptySubsequences: false)
guard parts.count == 2,
      let payload = Data(base64Encoded: String(parts[0])),
      let signature = Data(base64Encoded: String(parts[1])),
      licenceKey.isValidSignature(signature, for: payload) else {
    fail("refused: the licence code in the request is not a licence this vendor issued")
}
guard let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
      claims["feature"] as? String == licenceFeature else {
    fail("refused: the licence is not a Field Assist licence")
}
if let expires = claims["expires"] as? String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: expires) else { fail("refused: the licence's expiry date cannot be read") }
    guard date > Date() else { fail("refused: the licence expired on \(expires)") }
}
guard let licensedOrganization = claims["organizationID"] as? String,
      let licensedProfile = claims["profileID"] as? String else {
    fail("""
    refused: this licence was not issued for desktop activation.
    Issue one with: generate-field-license.swift "<Licensee>" --organization-id <ID> --profile-id <ID>
    """)
}
guard licensedOrganization == organizationID, licensedProfile == profileId else {
    fail("refused: the request names organisation \(organizationID) and profile \(profileId), but the licence was issued for \(licensedOrganization) and \(licensedProfile)")
}

// MARK: - What is about to be signed

let settings = (profileRequest["settings"] as? [String: Any] ?? [:]).keys.sorted()
let lockdown = profileRequest["lockdown"] as? [String: Any]
let summary = """
Activation request \(requestId.prefix(16))…
  Licensee:               \(claims["licensee"] as? String ?? "(not named)")
  Licence expires:        \(claims["expires"] as? String ?? "never")
  Organisation:           \(organizationName)  [\(organizationID)]
  Profile:                \(profileId)
  Office administrator:   \(administratorPublicKey)
  Lease:                  \(profileRequest["leaseDays"] ?? "?") days
  Edition:                \(profileRequest["edition"] as? String ?? "none")
  Settings sections open: \((lockdown?["open"] as? [String])?.joined(separator: ", ") ?? "default")
  Settings sections locked: \((lockdown?["lock"] as? [String])?.joined(separator: ", ") ?? "default")
  Administrator card:     \(profileRequest["adminCard"] == nil ? "no" : "yes")
  Settings (\(settings.count)): \(settings.joined(separator: ", "))

"""
FileHandle.standardError.write(Data(summary.utf8))

// MARK: - Sign with make-org-profile.swift

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let mint = scriptDirectory.appendingPathComponent("make-org-profile.swift").path
guard FileManager.default.fileExists(atPath: mint) else { fail("error: make-org-profile.swift is not beside this script") }
let work = FileManager.default.temporaryDirectory.appendingPathComponent("office-activation-\(UUID().uuidString)")
do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
catch { fail("error: could not make a working folder: \(error.localizedDescription)") }
defer { try? FileManager.default.removeItem(at: work) }
let inputPath = work.appendingPathComponent("profile-request.json").path
let documentPath = work.appendingPathComponent("profile.txt").path
guard let input = try? JSONSerialization.data(withJSONObject: profileRequest, options: [.sortedKeys]),
      FileManager.default.createFile(atPath: inputPath, contents: input) else {
    fail("error: could not prepare the profile request")
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", mint, "make", inputPath, documentPath] + passThrough
// The mint prints the payload it signed; the summary above is what the vendor reads.
process.standardOutput = FileHandle.nullDevice
let mintErrors = Pipe()
process.standardError = mintErrors
do { try process.run() } catch { fail("error: could not run make-org-profile.swift: \(error.localizedDescription)") }
let mintMessages = mintErrors.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(mintMessages)
    try? FileManager.default.removeItem(at: work)
    fail("refused: make-org-profile.swift did not sign this request (see above). Nothing was written.")
}
guard let document = (try? String(contentsOfFile: documentPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty else {
    fail("error: make-org-profile.swift wrote no profile")
}

// MARK: - The reply

let reply: [String: Any] = ["version": 1, "profileDocument": document, "licenceCode": licenceCode]
guard let replyData = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]),
      FileManager.default.createFile(atPath: replyPath, contents: replyData) else {
    fail("error: could not write \(replyPath)")
}
print("reply written: \(replyPath) — send it to the office; its administrator loads it with \"Load your supplier's reply…\"")
