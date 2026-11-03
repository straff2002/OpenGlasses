import Foundation

/// What an error is allowed to sound like (pure).
///
/// Live-traced failure: a model-load `DecodingError` reached TTS verbatim and the glasses
/// read out "keyNotFound(path: [language_model, model, layers, 15…" to the user. Spoken
/// errors must be human sentences; internals belong in the log.
enum SpokenErrorPolicy {
    /// A short, speakable reason. Uses the error's `localizedDescription` only when it
    /// looks like prose; otherwise a generic line.
    static func spokenReason(for error: Error) -> String {
        let description = error.localizedDescription
        return looksHuman(description) ? description : "Something went wrong on the device — check the debug log for details."
    }

    /// What a failed photo turn says, or nil when the wearer cancelled it (a barge-in is not a
    /// failure to announce). Which half failed decides the line: a camera that would not take the
    /// picture, or a picture no model could answer about. With model-switch narration on, the
    /// second names the cascade's real reason, as a spoken turn does.
    ///
    /// `gap` is the credential gap behind `error`, when known (Plan KL P0): "…couldn't get an
    /// answer about it — you're not signed in to ChatGPT."
    static func photoFailureLine(for error: Error, photoCaptured: Bool, narrateModelFailures: Bool,
                                 gap: CredentialGap? = nil) -> String? {
        if isCancellation(error) { return nil }
        guard photoCaptured else { return "Sorry, I couldn't take a photo. \(spokenReason(for: error))" }
        guard narrateModelFailures else {
            return "I took the photo, but couldn't get an answer about it. \(spokenReason(for: error))"
        }
        return "I took the photo, but couldn't get an answer about it — \(ModelSwitchNarrator.exhaustionReason(lastError: error, gap: gap))."
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Prose heuristic: short, no code-ish brackets/underscores/paths, has spaces.
    static func looksHuman(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 200, text.contains(" ") else { return false }
        let codey: [Character] = ["[", "]", "{", "}", "_", "(", ")"]
        let codeyCount = text.filter { codey.contains($0) }.count
        return codeyCount < 3 && !text.contains("keyNotFound") && !text.contains("Error Domain")
    }
}
