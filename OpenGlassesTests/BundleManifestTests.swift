import CryptoKit
import XCTest
@testable import OpenGlasses

/// The recorded-job bundle's manifest (Contracts/recorded-session.md §3) against the golden
/// manifest the reference implementation signed: the phone writes the same bytes, and reads
/// nothing but that one spelling.
final class BundleManifestTests: XCTestCase {
    private typealias F = RecordedJobFixtures

    private let videoPart = Data("Avenkin public fixture recording video part v1: eighty-two bytes of nothing at all".utf8)
    private let audioPart = Data("Avenkin public fixture audio v1".utf8)
    private let chunkBytes: Int64 = 32
    private let now: Int64 = 1_800_000_000

    /// The fixture phone key: seed = SHA-256 of a public label. It has no authority.
    private func phoneKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(SHA256.hash(data: Data("Avenkin public fixture phone key v1".utf8))))
    }

    private var binding: BundleManifest.Binding {
        .init(organizationID: "fixture-organisation", enrolmentID: "fixture-enrolment",
              officeID: "office-6c20b57a74ba2a4be634f3dd", generation: 1,
              phoneTransportID: "A44GCYW-HLGLMZV-EG2RHLW-YRQ773E-7GZUZMH-26RQHUT-MGGFBAI-JF7G6AW")
    }

    private func parts() throws -> [BundleManifest.PlannedPart] {
        [.init(partID: "video-1", track: .video, container: "mp4",
               plan: try XCTUnwrap(ChunkPlan.plan(videoPart, chunkBytes: chunkBytes))),
         .init(partID: "audio-1", track: .audio, container: "m4a",
               plan: try XCTUnwrap(ChunkPlan.plan(audioPart, chunkBytes: chunkBytes)))]
    }

    private func manifest(jobNumber: String? = "JOB-1042", blurred: Bool = false, droppedFrames: Int64 = 0,
                          consentAt: Int64? = nil, chunkBytes: Int64? = nil,
                          parts: [BundleManifest.PlannedPart]? = nil) throws -> BundleManifest? {
        BundleManifest(
            bundleID: String(BundleManifest.digest(Data("Avenkin public fixture recording bundle v1".utf8)).prefix(32)),
            binding: binding, jobSessionID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", jobNumber: jobNumber,
            createdAt: now, blurred: blurred, droppedFrames: droppedFrames, consentAt: consentAt ?? now - 3_600,
            chunkBytes: chunkBytes ?? self.chunkBytes,
            timeline: try F.data("recorded-session-timeline-v1"),
            transcript: try F.data("recorded-session-transcript-v1"),
            parts: try parts ?? self.parts())
    }

    private func golden() throws -> (envelope: Data, payload: Data, signature: Data) {
        let envelope = try F.data("recording-bundle-manifest-v1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope) as? [String: String])
        return (envelope, try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["payload"]))),
                try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["signature"]))))
    }

    // MARK: - The golden manifest

    func testThePhoneWritesTheGoldenManifestByteForByte() throws {
        let golden = try golden()
        let manifest = try XCTUnwrap(try manifest())
        XCTAssertEqual(manifest.payload(), golden.payload)
        XCTAssertEqual(manifest.files.map(\.role), ["timeline", "transcript", "media", "media", "media", "media"])
        XCTAssertEqual(manifest.parts.map(\.chunks.count), [3, 1])

        // The signature is the phone's, over the domain and those exact bytes, and the envelope
        // is the one published.
        XCTAssertTrue(try phoneKey().publicKey.isValidSignature(
            golden.signature, for: BundleManifest.signingDomain + golden.payload))
        XCTAssertFalse(try phoneKey().publicKey.isValidSignature(golden.signature, for: golden.payload))
        XCTAssertEqual(BundleManifest.sealed(payload: golden.payload, signature: golden.signature), golden.envelope)
        XCTAssertNil(BundleManifest.sealed(payload: golden.payload, signature: Data(repeating: 0, count: 63)))
        XCTAssertNil(BundleManifest.sealed(payload: golden.payload + Data(" ".utf8), signature: golden.signature))

        // What the office's receipt names is the digest of those bytes.
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: F.data("recording-receipt-received-v1")) as? [String: String])
        let stated = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(Data(base64Encoded: XCTUnwrap(receipt["payload"])))) as? [String: Any])
        XCTAssertEqual(stated["manifestSHA256"] as? String, manifest.payloadSHA256())
        XCTAssertEqual(stated["bundleID"] as? String, manifest.bundleID)
    }

    func testOnlyTheOneSpellingIsAManifest() throws {
        let payload = try golden().payload
        XCTAssertEqual(BundleManifest(payload: payload), try manifest())
        let text = String(decoding: payload, as: UTF8.self)
        let changes: [(String, String, String)] = [
            ("white space", #"{"version":1,"#, #"{ "version":1,"#),
            ("an unknown member", #"{"version":1,"#, #"{"version":1,"note":"x","#),
            ("a member repeated", #""blurred":false,"#, #""blurred":false,"blurred":false,"#),
            ("a number as a decimal", #""droppedFrames":0"#, #""droppedFrames":0.0"#),
            ("a number as text", #""chunkBytes":32"#, #""chunkBytes":"32""#),
            ("a member out of order", #""version":1,"kind":"avenkin.recording-bundle""#, #""kind":"avenkin.recording-bundle","version":1"#),
            ("a truth value as text", #""blurred":false"#, #""blurred":"false""#),
            ("a truth value as a number", #""blurred":false"#, #""blurred":0"#),
            ("a member left out", #""jobNumber":"JOB-1042","#, ""),
            ("another version", #"{"version":1,"#, #"{"version":2,"#),
            ("another kind", "avenkin.recording-bundle", "avenkin.recording-receipt"),
            ("a timeline version this is not", #""timelineVersion":1"#, #""timelineVersion":2"#),
        ]
        for (what, old, new) in changes {
            XCTAssertTrue(text.contains(old), what)
            XCTAssertNil(BundleManifest(payload: Data(text.replacingOccurrences(of: old, with: new).utf8)), what)
        }
        XCTAssertNil(BundleManifest(payload: Data()))
        XCTAssertNil(BundleManifest(payload: Data("[]".utf8)))
        XCTAssertNil(BundleManifest(payload: try F.data("recording-receipt-received-v1")), "a receipt is not a manifest")
    }

    // MARK: - What a manifest may list

    func testAManifestListsExactlyTheBundle() throws {
        XCTAssertNil(try manifest(jobNumber: #"JOB "1042""#), "a job number that needs an escape")
        XCTAssertNil(try manifest(droppedFrames: 3), "dropped frames with nothing blurred")
        XCTAssertNil(try manifest(consentAt: now + 1), "consent after the bundle was sealed")
        XCTAssertNil(try manifest(consentAt: 0), "no consent")
        XCTAssertNil(try manifest(chunkBytes: 64), "parts cut at another chunk size")
        XCTAssertNil(try manifest(chunkBytes: 0))

        var same = try parts()
        same[1] = .init(partID: "video-1", track: .audio, container: "m4a", plan: same[1].plan)
        XCTAssertNil(try manifest(parts: same), "two parts under one name")
        var path = try parts()
        path[0] = .init(partID: "../video", track: .video, container: "mp4", plan: path[0].plan)
        XCTAssertNil(try manifest(parts: path), "a part named as a path")
        var container = try parts()
        container[0] = .init(partID: "video-1", track: .video, container: "mkv", plan: container[0].plan)
        XCTAssertNil(try manifest(parts: container), "a container the contract does not name")

        // No job number, blurred with frames dropped, and no media at all are each a bundle.
        XCTAssertTrue(String(decoding: try XCTUnwrap(try manifest(jobNumber: nil)?.payload()), as: UTF8.self)
            .contains(#""jobNumber":"","#))
        XCTAssertNotNil(try manifest(blurred: true, droppedFrames: 12)?.payload())
        let bare = try XCTUnwrap(try manifest(parts: []))
        XCTAssertEqual(bare.files.count, 2)
        XCTAssertTrue(String(decoding: try XCTUnwrap(bare.payload()), as: UTF8.self).hasSuffix(#""parts":[]}"#))
        XCTAssertEqual(BundleManifest(payload: try XCTUnwrap(bare.payload())), bare)
    }

    func testIdenticalChunksAreOneFile() throws {
        // Two parts with the same bytes: each lists its chunks, and the bundle holds each once.
        let plan = try XCTUnwrap(ChunkPlan.plan(videoPart, chunkBytes: chunkBytes))
        let twice = try XCTUnwrap(try manifest(parts: [
            .init(partID: "video-1", track: .video, container: "mp4", plan: plan),
            .init(partID: "video-2", track: .video, container: "mp4", plan: plan),
        ]))
        XCTAssertEqual(twice.files.filter { $0.role == "media" }.count, 3)
        XCTAssertEqual(twice.parts.map(\.chunks), [plan.chunks.map(\.sha256), plan.chunks.map(\.sha256)])
        XCTAssertEqual(BundleManifest(payload: try XCTUnwrap(twice.payload())), twice)
    }
}
