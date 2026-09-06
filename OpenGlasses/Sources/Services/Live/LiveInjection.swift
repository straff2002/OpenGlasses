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

    /// A full-quality still pushed into the model's view over the realtime video lane — the same
    /// channel as the throttled stream, minus the throttle and the quality loss. No turn semantics:
    /// generation is driven by whatever accompanies it (a tool response, or a `geminiText` with
    /// `completeTurn: true`).
    static func geminiImage(base64JPEG: String) -> [String: Any] {
        [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": base64JPEG,
                ]
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

    /// The generation trigger the Realtime wire requires after `conversation.item.create`.
    /// Omitting this is the Realtime spelling of the append-only trap.
    static func realtimeResponseCreate() -> [String: Any] {
        ["type": "response.create"]
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
    /// Whether someone is mid-turn right now — the model speaking, or the wearer. An injection
    /// sent into either collides: the Realtime wire has one active-response slot and refuses a
    /// second, and a turn arriving mid-utterance cuts the speaker off. Consulted through
    /// `LiveInjectionAdmission`, which bounds how long a result may wait for quiet.
    var isBusyForInjection: Bool { get }
    /// Push a full-quality still into the model's view (no turn semantics — see envelope docs).
    func injectSharpImage(jpegData: Data)
    /// Put text in front of the model. `completeTurn: true` = the model responds now, in its own
    /// voice, inside the session — the whole point of the lane.
    func injectText(_ text: String, completeTurn: Bool)
}
