import Foundation

/// Plan CB P1 — mid-session injection for the live voice modes.
///
/// The live sessions had exactly one image path (the throttled frame stream) and no text path,
/// so anything asynchronous — a deferred agent answer, a sharp still for `look_closely` — either
/// couldn't reach the model at all or had to be spoken *over* the session by TTS in a different
/// voice. These are the wire envelopes that give the session an inbound lane.
///
/// # The `completeTurn` contract (the easy thing to get wrong)
///
/// On the Gemini wire, `clientContent` without `turnComplete: true` only **appends to context** —
/// the model accepts the text and generates nothing. The failure is silent and presents as a
/// delivery bug: the user hears an acknowledgement, then nothing, re-asks, and every re-ask spawns
/// a duplicate task. The OpenAI Realtime wire has the same trap in different clothes:
/// `conversation.item.create` needs a following `response.create` to produce a turn.
///
/// Appending *without* completing is also a real mode, not a bug — the streamed video frames ride
/// exactly that way, and forcing a response per frame would be wrong. So the flag is explicit at
/// every call site, and the envelopes are pure value-in/value-out so tests pin the exact shapes.
enum LiveInjectionEnvelope {

    // MARK: - Gemini Live

    /// A user-role text turn. `completeTurn: true` makes the model respond to it; `false` quietly
    /// extends context (background notes for a *future* turn — never for content the user should
    /// hear about now).
    static func geminiText(_ text: String, completeTurn: Bool) -> [String: Any] {
        [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": text]]]
                ],
                "turnComplete": completeTurn,
            ]
        ]
    }

    /// The line a deliberate still carries, so the model knows the image is the photo it was asked
    /// about and not one more streamed frame.
    static let geminiStillInstruction = "This photo was just taken by the wearer's camera; answer about it."

    /// A deliberate full-quality still (Plan LT §6): `look_closely`, a pinned frame. A user-role
    /// `clientContent` turn carrying the image as `inlineData` and `geminiStillInstruction`, with
    /// `turnComplete: false` — it extends context and generates nothing, so the wearer's words (or
    /// the tool response that follows it) still lead. Before LT the still rode `realtimeInput.video`
    /// beside the throttled stream, with nothing to tell it apart from a frame; streamed frames stay
    /// there (`GeminiLiveService.sendVideoFrame`).
    static func geminiStill(base64JPEG: String) -> [String: Any] {
        [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [
                        ["inlineData": ["mimeType": "image/jpeg", "data": base64JPEG]],
                        ["text": geminiStillInstruction],
                    ]]
                ],
                "turnComplete": false,
            ]
        ]
    }

    // MARK: - OpenAI Realtime

    /// A user-role text item. Pair with ``realtimeResponseCreate()`` when the model should answer —
    /// `completeTurn` at this layer is expressed by whether the caller sends both messages.
    static func realtimeText(_ text: String) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ]
    }

    /// A user-role image item (optionally with a leading text part).
    static func realtimeImage(base64JPEG: String, prompt: String?) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_image", "image": base64JPEG]]
        if let prompt {
            content.insert(["type": "input_text", "text": prompt], at: 0)
        }
        return [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content,
            ],
        ]
    }

    /// The current OpenAI protocol's image item: `image_url` holds a data URI, where the beta (and
    /// ``realtimeImage(base64JPEG:prompt:)``, which beta-compatible servers still read) sent bare
    /// base64 as `image`.
    static func realtimeImageDataURI(base64JPEG: String, prompt: String?) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64JPEG)"]]
        if let prompt {
            content.insert(["type": "input_text", "text": prompt], at: 0)
        }
        return [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content,
            ],
        ]
    }

    /// The generation trigger the Realtime wire requires after `conversation.item.create`.
    /// Omitting this is the Realtime spelling of the append-only trap.
    ///
    /// Plan HY P3 — `toolsAllowed: false` is for **announcements**: a deferred result, an agent
    /// completion, a notification read aloud, the idle warning. Each is the app putting words in
    /// the model's mouth, and with tools allowed the model could answer one by calling another
    /// tool, whose result is announced in turn — a chain nobody asked for. `tool_choice: none`
    /// scopes the ban to this one response; the session's own `tool_choice: auto` is untouched.
    /// A wearer turn never comes through here: spoken turns are answered by the server's own VAD
    /// (`create_response: true`), and a tool result's follow-up is the model's chain to continue.
    static func realtimeResponseCreate(toolsAllowed: Bool = true) -> [String: Any] {
        guard !toolsAllowed else { return ["type": "response.create"] }
        return ["type": "response.create", "response": ["tool_choice": "none"]]
    }
}

/// What a live session must offer for others to put content in front of the model.
///
/// Conformed to by both session managers. Consumers reach it through
/// `AppState.activeLiveInjector`, which resolves to whichever session is actually live — the
/// session managers themselves are torn down and rebuilt per session, and holding one directly is
/// the wiring mistake Plan CB documents (a provider assigned to a dropped router "worked" and did
/// nothing forever).
@MainActor
protocol LiveSessionInjecting: AnyObject {
    /// Whether the session is connected enough for an injection to reach the model.
    var canInject: Bool { get }
    var supportsTextInjection: Bool { get }
    var supportsContextUpdates: Bool { get }
    var supportsSuppliedSpeech: Bool { get }
    var supportsVision: Bool { get }
    /// Validate media before a tool claims that delivery succeeded.
    func validateSharpImage(_ jpegData: Data) throws
    /// Whether someone is mid-turn right now — the model speaking, or the wearer. An injection
    /// sent into either collides: the Realtime wire has one active-response slot and refuses a
    /// second, and a turn arriving mid-utterance cuts the speaker off. Consulted through
    /// `LiveInjectionAdmission`, which bounds how long a result may wait for quiet.
    var isBusyForInjection: Bool { get }
    /// Which session this is, counting from the process's first.
    ///
    /// Plan FF P1/PR4. A sharp still is captured *for* a conversation, and capture takes seconds —
    /// long enough for a reconnect to have replaced the session underneath it. `canInject` cannot
    /// see that: it is true again the moment the *new* session is ready, so a still captured for
    /// the old one would sail into a conversation that never asked for it and be read as the answer
    /// to whatever is being said now. The identity makes the replacement observable, so the capture
    /// can be refused instead.
    var liveSessionIdentity: Int { get }
    /// Push a full-quality still into the model's view. It generates nothing by itself: on Gemini
    /// it is an append-only turn (`LiveInjectionEnvelope.geminiStill`), on Realtime an item with no
    /// `response.create` — see the envelope docs.
    func injectSharpImage(jpegData: Data)
    /// Put text in front of the model. `completeTurn: true` = the model responds now, in its own
    /// voice, inside the session — the whole point of the lane.
    func injectText(_ text: String, completeTurn: Bool)
    /// Put an announcement in front of the model: a turn it answers now, with tools off for that
    /// one response (Plan HY P3), so an announcement can never start a tool call.
    func injectAnnouncement(_ text: String)
    func updateAppContext(_ text: String, key: String)
    func speakSuppliedText(_ text: String)
}

extension LiveSessionInjecting {
    var supportsTextInjection: Bool { true }
    var supportsContextUpdates: Bool { supportsTextInjection }
    var supportsSuppliedSpeech: Bool { false }
    var supportsVision: Bool { true }
    func validateSharpImage(_ jpegData: Data) throws {}
    func updateAppContext(_ text: String, key: String) { injectText(text, completeTurn: false) }
    /// A conformer with no per-response tool switch delivers an announcement as an ordinary
    /// completed turn.
    func injectAnnouncement(_ text: String) { injectText(text, completeTurn: true) }
    func speakSuppliedText(_ text: String) {}
}

/// Notification delivery has different semantics from a silent job-context refresh.
/// Return false when the caller must speak locally; never silently replace audible delivery
/// with an append-only context update.
@MainActor
enum LiveAnnouncementDelivery {
    @discardableResult
    static func deliver(_ message: String, using injector: LiveSessionInjecting) -> Bool {
        guard injector.canInject else { return false }
        if injector.supportsSuppliedSpeech {
            injector.speakSuppliedText(message)
            return true
        }
        if injector.supportsTextInjection {
            // Plan HY P3: an announcement, so tools are off for the response it starts.
            injector.injectAnnouncement(AsyncDeliveryPhrasing.resultInstruction(question: nil, answer: message))
            return true
        }
        return false
    }
}
