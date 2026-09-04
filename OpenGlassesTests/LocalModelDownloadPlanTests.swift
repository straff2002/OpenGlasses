import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the download state machine as a value.
///
/// The transition table, the persisted shape and the recovery decision are pure, so "the app
/// recovers cleanly from termination during each transition" is decided here and merely *observed*
/// in the manager tests.
final class LocalModelDownloadPlanTests: XCTestCase {

    // MARK: - Construction

    func testAPlanCannotBeBuiltFromADescriptorThatCannotBeVerified() {
        // Unpinned revision, missing digest, zero size, escaping path, no files: each is enough on
        // its own, and each is the reason a download must not start.
        let unverifiable: [LocalModelDescriptor] = [
            descriptor(revision: LocalModelDescriptor.floatingRevision),
            descriptor(files: [LocalModelFile(relativePath: "m.gguf", byteCount: 10, sha256: "", role: .weights)]),
            descriptor(files: [LocalModelFile(relativePath: "m.gguf", byteCount: 0, sha256: digest, role: .weights)]),
            descriptor(files: [LocalModelFile(relativePath: "../m.gguf", byteCount: 10, sha256: digest, role: .weights)]),
            descriptor(files: []),
        ]
        for candidate in unverifiable {
            XCTAssertNil(LocalModelDownloadPlan(descriptor: candidate, origin: .repositoryImport),
                         candidate.files.first?.relativePath ?? "no files")
        }
        XCTAssertNotNil(LocalModelDownloadPlan(descriptor: descriptor(), origin: .curatedCatalog))
    }

    // MARK: - Transitions

    func testTheAllowedPathIsTheDiagrammedOne() throws {
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(fileCount: 2),
                                                        origin: .curatedCatalog))
        try plan.advance(to: .awaitingConsent)
        try plan.advance(to: .queued)
        try plan.advance(to: .downloading(fileIndex: 0))
        try plan.advance(to: .validating(fileIndex: 0))
        plan.markValidated(fileIndex: 0, byteCount: 10)
        try plan.advance(to: .downloading(fileIndex: 1))
        try plan.advance(to: .validating(fileIndex: 1))
        plan.markValidated(fileIndex: 1, byteCount: 10)
        try plan.advance(to: .installing)
        try plan.advance(to: .installed)
        XCTAssertEqual(plan.state, .installed)
        XCTAssertEqual(plan.fractionCompleted, 1)
    }

    func testForbiddenTransitions() throws {
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(fileCount: 2),
                                                        origin: .curatedCatalog))
        // Consent cannot be skipped, and a file cannot be skipped.
        XCTAssertThrowsError(try plan.advance(to: .downloading(fileIndex: 0)))
        try plan.advance(to: .awaitingConsent)
        try plan.advance(to: .queued)
        XCTAssertThrowsError(try plan.advance(to: .downloading(fileIndex: 1)),
                             "files are fetched in order")
        XCTAssertThrowsError(try plan.advance(to: .installing),
                             "nothing installs before every file validates")

        // A terminal state is terminal.
        var installed = plan
        try installed.advance(to: .downloading(fileIndex: 0))
        try installed.advance(to: .validating(fileIndex: 0))
        installed.markValidated(fileIndex: 0, byteCount: 10)
        try installed.advance(to: .downloading(fileIndex: 1))
        try installed.advance(to: .validating(fileIndex: 1))
        installed.markValidated(fileIndex: 1, byteCount: 10)
        try installed.advance(to: .installing)
        try installed.advance(to: .installed)
        XCTAssertThrowsError(try installed.advance(to: .queued))
        XCTAssertThrowsError(try installed.advance(to: .cancelled),
                             "an installed model is deleted, not cancelled")
        XCTAssertThrowsError(try installed.advance(to: .failed(.retryable(.transport))))
    }

    func testRetryableFailuresMayRequeueAndTerminalOnesMayNot() throws {
        var retryable = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(),
                                                             origin: .curatedCatalog))
        try retryable.advance(to: .failed(.retryable(.transport)))
        XCTAssertNoThrow(try retryable.advance(to: .queued))

        var terminal = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(),
                                                            origin: .curatedCatalog))
        try terminal.advance(to: .failed(.terminal(.digestMismatch)))
        XCTAssertThrowsError(try terminal.advance(to: .queued))
        XCTAssertNoThrow(try terminal.advance(to: .cancelled), "a dead plan can still be cleared")
    }

    func testFailureClassificationIsFixedAndDeliberate() {
        for reason in [LocalModelDownloadPlan.FailureReason.transport, .httpStatus,
                       .storageUnavailable, .installFailed] {
            XCTAssertTrue(LocalModelDownloadPlan.Failure.classify(reason).isRetryable, reason.rawValue)
        }
        for reason in [LocalModelDownloadPlan.FailureReason.sizeMismatch, .digestMismatch,
                       .redirectHostRejected, .insecureRedirect, .containmentRefused,
                       .revisionMismatch, .planUnreadable, .consentMissing, .fitRefused] {
            XCTAssertFalse(LocalModelDownloadPlan.Failure.classify(reason).isRetryable,
                           "\(reason.rawValue): refetching the same bytes is not a fix")
        }
    }

    // MARK: - Progress and recovery

    func testProgressComesFromPersistedBytes() throws {
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(fileCount: 2),
                                                        origin: .curatedCatalog))
        XCTAssertEqual(plan.fractionCompleted, 0)
        plan.recordProgress(fileIndex: 0, completedBytes: 5)
        XCTAssertEqual(plan.fractionCompleted, 0.25, accuracy: 0.0001)
        plan.markValidated(fileIndex: 0, byteCount: 10)
        XCTAssertEqual(plan.fractionCompleted, 0.5, accuracy: 0.0001)
        // A count beyond the file's size cannot inflate the bar.
        plan.recordProgress(fileIndex: 1, completedBytes: 999)
        XCTAssertEqual(plan.fractionCompleted, 1, accuracy: 0.0001)
    }

    func testRecoveryForEveryState() throws {
        let base = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(fileCount: 2),
                                                        origin: .curatedCatalog))
        func recovery(_ state: LocalModelDownloadPlan.State,
                      validatedFiles: Int = 0) -> LocalModelDownloadPlan.Recovery {
            var plan = base
            for index in 0..<validatedFiles { plan.markValidated(fileIndex: index, byteCount: 10) }
            plan.state = state
            return plan.recovery
        }

        XCTAssertEqual(recovery(.planned), .awaitUser)
        XCTAssertEqual(recovery(.awaitingConsent), .awaitUser)
        XCTAssertEqual(recovery(.queued), .resumeDownload(fileIndex: 0))
        XCTAssertEqual(recovery(.downloading(fileIndex: 0)), .resumeDownload(fileIndex: 0))
        XCTAssertEqual(recovery(.validating(fileIndex: 0)), .resumeDownload(fileIndex: 0))
        XCTAssertEqual(recovery(.downloading(fileIndex: 1), validatedFiles: 1),
                       .resumeDownload(fileIndex: 1))
        XCTAssertEqual(recovery(.validating(fileIndex: 1), validatedFiles: 2), .finishInstall)
        XCTAssertEqual(recovery(.installing, validatedFiles: 2), .finishInstall)
        XCTAssertEqual(recovery(.installing), .resumeDownload(fileIndex: 0),
                       "\"installing\" is not evidence that the bytes are still there")
        XCTAssertEqual(recovery(.installed), .discard)
        XCTAssertEqual(recovery(.cancelled), .discard)
        XCTAssertEqual(recovery(.failed(.retryable(.transport))), .offerRetry(.transport))
        XCTAssertEqual(recovery(.failed(.terminal(.digestMismatch))), .discard)
    }

    // MARK: - Persistence shape

    func testPlanRoundTripsThroughItsStoredForm() throws {
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(fileCount: 2),
                                                        origin: .repositoryImport))
        plan.markValidated(fileIndex: 0, byteCount: 10)
        plan.acceptedLicenseRevision = "rev"
        plan.state = .validating(fileIndex: 1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LocalModelDownloadPlan.self, from: encoder.encode(plan))

        XCTAssertEqual(decoded.state, .validating(fileIndex: 1))
        XCTAssertEqual(decoded.files, plan.files)
        XCTAssertEqual(decoded.origin, .repositoryImport)
        XCTAssertEqual(decoded.acceptedLicenseRevision, "rev")

        // The stored form is readable, not a synthesized enum blob.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plan))
                                    as? [String: Any])
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(state["name"] as? String, "validating")
        XCTAssertEqual(state["fileIndex"] as? Int, 1)
    }

    func testAnUnreadableStoredStateBecomesATerminalFailureRatherThanAGuess() throws {
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(),
                                                        origin: .curatedCatalog))
        plan.state = .queued
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plan))
                                    as? [String: Any])
        json["state"] = ["name": "somethingFromTheFuture"]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            LocalModelDownloadPlan.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.state, .failed(.terminal(.planUnreadable)))
    }

    // MARK: - Transfer identifiers

    func testTransferIdentifiersRoundTripAndRejectRubbish() {
        let identifier = LocalModelTransferIdentifier(planID: UUID(), fileIndex: 3)
        XCTAssertEqual(LocalModelTransferIdentifier(identifier.description), identifier)
        for bad in [nil, "", "not-a-uuid#0", identifier.planID.uuidString,
                    "\(identifier.planID.uuidString)#x", "\(identifier.planID.uuidString)#-1"] {
            XCTAssertNil(LocalModelTransferIdentifier(bad), bad ?? "nil")
        }
    }

    // MARK: - Helpers

    private let digest = String(repeating: "a", count: 64)

    private func descriptor(revision: String = String(repeating: "b", count: 40),
                            fileCount: Int = 1,
                            files: [LocalModelFile]? = nil) -> LocalModelDescriptor {
        let resolved = files ?? (0..<fileCount).map {
            LocalModelFile(relativePath: "file\($0).gguf", byteCount: 10, sha256: digest, role: .weights)
        }
        return LocalModelDescriptor(
            id: LocalModelID("owner/repo#file.gguf"),
            displayName: "Test",
            runtime: .llamaCpp,
            repositoryID: "owner/repo",
            revision: revision,
            files: resolved,
            quantization: "Q4_K_M",
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: Int64(10 * max(resolved.count, 1)),
            estimatedWorkingBytes: 1,
            minimumHeadroomBytes: 0)
    }
}
