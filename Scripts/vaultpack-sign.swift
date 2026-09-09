#!/usr/bin/env swift
import Foundation
import CryptoKit

// Vault pack signing (Plan EG). Same key and message shape as skillpack-sign.swift, with
// pack.json in the manifest position and every other file (manifest.json included) hashed.
//
//   sign-pack <vaultDir> --key-file <path|->      → prints the pack signature (base64)
//   sign-catalog <indexJSON> --key-file <path|->  → prints the signed catalog envelope
//
// The key is read from a FILE, or from stdin with `--key-file -`, and is never taken as an
// argument: process arguments are visible in `ps`, recorded in shell history, echoed by CI logs
// and captured in crash reports. Mint the key with
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

// MARK: - Key handling (never accepts, prints or logs a private key)

/// Refuse a private key handed in on the command line, whatever the flag or position.
///
/// A process's arguments are not private. They are in `ps` output for anyone on the machine, in
/// the shell's history file, in CI logs whenever a step echoes its command, and in a crash
/// report. A key that has taken any of those routes is compromised and must be rotated — so the
/// tool refuses the shape rather than trusting the operator to remember.
///
/// The test is precise, not a guess: an argument is rejected only if it is not an existing path
/// AND decodes from base64 to exactly 32 bytes, which is a Curve25519 raw key and very little
/// else. A key file's path decodes to nothing.
///
/// Nothing about the offending value is echoed — not a prefix, not a length. The whole point is
/// to avoid writing it anywhere.
func refuseInlineKey(_ arguments: [String]) {
    let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    for argument in arguments.dropFirst() {
        guard argument.count >= 40,
              !FileManager.default.fileExists(atPath: argument),
              argument.allSatisfy({ base64Alphabet.contains($0) }),
              let decoded = Data(base64Encoded: argument),
              decoded.count == 32 else { continue }
        FileHandle.standardError.write(Data("""
        error: a private key was passed on the command line. Refusing to use it.

          Command-line arguments are visible in `ps`, recorded in shell history, printed by CI
          logs and captured in crash reports. Treat that key as compromised: mint a new one and
          re-sign anything the old one signed.

          Pass a file instead — the key never becomes an argument:

            --key-file secrets/<name>-signing-key.txt
            --key-file -            # read the key from stdin

        """.utf8))
        exit(2)
    }
}

/// The `--key-file` argument. `-` means stdin.
func keyFilePath(_ arguments: [String], usage: String) -> String {
    guard let index = arguments.firstIndex(of: "--key-file"), index + 1 < arguments.count else {
        fail("missing --key-file <path|->\n\(usage)")
    }
    return arguments[index + 1]
}

/// Last non-comment, non-empty line — the format `keygen` writes.
func privateKeyLine(in contents: String) -> String? {
    contents
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Load the signing key from a file path, or from stdin when the path is `-`.
///
/// Never returns the key as a string to a caller that might print it, and never includes key
/// material in any error it raises.
func loadPrivateKey(keyFile path: String) -> Curve25519.Signing.PrivateKey {
    let contents: String
    if path == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            fail("stdin was not UTF-8 text")
        }
        contents = text
    } else {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("can't read key file \(path)")
        }
        // A key readable by the rest of the machine is a key that has already leaked to anyone
        // with an account on it. Warned, not refused: a mode this tool did not set is the
        // operator's to fix, and failing here would strand someone mid-release.
        if let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber,
           mode.intValue & 0o077 != 0 {
            let notice = "warning: \(path) is readable beyond its owner "
                + "(mode \(String(mode.intValue, radix: 8))). Run: chmod 600 \(path)\n"
            FileHandle.standardError.write(Data(notice.utf8))
        }
        contents = text
    }
    guard let line = privateKeyLine(in: contents) else {
        fail("no key line in \(path == "-" ? "stdin" : path) "
             + "(expected the base64 key as the last non-comment line)")
    }
    guard let data = Data(base64Encoded: line),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        // Deliberately says nothing about what was read.
        fail("the key file does not contain a valid Curve25519 private key")
    }
    return key
}

let usage = """
usage: vaultpack-sign.swift sign-pack <vaultDir> --key-file <path|->
                          | sign-catalog <indexJSON> --key-file <path|->

  The signing key is read from a file, or from stdin with `--key-file -`. A key passed as an
  argument is refused: arguments reach `ps`, shell history, CI logs and crash reports.
"""

let arguments = CommandLine.arguments
refuseInlineKey(arguments)
guard arguments.count >= 2 else { fail(usage) }

switch arguments[1] {
case "sign-pack":
    guard arguments.count >= 3 else { fail("sign-pack <vaultDir> --key-file <path|->") }
    let packDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let key = loadPrivateKey(keyFile: keyFilePath(arguments, usage: usage))
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
    guard arguments.count >= 3 else { fail("sign-catalog <indexJSON> --key-file <path|->") }
    guard let indexData = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else {
        fail("can't read \(arguments[2])")
    }
    let key = loadPrivateKey(keyFile: keyFilePath(arguments, usage: usage))
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
