import XCTest
@testable import OpenGlasses

/// Plan HX follow-up — a camera start nobody asked for never leaves the app for Meta AI.
///
/// The decision is a table. What carries "who began this" from the launch call sites to the
/// permission step is a task-local, so the second half drives the coordinator through the fake
/// backend and reads what reached it. The step itself is in the Meta backend, which cannot run
/// here (`Wearables` traps in a unit-test host), so the last tests read the source.
@MainActor
final class CameraPermissionRequestPolicyTests: XCTestCase {

    private typealias Policy = CameraPermissionRequestPolicy

    // MARK: - The table

    func testAGrantedPermissionProceedsWhoeverBeganTheStart() {
        XCTAssertEqual(Policy.step(granted: true, initiator: .wearer), .proceed)
        XCTAssertEqual(Policy.step(granted: true, initiator: .app), .proceed)
    }

    func testAStartTheWearerAskedForAsks() {
        XCTAssertEqual(Policy.step(granted: false, initiator: .wearer), .request)
    }

    func testAStartTheAppBeganFailsWithoutAsking() {
        XCTAssertEqual(Policy.step(granted: false, initiator: .app), .failWithoutAsking)
    }

    // MARK: - What the wearer is told

    func testTheNoticeSaysWhereTheRowToPressIsAndIsTheCardsOwnHint() {
        XCTAssertEqual(Policy.notice, SessionCardGlassesPill.awayHint(for: .permissionNeeded))
        XCTAssertTrue(Policy.notice.contains("Settings › Devices & Privacy › Glasses"))
        XCTAssertTrue(Policy.notice.localizedCaseInsensitiveContains("camera access"))
        XCTAssertEqual(CameraError.permissionNotRequested.errorDescription, Policy.notice,
                       "a caller that shows the error shows what to press, not a bare refusal")
    }

    // MARK: - Who began it

    func testEveryStartIsTheWearersUnlessACallerSaysOtherwise() {
        XCTAssertEqual(Policy.initiator, .wearer)
    }

    func testTheAppsOwnWorkIsMarkedForItsDurationOnly() async {
        let inside = await Policy.startedByApp { Policy.initiator }
        XCTAssertEqual(inside, .app)
        XCTAssertEqual(Policy.initiator, .wearer, "the mark does not outlive the work")
    }

    /// The coordinator runs a start on a task of its own, and a session manager is several calls
    /// further on. The mark has to survive both.
    func testTheMarkFollowsTheWorkIntoATaskItStarts() async {
        let inside = await Policy.startedByApp {
            await Task { @MainActor in Policy.initiator }.value
        }
        XCTAssertEqual(inside, .app)
    }

    func testAnExplicitMarkOverridesTheOneItWasStartedUnder() async {
        let inside = await Policy.startedByApp {
            await Policy.begun(by: .wearer) { Policy.initiator }
        }
        XCTAssertEqual(inside, .wearer)
    }

    // MARK: - Through the coordinator

    private func makeService() -> (CameraService, MockCameraBackend) {
        let backend = MockCameraBackend(isReady: true)
        // Not decodable as an image on purpose: keeps the photo-library write out of a unit test.
        backend.captureResult = .success(Data([0xDE, 0xAD]))
        return (CameraService(backend: backend, phoneCamera: MockPhoneCamera()), backend)
    }

    func testAnOrdinaryStartReachesTheBackendAsTheWearers() async throws {
        let (service, backend) = makeService()
        _ = try await service.startStreaming()
        _ = try await service.capturePhoto()
        XCTAssertEqual(backend.workInitiators, [.wearer, .wearer])
    }

    func testAStartTheAppBeganReachesTheBackendMarked() async throws {
        let (service, backend) = makeService()
        try await Policy.startedByApp { _ = try await service.startStreaming() }
        XCTAssertEqual(backend.workInitiators, [.app])
    }

    func testAClaimAndACaptureInsideTheAppsWorkAreMarkedToo() async throws {
        let (service, backend) = makeService()
        try await Policy.startedByApp {
            try await service.claimStream(for: .liveSession)
            _ = try await service.capturePhoto()
        }
        XCTAssertEqual(backend.workInitiators, [.app, .app])
    }

    func testTheNextStartAfterTheAppsIsTheWearersAgain() async throws {
        let (service, backend) = makeService()
        try await Policy.startedByApp { _ = try await service.startStreaming() }
        await service.stopStreaming()
        _ = try await service.startStreaming()
        XCTAssertEqual(backend.workInitiators, [.app, .wearer])
    }

    /// What the real backend does for an unasked start with the permission missing: the status,
    /// the notice, the throw. On this side of the seam that must fail the start cleanly, leave
    /// nothing armed, hand the status on for the diagnosis and put the notice where it is read.
    func testAStartFailedForAnUnaskedPermissionLeavesTheDiagnosisAndTheNotice() async {
        let (service, backend) = makeService()
        var statuses: [GlassesCameraPermission] = []
        service.onGlassesCameraPermission = { statuses.append($0) }
        backend.startError = CameraError.permissionNotRequested
        defer { NoticeCenter.shared.clear(source: .camera) }

        do {
            try await Policy.startedByApp {
                backend.events.send(.cameraPermission(.notGranted))
                backend.events.send(.transientNotice(Policy.notice))
                try await service.claimStream(for: .liveSession)
            }
            XCTFail("expected the start to fail")
        } catch CameraError.permissionNotRequested {
        } catch {
            XCTFail("failed with the wrong error: \(type(of: error))")
        }

        XCTAssertEqual(statuses, [.notGranted])
        XCTAssertEqual(GlassesReachabilityDiagnosis.resolve(
            registration: .registered, links: [], permission: statuses.first ?? .notChecked),
                       .permissionNeeded)
        XCTAssertEqual(service.streamingNotice, Policy.notice)
        XCTAssertFalse(service.isStartingStream)
        XCTAssertFalse(service.hasStreamClaims, "a claim on a stream that never came up is not kept")
        XCTAssertEqual(service.scheduledCameraWorkCount, 0)
    }

    // MARK: - The callers that cannot run here

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The source with whole-line `//` comments dropped, so prose that names a call is not
    /// mistaken for the call.
    private func code(_ path: String) throws -> String {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func slice(of code: String, from opening: String, to closing: String,
                       _ what: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: opening), "the source no longer has \(what)")
        let rest = code[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: closing), "could not find the end of \(what)")
        return rest[..<end.lowerBound]
    }

    /// `ensurePermission()` is the only place a camera start asks, and it must ask the table first.
    func testTheBackendAsksTheTableBeforeItAsksMetaAI() throws {
        let backend = try code("OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift")
        let ensure = try slice(of: backend, from: "func ensurePermission() async throws {",
                               to: "private func phoneCameraAllowed()", "`ensurePermission()`")
        let decision = try XCTUnwrap(ensure.range(of: "CameraPermissionRequestPolicy.step("),
                                     "a camera start no longer asks whether it may request the "
                                         + "permission: the app's own starts at launch can open "
                                         + "Meta AI again")
        XCTAssertTrue(ensure.contains("initiator: CameraPermissionRequestPolicy.initiator"))
        let request = try XCTUnwrap(ensure.range(of: "requestPermission(.camera)"))
        XCTAssertLessThan(decision.lowerBound, request.lowerBound)
        XCTAssertEqual(ensure.components(separatedBy: "requestPermission(.camera)").count, 2,
                       "a second request in `ensurePermission()` would not be behind the table")

        let refused = try slice(of: backend, from: "} catch CameraError.permissionNotRequested {",
                                to: "} catch {", "the unasked-permission branch")
        XCTAssertTrue(refused.contains("events.send(.cameraPermission(.notGranted))"),
                      "the diagnosis is no longer told the permission is missing")
        XCTAssertTrue(refused.contains("events.send(.transientNotice(CameraPermissionRequestPolicy.notice))"),
                      "the wearer is no longer told what to press")
        XCTAssertTrue(refused.contains("throw CameraError.permissionNotRequested"),
                      "the start must fail here, not go round the retry loop")
    }

    /// The camera start a live mode makes at launch is the app's own.
    func testTheLaunchCameraStartIsMarkedAsTheApps() throws {
        let appState = try code("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        let launch = try slice(of: appState, from: "private func startModeSubstrateOnLaunch() {",
                               to: "\n    }\n", "`startModeSubstrateOnLaunch()`")
        let mark = try XCTUnwrap(launch.range(of: "CameraPermissionRequestPolicy.startedByApp {"),
                                 "the launch camera start is no longer marked as the app's own: "
                                     + "with the permission missing it opens Meta AI unasked")
        let start = try XCTUnwrap(launch.range(of: "cameraService.startStreaming()"))
        XCTAssertLessThan(mark.lowerBound, start.lowerBound)
    }
}
