import Foundation

/// Whether a private conversation is open right now, for the services that write, list, show or
/// send a conversation but cannot see `AppState` (Plan LU P1).
///
/// One process-wide flag behind a lock, in the style of `PolicyEnvelope` and `MedicalEgressGuard`:
/// the memory store, the activity trail, the turn traces, the camera's Photos sink, the bridges
/// and the recogniser are read from more than one isolation domain, and each asks the same
/// question — "what does my sink do now?" — through `rule(for:)`. With no private conversation open
/// every sink is `.keep`, so a service that asks changes nothing for an ordinary conversation.
///
/// **One writer.** `PrivateConversationController` sets the flag as its state changes, and nothing
/// else does; `PrivateConversationSinkGuardTests` fails on any other call to `setActive(_:)` in
/// `OpenGlasses/Sources`. Tests set it directly and put it back.
enum PrivateConversationGate {

    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var active = false

    /// A private conversation is open.
    static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Set by `PrivateConversationController` as a private conversation starts and ends.
    static func setActive(_ value: Bool) {
        lock.lock()
        active = value
        lock.unlock()
    }

    /// What `sink` does right now: its rule from `PrivateConversationPolicy` while a private
    /// conversation is open, and `.keep` otherwise.
    static func rule(for sink: ConversationSink) -> PrivateConversationPolicy.Rule {
        isActive ? PrivateConversationPolicy.rule(for: sink) : .keep
    }

    /// `sink` writes, lists or sends nothing right now.
    static func skips(_ sink: ConversationSink) -> Bool {
        rule(for: sink) == .skip
    }

    /// `sink` keeps its record without the content right now.
    static func keepsTitleOnly(_ sink: ConversationSink) -> Bool {
        rule(for: sink) == .titleOnly
    }

    /// The fixed line `sink` shows in place of content right now, or nil when it shows the content.
    static func placeholder(for sink: ConversationSink) -> String? {
        if case .placeholder(let line) = rule(for: sink) { return line }
        return nil
    }
}

/// Which recogniser a private conversation's questions use (Plan LU decision 4). Pure.
///
/// On-device where the locale supports it; where it doesn't, Apple's server recognition is used
/// (the explainer says so once). The chosen cloud vendors (Deepgram, OpenAI) are never used for a
/// private question: they are server recognition by a third party, and the wearer's choice of one
/// was made for ordinary conversations.
enum PrivateRecognitionPolicy {

    /// Whether the Apple recognition request must stay on the device.
    static func requiresOnDevice(isPrivate: Bool, localeSupportsOnDevice: Bool) -> Bool {
        isPrivate && localeSupportsOnDevice
    }

    /// Whether a cloud dictation vendor may take the turn.
    static func allowsCloudVendor(isPrivate: Bool) -> Bool {
        !isPrivate
    }
}
