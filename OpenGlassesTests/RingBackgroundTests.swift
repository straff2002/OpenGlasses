import XCTest
@testable import OpenGlasses

/// Plan MZ follow-up — a clench with the phone in a pocket: the turn starts when the microphone
/// can open (foreground, or a live audio session from always-on listening), is refused with one
/// notification per cooldown when it can't, and an action that needs no microphone is unaffected.
/// Also the ring central's state restoration: the identifier, the launch check and which restored
/// ring is taken back.
@MainActor
final class RingBackgroundTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    private let pocket = RingMicrophoneFacts(appActive: false, audioLive: false)
    private let alwaysOn = RingMicrophoneFacts(appActive: false, audioLive: true)

    override func setUp() {
        super.setUp()
        RingTriggerRunner.backgroundGate.reset()
    }

    override func tearDown() {
        RingTriggerRunner.backgroundGate.reset()
        super.tearDown()
    }

    // MARK: - The gate

    func testTheForegroundAlwaysProceeds() {
        var gate = RingBackgroundListenGate()
        XCTAssertEqual(gate.decide(.startListening, facts: .foreground, now: t0), .proceed)
        XCTAssertEqual(gate.decide(.startListening, facts: RingMicrophoneFacts(appActive: true, audioLive: true),
                                   now: t0), .proceed)
        XCTAssertNil(gate.lastNotice)
    }

    func testALiveAudioSessionLetsABackgroundClenchTalk() {
        var gate = RingBackgroundListenGate()
        XCTAssertEqual(gate.decide(.startListening, facts: alwaysOn, now: t0), .proceed)
        XCTAssertEqual(gate.decide(.interruptAndListen, facts: alwaysOn, now: t0), .proceed)
        XCTAssertEqual(gate.decide(.askAgent, facts: alwaysOn, now: t0), .proceed)
    }

    func testEveryTurnStartIsRefusedInAPocketWithoutALiveSession() {
        for effect in [TempleEffect.startListening, .interruptAndListen, .askAgent] {
            var gate = RingBackgroundListenGate()
            XCTAssertEqual(gate.decide(effect, facts: pocket, now: t0), .refuse(notify: true), "\(effect)")
        }
    }

    func testAnActionWithoutTheMicrophoneIsUnaffected() {
        var gate = RingBackgroundListenGate()
        for effect in [TempleEffect.photoDescribe, .photoToCameraRoll, .toggleRecording(starting: true), .musicPlayPause,
                       .endConversation, .setMicMuted(true), .readDigest] {
            XCTAssertEqual(gate.decide(effect, facts: pocket, now: t0), .proceed, "\(effect)")
        }
        XCTAssertNil(gate.lastNotice)
    }

    func testOneNoticePerCooldown() {
        var gate = RingBackgroundListenGate()
        XCTAssertEqual(gate.decide(.startListening, facts: pocket, now: t0), .refuse(notify: true))
        XCTAssertEqual(gate.decide(.startListening, facts: pocket, now: t0.addingTimeInterval(3)),
                       .refuse(notify: false))
        let justBefore = t0.addingTimeInterval(RingBackgroundListenGate.noticeCooldown - 1)
        XCTAssertEqual(gate.decide(.startListening, facts: pocket, now: justBefore), .refuse(notify: false))
        XCTAssertEqual(gate.decide(.startListening, facts: pocket, now: t0.addingTimeInterval(
            RingBackgroundListenGate.noticeCooldown)), .refuse(notify: true), "and again once it has passed")
    }

    func testAClockSetBackDoesNotSilenceTheNotice() {
        var gate = RingBackgroundListenGate()
        _ = gate.decide(.startListening, facts: pocket, now: t0)
        XCTAssertEqual(gate.decide(.startListening, facts: pocket, now: t0.addingTimeInterval(-60)),
                       .refuse(notify: true))
    }

    // MARK: - The runner

    private final class FakeApp: TempleActionPerforming {
        var context = TempleContext(activity: .standby, glassesCameraReady: true)
        var effects: [TempleEffect] = []
        var earcons: [TempleEarcon] = []
        var lines: [String] = []
        func templeContext() -> TempleContext { context }
        func performTempleEffect(_ effect: TempleEffect) async { effects.append(effect) }
        func playTempleEarcon(_ earcon: TempleEarcon) { earcons.append(earcon) }
        func announceTempleLine(_ line: String) async { lines.append(line) }
    }

    func testAPocketClenchStartsNothingAndPostsOneNotice() async {
        let app = FakeApp()
        var notices = 0
        let first = await RingTriggerRunner.run(.startTalking, performer: app, microphone: pocket, now: t0,
                                                postNotice: { notices += 1 })
        XCTAssertEqual(first, .refusedInBackground(noticePosted: true))
        let second = await RingTriggerRunner.run(.startTalking, performer: app, microphone: pocket,
                                                 now: t0.addingTimeInterval(10), postNotice: { notices += 1 })
        XCTAssertEqual(second, .refusedInBackground(noticePosted: false))
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(app.effects, [], "no turn started that iOS would refuse")
        XCTAssertEqual(app.earcons, [], "no earcon: nothing can play")
        XCTAssertEqual(app.lines, [])
    }

    func testAClenchWithAlwaysOnListeningTalksFromThePocket() async {
        let app = FakeApp()
        let result = await RingTriggerRunner.run(.startTalking, performer: app, microphone: alwaysOn, now: t0,
                                                 postNotice: { XCTFail("no notice") })
        XCTAssertEqual(result, .carriedOut(.run(.startListening)))
        XCTAssertEqual(app.effects, [.startListening])
    }

    func testAPhotoClenchFromThePocketStillTakesThePhoto() async {
        let app = FakeApp()
        let result = await RingTriggerRunner.run(.photoDescribe, performer: app, microphone: pocket, now: t0,
                                                 postNotice: { XCTFail("no notice") })
        XCTAssertEqual(result, .carriedOut(.run(.photoDescribe)))
        XCTAssertEqual(app.effects, [.photoDescribe])
    }

    func testAnIgnoredClenchIsNotTakenForARefusal() async {
        let app = FakeApp()
        app.context = TempleContext(activity: .thinking, glassesCameraReady: true)
        let result = await RingTriggerRunner.run(.startTalking, performer: app, microphone: pocket, now: t0,
                                                 postNotice: { XCTFail("no notice") })
        XCTAssertEqual(result, .carriedOut(.ignored(.busy)))
    }

    // MARK: - The notice

    func testTheNoticeNamesTheSettingByItsOnScreenTitle() throws {
        XCTAssertFalse(RingBackgroundListenNotice.title.isEmpty)
        XCTAssertTrue(RingBackgroundListenNotice.body.contains("Listen for Wake Phrase"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent(
            "OpenGlasses/Sources/App/Views/SettingsScreens.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("title: \"Listen for Wake Phrase\""),
                      "the notice sends the wearer to a setting that must exist under that name")
    }

    // MARK: - State restoration

    func testTheRestoreIdentifierIsPinned() {
        XCTAssertEqual(RingRestoration.restoreIdentifier, "ring-central",
                       "iOS matches a relaunch to the central by this string; a new one strands the link")
    }

    func testALaunchForTheRingIsRecognised() {
        XCTAssertTrue(RingRestoration.launchedForRing(centrals: ["ring-central"]))
        XCTAssertTrue(RingRestoration.launchedForRing(centrals: ["other", "ring-central"]))
        XCTAssertFalse(RingRestoration.launchedForRing(centrals: ["other"]))
        XCTAssertFalse(RingRestoration.launchedForRing(centrals: []))
        XCTAssertFalse(RingRestoration.launchedForRing(centrals: nil))
    }

    func testOnlyThePairedRingIsTakenBack() {
        let paired = UUID(), other = UUID()
        XCTAssertEqual(RingRestoration.peripheralToAdopt(restored: [other, paired], paired: paired), paired)
        XCTAssertNil(RingRestoration.peripheralToAdopt(restored: [other], paired: paired))
        XCTAssertNil(RingRestoration.peripheralToAdopt(restored: [paired], paired: nil),
                     "no paired ring: nothing is taken back")
        XCTAssertNil(RingRestoration.peripheralToAdopt(restored: [], paired: paired))
    }

    func testTheTransportUsesTheIdentifierAndTakesTheRingBack() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "OpenGlasses/Sources/Services/Ring/RingBLETransport.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("CBCentralManagerOptionRestoreIdentifierKey: RingRestoration.restoreIdentifier"))
        XCTAssertTrue(source.contains("willRestoreState"))
        XCTAssertEqual(source.components(separatedBy: "CBCentralManager(").count - 1, 1,
                       "one central, the restorable one")
    }
}
