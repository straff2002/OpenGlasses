import XCTest
@testable import OpenGlasses

/// End-to-end tests for the chat-readback pump against a fake socket (Plan CI P2): wire lines
/// in → spoken items out, with the broadcast lifecycle, PING→PONG, TTS-busy gating, and
/// realtime suppression all driven headlessly. Fresh instances throughout (house rule).
@MainActor
final class BroadcastChatReadbackServiceTests: XCTestCase {

    private final class FakeSocket: ChatSocketConnecting {
        var sent: [String] = []
        var onText: (@Sendable (String) -> Void)?
        var closeCount = 0
        func connect(url: URL,
                     onText: @escaping @Sendable (String) -> Void,
                     onClose: @escaping @Sendable () -> Void) {
            self.onText = onText
        }
        func send(_ text: String) { sent.append(text) }
        func close() { closeCount += 1 }
    }

    private var socket = FakeSocket()
    private var now: TimeInterval = 0
    private var spoken: [SpokenChatItem] = []
    private var busy = false
    private var realtime = false

    private func makeService() -> BroadcastChatReadbackService {
        let client = TwitchChatClient(makeSocket: { [socket] in socket })
        let service = BroadcastChatReadbackService(client: client, clock: { [weak self] in self?.now ?? 0 })
        service.ttsBusy = { [weak self] in self?.busy ?? false }
        service.realtimeSessionActive = { [weak self] in self?.realtime ?? false }
        service.speak = { [weak self] item in self?.spoken.append(item) }
        return service
    }

    override func setUp() {
        super.setUp()
        socket = FakeSocket()
        now = 0
        spoken = []
        busy = false
        realtime = false
    }

    func testStartSendsAnonymousLoginAndJoin() {
        let service = makeService()
        service.start(channel: "  #GlassesCaster ", rules: ChatReadbackRules())
        XCTAssertEqual(socket.sent.first, "CAP REQ :twitch.tv/tags twitch.tv/commands")
        XCTAssertTrue(socket.sent.contains { $0.hasPrefix("NICK justinfan") })
        XCTAssertTrue(socket.sent.contains("JOIN #glassescaster"))   // trimmed + lowercased
        service.stop()
    }

    func testWireLineBecomesSpokenItem() async {
        let service = makeService()
        var rules = ChatReadbackRules()
        rules.streamerHandle = "glassescaster"
        service.start(channel: "glassescaster", rules: rules)
        socket.onText?("@display-name=Sam :sam!sam@sam.tmi.twitch.tv PRIVMSG #glassescaster :great view\r\n")
        for _ in 0..<10 { await Task.yield() }   // let the client's main-actor hop run
        now = 2
        await service.pumpOnce()
        XCTAssertEqual(spoken.map(\.text), ["Sam says: great view"])
        service.stop()
    }

    func testPingAnsweredWithPong() async {
        let service = makeService()
        service.start(channel: "c", rules: ChatReadbackRules())
        socket.onText?("PING :tmi.twitch.tv")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(socket.sent.contains("PONG :tmi.twitch.tv"))
        service.stop()
    }

    func testTTSBusyDefersSpeech() async {
        let service = makeService()
        service.start(channel: "c", rules: ChatReadbackRules())
        service.handleMessage(ChatMessage(user: "Sam", login: "sam", text: "hi", badges: [],
                                          isAction: false, textWithoutEmotes: "hi"))
        busy = true
        await service.pumpOnce()
        XCTAssertTrue(spoken.isEmpty)
        busy = false
        now = 1
        await service.pumpOnce()
        XCTAssertEqual(spoken.count, 1)
        service.stop()
    }

    func testRealtimeSessionSuppressesReadback() async {
        let service = makeService()
        service.start(channel: "c", rules: ChatReadbackRules())
        service.handleMessage(ChatMessage(user: "Sam", login: "sam", text: "hi", badges: [],
                                          isAction: false, textWithoutEmotes: "hi"))
        realtime = true
        await service.pumpOnce()
        realtime = false
        await service.pumpOnce()   // queue was flushed while suppressed
        XCTAssertTrue(spoken.isEmpty)
        service.stop()
    }

    func testStopClosesSocketAndDropsQueue() async {
        let service = makeService()
        service.start(channel: "c", rules: ChatReadbackRules())
        service.handleMessage(ChatMessage(user: "Sam", login: "sam", text: "hi", badges: [],
                                          isAction: false, textWithoutEmotes: "hi"))
        service.stop()
        XCTAssertGreaterThanOrEqual(socket.closeCount, 1)
        await service.pumpOnce()   // no-op after stop
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertFalse(service.isRunning)
    }

    func testMessagesIgnoredWhenNotRunning() {
        let service = makeService()
        service.handleMessage(ChatMessage(user: "Sam", login: "sam", text: "hi", badges: [],
                                          isAction: false, textWithoutEmotes: "hi"))
        XCTAssertTrue(service.policy.queue.isEmpty)
    }
}
