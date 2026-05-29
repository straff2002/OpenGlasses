import XCTest
@testable import OpenGlasses

/// Tests for AgentNotificationQueue: staleness logic, priority ordering, queue management.
@MainActor
final class AgentNotificationQueueTests: XCTestCase {

    // MARK: - Staleness

    func testLowPriorityStaleAfter30Minutes() {
        let notification = AgentNotificationQueue.QueuedNotification(
            id: "1",
            message: "Weather update",
            source: "weather_check",
            personaId: nil,
            personaName: nil,
            createdAt: Date().addingTimeInterval(-1801), // 30min + 1s ago
            priority: .low
        )
        XCTAssertTrue(notification.isStale, "Low priority should be stale after 30 minutes")
    }

    func testLowPriorityFreshWithin30Minutes() {
        let notification = AgentNotificationQueue.QueuedNotification(
            id: "2",
            message: "Weather update",
            source: "weather_check",
            personaId: nil,
            personaName: nil,
            createdAt: Date().addingTimeInterval(-1799), // 30min - 1s ago
            priority: .low
        )
        XCTAssertFalse(notification.isStale)
    }

    func testMediumPriorityStaleAfter2Hours() {
        let notification = AgentNotificationQueue.QueuedNotification(
            id: "3",
            message: "Calendar reminder",
            source: "calendar",
            personaId: nil,
            personaName: nil,
            createdAt: Date().addingTimeInterval(-7201), // 2h + 1s ago
            priority: .medium
        )
        XCTAssertTrue(notification.isStale, "Medium priority should be stale after 2 hours")
    }

    func testMediumPriorityFreshWithin2Hours() {
        let notification = AgentNotificationQueue.QueuedNotification(
            id: "4",
            message: "Calendar reminder",
            source: "calendar",
            personaId: nil,
            personaName: nil,
            createdAt: Date().addingTimeInterval(-7199),
            priority: .medium
        )
        XCTAssertFalse(notification.isStale)
    }

    func testHighPriorityNeverStale() {
        let notification = AgentNotificationQueue.QueuedNotification(
            id: "5",
            message: "Security alert",
            source: "security",
            personaId: nil,
            personaName: nil,
            createdAt: Date().addingTimeInterval(-86400), // 24h ago
            priority: .high
        )
        XCTAssertFalse(notification.isStale, "High priority should never be stale")
    }

    // MARK: - Priority Raw Values

    func testPriorityRawValues() {
        XCTAssertEqual(AgentNotificationQueue.QueuedNotification.Priority.low.rawValue, "low")
        XCTAssertEqual(AgentNotificationQueue.QueuedNotification.Priority.medium.rawValue, "medium")
        XCTAssertEqual(AgentNotificationQueue.QueuedNotification.Priority.high.rawValue, "high")
    }

    // MARK: - Codable Round-Trip

    func testNotificationCodableRoundTrip() throws {
        let original = AgentNotificationQueue.QueuedNotification(
            id: "rt-1",
            message: "Test notification",
            source: "test_source",
            personaId: "claude",
            personaName: "Claude",
            createdAt: Date(),
            priority: .medium
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentNotificationQueue.QueuedNotification.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.message, original.message)
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.personaId, original.personaId)
        XCTAssertEqual(decoded.personaName, original.personaName)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertFalse(decoded.delivered)
    }

    // MARK: - Staleness Boundary

    func testStalenessJustInsideBoundary() {
        // isStale reads the wall clock (age > 1800), so a value at exactly -1800 races just over the
        // threshold by the time it's evaluated. Use a value safely inside the 30-minute window to
        // deterministically verify a recent low-priority notification is NOT stale.
        let notification = AgentNotificationQueue.QueuedNotification(
            id: "boundary",
            message: "Test",
            source: "test",
            personaId: nil,
            personaName: nil,
            createdAt: Date().addingTimeInterval(-1799), // just under 30 min
            priority: .low
        )
        XCTAssertFalse(notification.isStale)
    }
}
