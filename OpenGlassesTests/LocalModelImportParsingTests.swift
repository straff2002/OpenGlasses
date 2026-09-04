import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the repository importer's parsing half.
///
/// The rejection table is the point: every rule in the plan's "Import parsing" section gets its own
/// case, because a host allowlist with one untested hole is a host allowlist that does not exist.
/// Nothing here touches the network — the two fetches are behind a protocol and the enumeration
/// rules are exercised against fixtures.
final class LocalModelImportParsingTests: XCTestCase {

    // MARK: - Accepted forms

    func testShorthandAndURLFormsResolveToTheSameReference() {
        let expected = LocalModelRepositoryReference(host: "huggingface.co",
                                                     owner: "Qwen",
                                                     repository: "Qwen2.5-0.5B-Instruct-GGUF")
        for input in ["Qwen/Qwen2.5-0.5B-Instruct-GGUF",
                      "  Qwen/Qwen2.5-0.5B-Instruct-GGUF  ",
                      "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF",
                      "https://www.huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF",
                      "https://hf.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF",
                      "https://HuggingFace.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF",
                      "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF.git"] {
            switch LocalModelRepositoryReference.parse(input) {
            case .success(let reference):
                XCTAssertEqual(reference, expected, "input: \(input)")
            case .failure(let rejection):
                XCTFail("\(input) should parse, got \(rejection)")
            }
        }
    }

    // MARK: - The rejection table

    func testRejectionTable() {
        let cases: [(input: String, expected: LocalModelImportRejection)] = [
            ("", .empty),
            ("   ", .empty),
            ("owner repo", .notAURL),
            ("owner", .notAURL),
            ("huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF", .missingScheme),
            ("hf.co/owner/repo", .missingScheme),
            ("owner/repo/tree/main", .pathOutsideRepositoryForm),
            ("http://huggingface.co/owner/repo", .disallowedScheme("http")),
            ("ftp://huggingface.co/owner/repo", .disallowedScheme("ftp")),
            ("file:///etc/passwd", .disallowedScheme("file")),
            ("javascript://huggingface.co/owner/repo", .disallowedScheme("javascript")),
            ("https://user:secret@huggingface.co/owner/repo", .embeddedCredentials),
            ("https://huggingface.co/owner/repo?token=abc", .queryNotAllowed),
            ("https://huggingface.co/owner/repo#anchor", .fragmentNotAllowed),
            ("https://evil.example.com/owner/repo", .disallowedHost("evil.example.com")),
            // A lookalike subdomain is not the allowlisted host.
            ("https://huggingface.co.evil.example/owner/repo", .disallowedHost("huggingface.co.evil.example")),
            ("https://cdn-lfs.huggingface.co/owner/repo", .disallowedHost("cdn-lfs.huggingface.co")),
            ("https://127.0.0.1/owner/repo", .privateOrReservedHost("127.0.0.1")),
            ("https://192.168.1.1/owner/repo", .privateOrReservedHost("192.168.1.1")),
            ("https://169.254.169.254/owner/repo", .privateOrReservedHost("169.254.169.254")),
            ("https://localhost/owner/repo", .privateOrReservedHost("localhost")),
            ("https://huggingface.co/owner", .pathOutsideRepositoryForm),
            ("https://huggingface.co/owner/repo/tree/main", .pathOutsideRepositoryForm),
            ("https://huggingface.co/owner/repo/resolve/main/model.gguf", .pathOutsideRepositoryForm),
            // Traversal, plain and percent-encoded: both leave the repository form.
            ("https://huggingface.co/owner/../../etc/passwd", .pathOutsideRepositoryForm),
            ("https://huggingface.co/%2e%2e/%2e%2e/etc", .pathOutsideRepositoryForm),
            ("../owner/repo", .pathOutsideRepositoryForm),
            ("..%2Frepo", .notAURL),
            ("-owner/repo", .malformedOwner),
            ("ow ner/repo", .notAURL),
            ("owner/re;po", .malformedRepository),
            ("owner/re..po", .malformedRepository),
            ("owner/", .malformedRepository),
            ("/repo", .malformedOwner),
        ]

        for testCase in cases {
            switch LocalModelRepositoryReference.parse(testCase.input) {
            case .success(let reference):
                XCTFail("\(testCase.input) should be refused, parsed as \(reference.repositoryID)")
            case .failure(let rejection):
                XCTAssertEqual(rejection, testCase.expected, "input: \(testCase.input)")
            }
        }
    }

    /// A site route that *happens* to have two path segments parses as a reference, and that is
    /// deliberate: structure cannot tell `owner/repo` from an app route, and a denylist of the
    /// host's own pages would be a list to maintain forever. Resolution is what settles it — the
    /// first thing the planner does is ask the metadata API, which has no such repository.
    func testARouteShapedLikeARepositoryIsLeftForResolutionToRefuse() {
        guard case .success(let reference) =
                LocalModelRepositoryReference.parse("https://huggingface.co/settings/tokens") else {
            return XCTFail("a two-segment path is structurally a repository reference")
        }
        XCTAssertEqual(reference.repositoryID, "settings/tokens")
    }

    func testEveryRejectionHasUserFacingCopyThatDoesNotEchoTheInput() {
        let rejections: [LocalModelImportRejection] = [
            .empty, .notAURL, .missingScheme, .disallowedScheme("gopher"), .embeddedCredentials,
            .queryNotAllowed, .fragmentNotAllowed, .disallowedHost("evil.example"),
            .privateOrReservedHost("10.0.0.1"), .pathOutsideRepositoryForm,
            .malformedOwner, .malformedRepository,
        ]
        for rejection in rejections {
            let message = rejection.localizedMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("evil.example"))
            XCTAssertFalse(message.contains("10.0.0.1"))
            XCTAssertFalse(message.contains("gopher"))
        }
    }

    // MARK: - Download host policy

    func testDownloadHostPolicyAllowsTheCDNFamilyAndNothingElse() {
        // Real weights are served from CDN hosts under the same domains — a policy pinned to the
        // repository host alone would refuse every actual download.
        for allowed in ["https://huggingface.co/x", "https://cdn-lfs.huggingface.co/x",
                        "https://us.aws.cdn.hf.co/x", "https://transfer.xethub.hf.co/x",
                        "https://hf.co/x"] {
            XCTAssertTrue(LocalModelRepositoryReference.isAllowedDownloadURL(URL(string: allowed)!),
                          allowed)
        }
        for refused in ["http://huggingface.co/x",                  // not HTTPS
                        "https://user:pw@huggingface.co/x",         // credentials
                        "https://huggingface.co.evil.example/x",    // suffix lookalike
                        "https://evil.example/huggingface.co/x",
                        "https://s3.amazonaws.com/x",
                        "https://127.0.0.1/x"] {
            XCTAssertFalse(LocalModelRepositoryReference.isAllowedDownloadURL(URL(string: refused)!),
                           refused)
        }
        XCTAssertFalse(LocalModelRepositoryReference.isAllowedDownloadURL(nil))
    }

    // MARK: - File URLs

    func testFileURLRequiresAnExactRevisionAndAContainedPath() {
        let reference = LocalModelRepositoryReference(host: "huggingface.co",
                                                      owner: "Qwen",
                                                      repository: "Qwen2.5-0.5B-Instruct-GGUF")
        let revision = String(repeating: "a", count: 40)
        XCTAssertEqual(
            reference.fileURL(revision: revision, relativePath: "model.gguf")?.absoluteString,
            "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/\(revision)/model.gguf")

        // A branch, a short hash and an empty revision are all refused — a floating pointer is not
        // installable metadata.
        for badRevision in ["main", "abc1234", "", String(repeating: "z", count: 40)] {
            XCTAssertNil(reference.fileURL(revision: badRevision, relativePath: "model.gguf"),
                         badRevision)
        }
        // Traversal never produces a URL.
        for badPath in ["../../etc/passwd", "/etc/passwd", "%2e%2e/x.gguf", ""] {
            XCTAssertNil(reference.fileURL(revision: revision, relativePath: badPath), badPath)
        }
    }

    // MARK: - Quantization labels and shard grouping

    func testQuantizationLabelsAreParsedAsDisplayTextOnly() {
        XCTAssertEqual(GGUFFileName.quantizationLabel(for: "qwen2.5-0.5b-instruct-q4_k_m.gguf"), "Q4_K_M")
        XCTAssertEqual(GGUFFileName.quantizationLabel(for: "Model-IQ4_XS.gguf"), "IQ4_XS")
        XCTAssertEqual(GGUFFileName.quantizationLabel(for: "smollm2-360m-instruct-q8_0.gguf"), "Q8_0")
        XCTAssertEqual(GGUFFileName.quantizationLabel(for: "model.F16.gguf"), "F16")
        XCTAssertNil(GGUFFileName.quantizationLabel(for: "model.gguf"))
        // Not a boundary-delimited token: a caption is never pulled out of the middle of a word.
        XCTAssertNil(GGUFFileName.quantizationLabel(for: "modelq4_k_mx.gguf"))
    }

    func testShardedFilesGroupIntoOneCandidate() throws {
        let files = [
            LocalModelRemoteFile(path: "big-00001-of-00002.gguf", byteCount: 10, sha256: digest("a")),
            LocalModelRemoteFile(path: "big-00002-of-00002.gguf", byteCount: 20, sha256: digest("b")),
            LocalModelRemoteFile(path: "small-q4_k_m.gguf", byteCount: 5, sha256: digest("c")),
        ]
        let offer = try XCTUnwrap(try? LocalModelImportPlanner.makeOffer(reference: reference,
                                                                         metadata: metadata(),
                                                                         files: files))
        XCTAssertEqual(offer.weights.count, 2)
        let sharded = offer.weights.first { $0.id == "big.gguf" }
        XCTAssertEqual(sharded?.files.count, 2, "a shard group is one candidate, never one shard")
        XCTAssertEqual(sharded?.byteCount, 30)
    }

    func testProjectorsAreListedSeparatelyAndGrantNoCapability() throws {
        let files = [
            LocalModelRemoteFile(path: "model-q4_k_m.gguf", byteCount: 10, sha256: digest("a")),
            LocalModelRemoteFile(path: "mmproj-model-f16.gguf", byteCount: 3, sha256: digest("b")),
        ]
        let offer = try LocalModelImportPlanner.makeOffer(reference: reference,
                                                          metadata: metadata(),
                                                          files: files)
        XCTAssertEqual(offer.weights.map(\.id), ["model-q4_k_m.gguf"])
        XCTAssertEqual(offer.projectors.map(\.id), ["mmproj-model-f16.gguf"])

        let descriptor = try LocalModelImportPlanner.descriptor(for: XCTUnwrap(offer.defaultSelection),
                                                                in: offer)
        XCTAssertEqual(descriptor.capabilities, [.text],
                       "a projector in the repository must not make the import vision-capable")
    }

    // MARK: - Default selection

    func testCuratedDefaultOnlyWhenTheExactPreferredFileIsPresent() throws {
        let withPreferred = try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "m-q4_k_m.gguf", byteCount: 10, sha256: digest("a")),
                    LocalModelRemoteFile(path: "m-q8_0.gguf", byteCount: 20, sha256: digest("b"))])
        XCTAssertEqual(withPreferred.defaultSelection?.id, "m-q4_k_m.gguf")
        XCTAssertFalse(withPreferred.requiresSelection)

        let withoutPreferred = try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "m-q5_k_m.gguf", byteCount: 10, sha256: digest("a")),
                    LocalModelRemoteFile(path: "m-q8_0.gguf", byteCount: 20, sha256: digest("b"))])
        XCTAssertNil(withoutPreferred.defaultSelection)
        XCTAssertTrue(withoutPreferred.requiresSelection, "the user chooses when nothing matches exactly")
    }

    func testCandidateWithoutDigestOrSizeIsNotInstallable() throws {
        let offer = try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "good-q4_k_m.gguf", byteCount: 10, sha256: digest("a")),
                    LocalModelRemoteFile(path: "nodigest-q8_0.gguf", byteCount: 10, sha256: nil),
                    LocalModelRemoteFile(path: "nosize-q6_k.gguf", byteCount: 0, sha256: digest("c"))])
        let unverifiable = offer.weights.filter { !$0.isInstallable }.map(\.id)
        XCTAssertEqual(Set(unverifiable), ["nodigest-q8_0.gguf", "nosize-q6_k.gguf"])

        for candidate in offer.weights where !candidate.isInstallable {
            XCTAssertThrowsError(try LocalModelImportPlanner.descriptor(for: candidate, in: offer)) {
                XCTAssertEqual($0 as? LocalModelImportFault, .noVerifiableFiles)
            }
        }
    }

    // MARK: - Offer-level refusals

    func testOfferRefusals() {
        // No GGUF at all.
        XCTAssertThrowsError(try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "README.md", byteCount: 10, sha256: nil)])) {
            XCTAssertEqual($0 as? LocalModelImportFault, .noEligibleFiles)
        }
        // Nothing verifiable.
        XCTAssertThrowsError(try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "m.gguf", byteCount: 10, sha256: nil)])) {
            XCTAssertEqual($0 as? LocalModelImportFault, .noVerifiableFiles)
        }
        // A traversal anywhere in the listing sinks the whole offer.
        XCTAssertThrowsError(try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "ok-q4_k_m.gguf", byteCount: 10, sha256: digest("a")),
                    LocalModelRemoteFile(path: "../escape.gguf", byteCount: 10, sha256: digest("b"))])) {
            XCTAssertEqual($0 as? LocalModelImportFault, .pathOutsideModelRoot)
        }
    }

    func testGatedOrUnresolvedRepositoriesAreRefusedBeforeAnyPlanExists() async {
        let listing = [LocalModelRemoteFile(path: "m-q4_k_m.gguf", byteCount: 10, sha256: digest("a"))]

        let gated = LocalModelImportPlanner(fetcher: FakeMetadataFetcher(
            metadata: LocalModelRepositoryMetadata(revision: String(repeating: "a", count: 40),
                                                   licenseIdentifier: "apache-2.0",
                                                   isGated: true, isPrivate: false),
            files: listing))
        await XCTAssertThrowsErrorAsync(try await gated.offer(for: reference)) {
            XCTAssertEqual($0 as? LocalModelImportFault, .repositoryNotPublic)
        }

        let floating = LocalModelImportPlanner(fetcher: FakeMetadataFetcher(
            metadata: LocalModelRepositoryMetadata(revision: "main",
                                                   licenseIdentifier: nil,
                                                   isGated: false, isPrivate: false),
            files: listing))
        await XCTAssertThrowsErrorAsync(try await floating.offer(for: reference)) {
            XCTAssertEqual($0 as? LocalModelImportFault, .revisionNotResolved)
        }
    }

    // MARK: - Descriptor construction

    func testImportedDescriptorIsPinnedInstallableAndTextOnly() throws {
        let revision = String(repeating: "b", count: 40)
        let offer = try LocalModelImportPlanner.makeOffer(
            reference: reference,
            metadata: LocalModelRepositoryMetadata(revision: revision,
                                                   licenseIdentifier: "apache-2.0",
                                                   isGated: false, isPrivate: false),
            files: [LocalModelRemoteFile(path: "m-q4_k_m.gguf", byteCount: 1_024, sha256: digest("a"))])
        let descriptor = try LocalModelImportPlanner.descriptor(
            for: try XCTUnwrap(offer.defaultSelection), in: offer)

        XCTAssertEqual(descriptor.runtime, .llamaCpp)
        XCTAssertEqual(descriptor.revision, revision)
        XCTAssertEqual(descriptor.quantization, "Q4_K_M")
        XCTAssertEqual(descriptor.capabilities, [.text])
        XCTAssertEqual(descriptor.contextLength, LocalModelImportPlanner.importedContextTokens)
        XCTAssertTrue(descriptor.installationFaults().isEmpty,
                      "an offer's descriptor must pass the very gate the downloader applies")
        XCTAssertEqual(descriptor.license.displayName, "Apache License 2.0")
        XCTAssertFalse(descriptor.license.requiresAcceptance)
    }

    func testUnknownLicenceRequiresAcceptanceAndClaimsNoSummary() {
        let summary = LocalModelLicenseSummary.imported(identifier: "some-custom-terms",
                                                        revision: String(repeating: "c", count: 40))
        XCTAssertTrue(summary.requiresAcceptance)
        XCTAssertNil(summary.revision, "an unread licence names no revision it could claim to summarize")
    }

    func testCandidateFromAnotherOfferIsRefused() throws {
        let offerA = try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "a-q4_k_m.gguf", byteCount: 10, sha256: digest("a"))])
        let offerB = try LocalModelImportPlanner.makeOffer(
            reference: reference, metadata: metadata(),
            files: [LocalModelRemoteFile(path: "b-q4_k_m.gguf", byteCount: 10, sha256: digest("b"))])
        XCTAssertThrowsError(try LocalModelImportPlanner.descriptor(
            for: try XCTUnwrap(offerA.defaultSelection), in: offerB)) {
            XCTAssertEqual($0 as? LocalModelImportFault, .unknownSelection)
        }
    }

    // MARK: - Response decoding (fixtures, never the network)

    func testMetadataDecodingTreatsAnythingButFalseAsGated() throws {
        let open = try LocalModelRepositoryClient.parseMetadata(Data("""
        {"sha":"\(String(repeating: "a", count: 40))","private":false,"gated":false,
         "cardData":{"license":"apache-2.0"}}
        """.utf8))
        XCTAssertFalse(open.isGated)
        XCTAssertEqual(open.licenseIdentifier, "apache-2.0")

        for gatedValue in ["\"auto\"", "\"manual\"", "true", "{}"] {
            let parsed = try LocalModelRepositoryClient.parseMetadata(Data("""
            {"sha":"\(String(repeating: "a", count: 40))","gated":\(gatedValue)}
            """.utf8))
            XCTAssertTrue(parsed.isGated, "gated: \(gatedValue)")
        }

        XCTAssertThrowsError(try LocalModelRepositoryClient.parseMetadata(Data("{}".utf8)))
    }

    func testFileListingTakesDigestsOnlyFromTheLargeFileRecord() throws {
        let sha = digest("a")
        let files = try LocalModelRepositoryClient.parseFileListing(Data("""
        [{"type":"directory","path":"sub"},
         {"type":"file","path":"m.gguf","size":123,"lfs":{"oid":"\(sha)","size":456}},
         {"type":"file","path":"README.md","size":10},
         {"type":"file","path":"weird.gguf","size":7,"lfs":{"oid":"not-a-sha"}}]
        """.utf8))
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0], LocalModelRemoteFile(path: "m.gguf", byteCount: 456, sha256: sha),
                       "the large-file record's size wins: it is the size of the real object")
        XCTAssertNil(files[1].sha256)
        XCTAssertNil(files[2].sha256, "a digest that is not SHA-256-shaped is no digest at all")
    }

    // MARK: - Helpers

    private let reference = LocalModelRepositoryReference(host: "huggingface.co",
                                                          owner: "owner",
                                                          repository: "repo")

    private func metadata() -> LocalModelRepositoryMetadata {
        LocalModelRepositoryMetadata(revision: String(repeating: "a", count: 40),
                                     licenseIdentifier: "apache-2.0",
                                     isGated: false,
                                     isPrivate: false)
    }

    /// A 64-character lowercase hex string. Digest *shape* is what these fixtures need; the real
    /// hashing is exercised against real bytes in the download-manager tests.
    private func digest(_ seed: String) -> String {
        String(repeating: seed.lowercased(), count: 64)
    }
}

/// A fetcher that answers from fixtures. The suite has no other kind.
struct FakeMetadataFetcher: LocalModelRepositoryMetadataFetching {
    let metadata: LocalModelRepositoryMetadata
    let files: [LocalModelRemoteFile]

    func metadata(for reference: LocalModelRepositoryReference) async throws -> LocalModelRepositoryMetadata {
        metadata
    }

    func files(for reference: LocalModelRepositoryReference,
               revision: String) async throws -> [LocalModelRemoteFile] {
        files
    }
}

/// `XCTAssertThrowsError` has no async form; this is the smallest thing that does the job.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath,
                                  line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
