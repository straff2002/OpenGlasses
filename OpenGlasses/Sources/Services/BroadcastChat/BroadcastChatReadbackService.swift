import Foundation

/// Broadcast chat read-aloud (Plan CI): while `BroadcastService` streams the glasses POV out,
/// this reads the channel's chat back to the wearer over TTS — their phone is in their pocket,
/// so spoken chat is the only way to actually host a stream from the glasses.
///
/// The service is a thin pump around the two pure cores: `TwitchChatClient` feeds parsed
/// messages into `ChatReadbackPolicy`; a timer drains the policy and hands each `SpokenChatItem`
/// to the injected `speak` closure. Assistant speech always wins — the pump simply doesn't pull
/// while `ttsBusy` reports true, so chat waits (and ages out via the policy's queue cap) rather
/// than pre-empting anything. The connection lives and dies with the broadcast session:
/// `AppState` calls `start`/`stop` from the broadcast toggle.
@MainActor
final class BroadcastChatReadbackService {

    /// Assistant TTS / conversation activity — chat never speaks over it.
    var ttsBusy: () -> Bool = { false }
    /// Realtime session (Gemini Live / OpenAI Realtime) — readback suppressed entirely.
    var realtimeSessionActive: () -> Bool = { false }
    /// Speaks one rendered chat line. Injected so tests capture instead of talking.
    var speak: (SpokenChatItem) async -> Void = { _ in }

    private(set) var policy: ChatReadbackPolicy
    private(set) var isRunning = false
    private let client: TwitchChatClient
    private let clock: () -> TimeInterval
    private var pumpTimer: Timer?
    private var pumping = false

    /// Seconds between drain attempts — coarse on purpose; chat is ambient, not urgent.
    static let pumpInterval: TimeInterval = 1.5

    init(client: TwitchChatClient? = nil,
         rules: ChatReadbackRules = ChatReadbackRules(),
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.client = client ?? TwitchChatClient()
        self.policy = ChatReadbackPolicy(rules: rules)
        self.clock = clock
        self.client.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
    }

    // MARK: - Lifecycle (broadcast-coupled)

    /// Start reading `channel`'s chat with the given tunables. Idempotent per broadcast.
    func start(channel: String, rules: ChatReadbackRules) {
        stop()
        policy = ChatReadbackPolicy(rules: rules)
        isRunning = true
        client.start(channel: channel)
        pumpTimer = Timer.scheduledTimer(withTimeInterval: Self.pumpInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pumpOnce() }
        }
        NSLog("[ChatReadback] started for #%@", channel)
    }

    func stop() {
        guard isRunning || pumpTimer != nil else { return }
        isRunning = false
        pumpTimer?.invalidate()
        pumpTimer = nil
        client.stop()
        policy.reset()
        NSLog("[ChatReadback] stopped")
    }

    // MARK: - Pump (tested)

    /// Feed one parsed message into the policy (also the test entry point).
    func handleMessage(_ message: ChatMessage) {
        guard isRunning else { return }
        policy.ingest(message, at: clock(), realtimeSessionActive: realtimeSessionActive())
    }

    /// Drain at most one item from the policy and speak it. Re-entrancy-guarded — speech takes
    /// seconds and the timer keeps firing.
    func pumpOnce() async {
        guard isRunning, !pumping else { return }
        guard let item = policy.nextItem(at: clock(), ttsBusy: ttsBusy(),
                                         realtimeSessionActive: realtimeSessionActive()) else { return }
        pumping = true
        await speak(item)
        pumping = false
    }
}
