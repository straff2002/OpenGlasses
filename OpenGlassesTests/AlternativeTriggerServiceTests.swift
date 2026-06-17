import XCTest
@testable import OpenGlasses

/// Tests for the alternative-trigger routing (Additional Capabilities #5): `handleEvent` applies the
/// per-trigger enabled check, the gate (confidence + debounce + suppression), and fires `onTrigger`.
/// Driven headlessly with an injected clock + enabled-set + synthetic events (no motion/audio).
@MainActor
final class AlternativeTriggerServiceTests: XCTestCase {

    private var now: TimeInterval = 0

    /// Build a service with an injected clock and a fixed enabled-set, capturing fired triggers.
    private func makeService(enabled: Set<AlternativeTrigger>,
                             debounce: TimeInterval = 2.0,
                             minimumConfidence: Double = 0.6) -> (AlternativeTriggerService, () -> [AlternativeTrigger]) {
        final class Box { var fired: [AlternativeTrigger] = [] }
        let box = Box()
        let service = AlternativeTriggerService(
            clock: { [weak self] in self?.now ?? 0 },
            isEnabled: { enabled.contains($0) },
            debounceInterval: debounce,
            minimumConfidence: minimumConfidence
        )
        service.onTrigger = { box.fired.append($0) }
        return (service, { box.fired })
    }

    func testEnabledTriggerFires() {
        let (service, fired) = makeService(enabled: [.shake])
        XCTAssertTrue(service.handleEvent(.shake))
        XCTAssertEqual(fired(), [.shake])
    }

    func testDisabledTriggerDoesNotFire() {
        let (service, fired) = makeService(enabled: [.shake])
        XCTAssertFalse(service.handleEvent(.acoustic))   // acoustic not enabled
        XCTAssertTrue(fired().isEmpty)
    }

    func testSuppressedDoesNotFire() {
        let (service, fired) = makeService(enabled: [.shake])
        service.isSuppressed = { true }
        XCTAssertFalse(service.handleEvent(.shake))
        XCTAssertTrue(fired().isEmpty)
    }

    func testLowConfidenceAcousticDoesNotFire() {
        let (service, fired) = makeService(enabled: [.acoustic], minimumConfidence: 0.6)
        XCTAssertFalse(service.handleEvent(.acoustic, confidence: 0.4))
        XCTAssertTrue(service.handleEvent(.acoustic, confidence: 0.8))
        XCTAssertEqual(fired(), [.acoustic])
    }

    func testDebounceCollapsesRapidEvents() {
        let (service, fired) = makeService(enabled: [.shake], debounce: 2.0)
        now = 0
        XCTAssertTrue(service.handleEvent(.shake))
        now = 1.0
        XCTAssertFalse(service.handleEvent(.shake))   // within debounce
        now = 2.5
        XCTAssertTrue(service.handleEvent(.shake))    // past debounce
        XCTAssertEqual(fired(), [.shake, .shake])
    }

    func testEachTriggerHasIndependentDebounce() {
        let (service, fired) = makeService(enabled: [.shake, .acoustic], debounce: 2.0)
        now = 0
        XCTAssertTrue(service.handleEvent(.shake))
        XCTAssertTrue(service.handleEvent(.acoustic))   // different gate → fires despite same instant
        XCTAssertEqual(fired(), [.shake, .acoustic])
    }

    func testHandleEventReturnsWhetherFired() {
        let (service, _) = makeService(enabled: [.volume])
        XCTAssertTrue(service.handleEvent(.volume))
        now = 0.5
        XCTAssertFalse(service.handleEvent(.volume))   // debounced
    }

    func testNothingEnabledMeansNoStart() {
        let service = AlternativeTriggerService(isEnabled: { _ in false })
        service.start()
        XCTAssertFalse(service.isRunning)   // no detectors started when nothing is enabled
    }
}
