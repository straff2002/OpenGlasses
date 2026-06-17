import XCTest
@testable import OpenGlasses

/// Tests for the shared `DeviceSession` ownership core (Additional Capabilities #3): the pure
/// `DeviceSessionOwnership` ref-count state machine and the `DeviceSessionCoordinator`'s
/// create/teardown lifecycle (via an injected fake session, no SDK).
@MainActor
final class DeviceSessionCoordinatorTests: XCTestCase {

    // MARK: - DeviceSessionOwnership (pure)

    func testFirstAcquireReportsFirstHolder() {
        var ownership = DeviceSessionOwnership()
        XCTAssertTrue(ownership.acquire(.camera))    // first → create
        XCTAssertFalse(ownership.acquire(.display))  // second → reuse
        XCTAssertTrue(ownership.isShared)
    }

    func testAcquireIsIdempotentForSameCapability() {
        var ownership = DeviceSessionOwnership()
        XCTAssertTrue(ownership.acquire(.camera))
        XCTAssertFalse(ownership.acquire(.camera))   // already holding → not "first" again
        XCTAssertEqual(ownership.holders, [.camera])
        XCTAssertFalse(ownership.isShared)
    }

    func testReleaseLastHolderReportsEmpty() {
        var ownership = DeviceSessionOwnership()
        ownership.acquire(.camera)
        ownership.acquire(.display)
        XCTAssertFalse(ownership.release(.camera))   // display still holds → keep
        XCTAssertTrue(ownership.release(.display))    // last out → tear down
        XCTAssertFalse(ownership.isHeld)
    }

    func testReleaseUnheldCapabilityIsNoOp() {
        var ownership = DeviceSessionOwnership()
        ownership.acquire(.camera)
        XCTAssertFalse(ownership.release(.display))   // wasn't holding
        XCTAssertTrue(ownership.holds(.camera))
    }

    // MARK: - DeviceSessionCoordinator (fake session)

    private final class FakeSession: DeviceSessionHandle {
        private(set) var stopCount = 0
        func stop() { stopCount += 1 }
    }

    private func makeCoordinator() -> (DeviceSessionCoordinator, () -> [FakeSession]) {
        final class Box { var created: [FakeSession] = [] }
        let box = Box()
        let coordinator = DeviceSessionCoordinator(makeSession: {
            let session = FakeSession()
            box.created.append(session)
            return session
        })
        return (coordinator, { box.created })
    }

    func testFirstAcquireCreatesSession() throws {
        let (coordinator, created) = makeCoordinator()
        let handle = try coordinator.acquire(.display)
        XCTAssertNotNil(handle)
        XCTAssertEqual(coordinator.createCount, 1)
        XCTAssertEqual(created().count, 1)
        XCTAssertTrue(coordinator.isHeld)
    }

    func testSecondAcquireReusesTheSameSession() throws {
        let (coordinator, created) = makeCoordinator()
        let a = try coordinator.acquire(.camera)
        let b = try coordinator.acquire(.display)
        XCTAssertTrue(a === b)                         // one shared session
        XCTAssertEqual(coordinator.createCount, 1)
        XCTAssertEqual(created().count, 1)
        XCTAssertTrue(coordinator.isShared)
    }

    func testReleaseLastHolderTearsDownAndStops() throws {
        let (coordinator, created) = makeCoordinator()
        try coordinator.acquire(.display)
        coordinator.release(.display)
        XCTAssertNil(coordinator.currentHandle)
        XCTAssertEqual(coordinator.teardownCount, 1)
        XCTAssertEqual(created().first?.stopCount, 1)  // session.stop() called
    }

    func testReleaseNonLastHolderKeepsSessionAlive() throws {
        let (coordinator, created) = makeCoordinator()
        try coordinator.acquire(.camera)
        try coordinator.acquire(.display)
        coordinator.release(.camera)                   // display still holds
        XCTAssertNotNil(coordinator.currentHandle)
        XCTAssertEqual(coordinator.teardownCount, 0)
        XCTAssertEqual(created().first?.stopCount, 0)  // not stopped
        XCTAssertEqual(coordinator.holders, [.display])
    }

    func testReacquireAfterTeardownCreatesFreshSession() throws {
        let (coordinator, created) = makeCoordinator()
        try coordinator.acquire(.display)
        coordinator.release(.display)
        try coordinator.acquire(.display)
        XCTAssertEqual(coordinator.createCount, 2)
        XCTAssertEqual(created().count, 2)
    }

    func testInvalidateDropsHandleButKeepsHolders() throws {
        let (coordinator, created) = makeCoordinator()
        try coordinator.acquire(.display)
        coordinator.invalidate()                       // session died underneath us
        XCTAssertNil(coordinator.currentHandle)
        XCTAssertEqual(coordinator.holders, [.display]) // holder retained
        try coordinator.acquire(.display)               // recreates for the existing holder
        XCTAssertEqual(coordinator.createCount, 2)
        XCTAssertEqual(created().last?.stopCount, 0)
    }

    func testAcquirePropagatesFactoryErrorAndLeavesStateClean() {
        struct Boom: Error {}
        let coordinator = DeviceSessionCoordinator(makeSession: { throw Boom() })
        XCTAssertThrowsError(try coordinator.acquire(.camera))
        XCTAssertFalse(coordinator.isHeld)              // holder not recorded on a failed create
        XCTAssertEqual(coordinator.createCount, 0)
        XCTAssertNil(coordinator.currentHandle)
    }
}
