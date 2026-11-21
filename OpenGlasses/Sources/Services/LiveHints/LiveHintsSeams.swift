import Foundation

// The carriers a live-hints session talks to (Plan MO P1), each behind a protocol so the session
// runs headless in tests with fakes. The production adapters are in `LiveHintsAdapters.swift`.

/// The wearer's documents, searched for a question (§5 step 1).
@MainActor
protocol HintDocumentSearch: AnyObject {
    /// The best passages for `question` in the session's scope, best first.
    func passages(for question: String, limit: Int) -> [HintPassage]
    /// The titles of the documents in the session's scope, for the recogniser's vocabulary (§8).
    func documentTitles() -> [String]
    /// The passages with what the session may do with them (§5a): whether the model may be asked,
    /// and which documents were searched. The session searches through this.
    func search(for question: String, limit: Int) -> HintSearchResult
}

extension HintDocumentSearch {
    /// The wearer's own documents: the model may be asked, as the session's settings say.
    func search(for question: String, limit: Int) -> HintSearchResult {
        HintSearchResult(passages: passages(for: question, limit: limit))
    }
}

/// One model call for a hint (§5 step 3), through the app's existing provider rules.
@MainActor
protocol HintModel: AnyObject {
    /// Whether a model can be asked now. False sends the session to the passage card alone.
    var isAvailable: Bool { get }
    /// A stateless, tool-free completion: nothing of it enters the conversation.
    func complete(system: String, user: String) async throws -> String
}

/// The lens (§6). The production one is the glasses' Display through the answer-card path.
@MainActor
protocol HintLensSink: AnyObject {
    /// A Display is connected and the HUD is on: hints go to the lens, not the ear.
    var isAvailable: Bool { get }
    /// Put the hint up, replacing any hint before it. False when the lens would not take it (the
    /// wearer dismissed the lens, a task card or a menu holds it).
    func present(_ hint: LiveHint) -> Bool
    /// Put the hint up again because the wearer asked ("show hints", a press on the Home card, a
    /// repeat): over a lens they dismissed, unlike `present`. False when the lens would not take it.
    func reshow(_ hint: LiveHint) -> Bool
    /// Take the hint `id` off the lens, if it is still the one there.
    func hide(hintID: Int)
}

/// The ear (§6): the assistant's voice, never through the phone speaker.
@MainActor
protocol HintEarSink: AnyObject {
    /// The output is the phone's own speaker (no headset, no glasses): a hint is for the screen only.
    var isPhoneSpeaker: Bool { get }
    /// Called with `isPhoneSpeaker` whenever the output route changes.
    var onRouteChanged: ((Bool) -> Void)? { get set }
    /// Called when the hint being spoken has finished (or was cut short).
    var onFinishedSpeaking: (() -> Void)? { get set }
    func sayHint(_ text: String)
    func stopSpeaking()
    /// A soft tick in the ear when a hint lands on the lens, for a wearer not looking at it.
    func chime()
}

/// Whether anyone near the phone is speaking, from the ungated mic level (§6).
@MainActor
protocol HintVoiceActivitySource: AnyObject {
    func start(onChange: @escaping (Bool) -> Void)
    func stop()
}

/// The phone's list of the last hints (§6), in memory only.
@MainActor
protocol HintPhoneListSink: AnyObject {
    func record(_ hint: LiveHint)
    /// The hint `id` changed (the model's answer replaced the passage card).
    func update(_ hint: LiveHint)
    func clear()
}

/// The session's captions (§1, §4).
@MainActor
protocol HintCaptionSource: AnyObject {
    /// Captions are running (whoever started them).
    var isActive: Bool { get }
    /// Newest first, as `AmbientCaptionService.captionHistory`.
    var captionHistory: [AmbientCaptionService.CaptionEntry] { get }
    /// The language the captions' text is written in (BCP-47 or a locale identifier).
    var languageCode: String { get }
    /// Called whenever `captionHistory` changes.
    var onHistoryChanged: (() -> Void)? { get set }
    /// The recogniser's extra vocabulary for this session (§8). Empty when none.
    var contextualStrings: [String] { get set }
    func start()
    func stop()
}

/// The session's clock and its tick.
@MainActor
protocol HintClock: AnyObject {
    var now: Date { get }
    /// Call `tick` every `interval` until the returned cancel is called.
    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void
}

/// The app-wide daily allowance (§1): not this plan's to meter, only to obey. Captions,
/// translation and every other accessibility feature never draw on it; only a live-hints session
/// charges it.
@MainActor
protocol HintSessionAllowance: AnyObject {
    /// Seconds left today, or nil for no limit.
    func remaining() -> TimeInterval?
    /// A running session used `seconds` more.
    func charge(_ seconds: TimeInterval)
}

/// No allowance: the default until the app-wide one exists.
@MainActor
final class UnlimitedHintAllowance: HintSessionAllowance {
    init() {}
    func remaining() -> TimeInterval? { nil }
    func charge(_ seconds: TimeInterval) {}
}
