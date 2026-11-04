import Foundation

/// Why a cloud voice turned a request away, when the wearer is the only one who can fix it.
///
/// A network blip or a server error falls through to the next engine and is nobody's business.
/// These are different: they repeat on every reply until the wearer tops up, corrects the key or
/// picks another voice, and until now the only sign was a worse voice with no explanation (support report,
/// 2026-10-05 — the wearer went looking for a voice setting to undo a change they never made).
enum CloudVoiceRejection: String, Equatable, CaseIterable {
    /// The account has no credit left. ElevenLabs sends this as a 401 whose body names
    /// `quota_exceeded`, so the status alone cannot tell it from a bad key; OpenAI sends a 429
    /// naming `insufficient_quota`, which the status alone would take for a rate limit.
    case outOfCredit
    /// The voice chosen for the key was refused: an ElevenLabs voice that does not exist or that the
    /// account may not use, or a 402 from a plan that will not pay for it. Not latched, because the
    /// wearer fixes it by picking another voice. The raw value is the one this case has always had,
    /// so an episode stored under it still counts as said.
    case refused
    /// The vendor did not accept the key itself (Plan KL P3): a 401 or 403 the body does not
    /// explain otherwise, or Gemini's `API_KEY_INVALID` 400. Asking again with the same key can
    /// only fail, so the voice is latched off for that key until it changes (`CloudVoiceKeyLatch`).
    case keyNotAccepted
    /// The vendor has withdrawn the voice model the app asks for. No key or top-up brings it back,
    /// so a wearer who was told "check the key" would be sent the wrong way (Plan KB).
    case modelUnavailable

    /// What an out-of-credit body says, lower-cased, for each cloud voice. A short list on
    /// purpose: a phrase that also turns up in an ordinary error would latch the voice off.
    static let outOfCreditMarkers = [
        "quota_exceeded",              // ElevenLabs
        "insufficient_quota",          // OpenAI
        "used all available credits",  // xAI
        "spending limit"               // xAI
    ]

    /// What a refused-key body says, lower-cased, when the status alone does not: Gemini refuses a
    /// bad key with a 400, the status every malformed request gets.
    static let keyNotAcceptedMarkers = [
        "api_key_invalid"              // Gemini
    ]

    /// What a refused-voice body says, lower-cased, whatever the status. Read before the key's
    /// status, so a bad voice id can never latch a good key off: the wearer fixes it by picking
    /// another voice, and the key must still be tried when they do.
    static let voiceRefusedMarkers = [
        "voice_not_found"              // ElevenLabs
    ]

    /// What a withdrawn model's body says, lower-cased, whatever the status: OpenAI answers a
    /// removed model with a 404, sometimes a 400, and a 403 for a project without access.
    static let modelUnavailableMarkers = [
        "model_not_found"              // OpenAI
    ]

    /// OpenAI's wording when the body has no code. Each counts only after "the model", because a
    /// bad voice id says "does not exist" too and that one the wearer can fix.
    static let modelUnavailablePhrases = [
        "does not exist",
        "has been deprecated"
    ]

    private static func namesAWithdrawnModel(_ lowered: String) -> Bool {
        if modelUnavailableMarkers.contains(where: { lowered.contains($0) }) { return true }
        guard let model = lowered.range(of: "the model") else { return false }
        let rest = lowered[model.upperBound...]
        return modelUnavailablePhrases.contains(where: { rest.contains($0) })
    }

    static func classify(statusCode: Int, body: String) -> CloudVoiceRejection? {
        let lowered = body.lowercased()
        if outOfCreditMarkers.contains(where: { lowered.contains($0) }) { return .outOfCredit }
        if namesAWithdrawnModel(lowered) { return .modelUnavailable }
        if voiceRefusedMarkers.contains(where: { lowered.contains($0) }) { return .refused }
        if keyNotAcceptedMarkers.contains(where: { lowered.contains($0) }) { return .keyNotAccepted }
        switch statusCode {
        case 401, 403: return .keyNotAccepted
        case 402: return .refused
        default: return nil
        }
    }
}

/// A rejection and the cloud voice that sent it: what the wearer is told, naming the vendor.
struct CloudVoiceNotice: Equatable {
    let engine: TTSEngine
    let rejection: CloudVoiceRejection
    /// The engine taking over is another cloud voice (Auto with more than one set up), so saying
    /// "the built-in voice" would be untrue.
    var nextIsCloud = false

    private var vendor: String { engine.vendorName ?? "The cloud voice" }

    /// Where the OpenAI, xAI and Gemini voices' keys live: on the saved model, not beside the
    /// ElevenLabs key, so "check the key" sends the wearer there.
    static var modelKeysPath: String { SettingsHub.path(to: .intelligence) }

    /// Said once, after the reply it interrupted. The path is spoken as words: a wearer who is not
    /// looking at the phone has to be able to find it later from memory.
    ///
    /// The ElevenLabs lines are the ones this notice has always said, kept as their own strings so
    /// their translations still apply; the other vendors share one wording with the name filled in.
    var spokenLine: String {
        if nextIsCloud {
            switch rejection {
            case .outOfCredit:
                return String(localized: "By the way, your \(vendor) credit has run out, so I'm using another voice. You can change voices in the app's Settings, under Connections, then Services and Integrations.")
            case .refused:
                return String(localized: "By the way, \(vendor) refused the voice request, so I'm using another voice. Check the key and voice in the app's Settings, under Connections, then Services and Integrations.")
            case .modelUnavailable:
                return String(localized: "By the way, \(vendor) no longer offers the voice model I was using, so I'm using another voice. You can choose another voice in the app's Settings, under Connections, then Services and Integrations.")
            case .keyNotAccepted where engine == .elevenLabs:
                return String(localized: "By the way, ElevenLabs didn't accept the key, so I'm using another voice. Check the key in the app's Settings, under Connections, then Services and Integrations.")
            case .keyNotAccepted:
                return String(localized: "By the way, \(vendor) didn't accept the key, so I'm using another voice. Check the key on your \(vendor) model in the app's Settings, under \(Self.modelKeysPath).")
            }
        }
        switch (engine, rejection) {
        case (.elevenLabs, .keyNotAccepted):
            return String(localized: "By the way, ElevenLabs didn't accept the key, so I'm using the built-in voice. Check the key in the app's Settings, under Connections, then Services and Integrations.")
        case (_, .keyNotAccepted):
            return String(localized: "By the way, \(vendor) didn't accept the key, so I'm using the built-in voice. Check the key on your \(vendor) model in the app's Settings, under \(Self.modelKeysPath).")
        case (.elevenLabs, .outOfCredit):
            return String(localized: "By the way, your ElevenLabs credit has run out, so I'm using the built-in voice. You can change voices in the app's Settings, under Connections, then Services and Integrations.")
        case (.elevenLabs, .refused):
            return String(localized: "By the way, ElevenLabs refused the voice request, so I'm using the built-in voice. Check the key and voice in the app's Settings, under Connections, then Services and Integrations.")
        case (_, .outOfCredit):
            return String(localized: "By the way, your \(vendor) credit has run out, so I'm using the built-in voice. You can change voices in the app's Settings, under Connections, then Services and Integrations.")
        case (_, .refused):
            return String(localized: "By the way, \(vendor) refused the voice request, so I'm using the built-in voice. Check the key and voice in the app's Settings, under Connections, then Services and Integrations.")
        case (_, .modelUnavailable):
            return String(localized: "By the way, \(vendor) no longer offers the voice model I was using, so I'm using the built-in voice. You can choose another voice in the app's Settings, under Connections, then Services and Integrations.")
        }
    }

    /// The same news for the screen.
    var banner: String {
        if nextIsCloud {
            switch rejection {
            case .outOfCredit:
                return String(localized: "\(vendor) is out of credit, so replies use another voice. Change voices in Settings › Connections › Services & Integrations.")
            case .refused:
                return String(localized: "\(vendor) refused the voice request, so replies use another voice. Check the key and voice in Settings › Connections › Services & Integrations.")
            case .modelUnavailable:
                return String(localized: "\(vendor) no longer offers the voice model in use, so replies use another voice. Choose another voice in Settings › Connections › Services & Integrations.")
            case .keyNotAccepted where engine == .elevenLabs:
                return String(localized: "ElevenLabs didn't accept the key, so replies use another voice. Check the key in Settings › Connections › Services & Integrations.")
            case .keyNotAccepted:
                return String(localized: "\(vendor) didn't accept the key, so replies use another voice. Check the key on your \(vendor) model in Settings › \(Self.modelKeysPath).")
            }
        }
        switch (engine, rejection) {
        case (.elevenLabs, .keyNotAccepted):
            return String(localized: "ElevenLabs didn't accept the key, so replies use the built-in voice. Check the key in Settings › Connections › Services & Integrations.")
        case (_, .keyNotAccepted):
            return String(localized: "\(vendor) didn't accept the key, so replies use the built-in voice. Check the key on your \(vendor) model in Settings › \(Self.modelKeysPath).")
        case (.elevenLabs, .outOfCredit):
            return String(localized: "ElevenLabs is out of credit, so replies use the built-in voice. Change voices in Settings › Connections › Services & Integrations.")
        case (.elevenLabs, .refused):
            return String(localized: "ElevenLabs refused the voice request, so replies use the built-in voice. Check the key and voice in Settings › Connections › Services & Integrations.")
        case (_, .outOfCredit):
            return String(localized: "\(vendor) is out of credit, so replies use the built-in voice. Change voices in Settings › Connections › Services & Integrations.")
        case (_, .refused):
            return String(localized: "\(vendor) refused the voice request, so replies use the built-in voice. Check the key and voice in Settings › Connections › Services & Integrations.")
        case (_, .modelUnavailable):
            return String(localized: "\(vendor) no longer offers the voice model in use, so replies use the built-in voice. Choose another voice in Settings › Connections › Services & Integrations.")
        }
    }

    /// What the announcer remembers. ElevenLabs keeps the bare reason it has always stored, so an
    /// episode announced before the other cloud voices existed is not announced a second time.
    var announcementToken: String {
        engine == .elevenLabs ? rejection.rawValue : "\(engine.rawValue).\(rejection.rawValue)"
    }

    /// The cloud voice an announcement token belongs to.
    static func engine(ofToken token: String) -> TTSEngine? {
        guard let dot = token.firstIndex(of: ".") else {
            return CloudVoiceRejection(rawValue: token) != nil ? .elevenLabs : nil
        }
        return TTSEngine(rawValue: String(token[..<dot]))
    }
}

/// When a rejection is worth saying aloud. Once per episode, not once per launch: a wearer who has
/// decided to live with the built-in voice should not be told again every morning. The episode ends
/// when that cloud voice speaks again or the wearer changes its key or voice.
///
/// Each cloud voice has its own episode. With Auto and two cloud voices set up, one refusing every
/// reply and the next speaking, the second's success must not make the first's refusal news again.
struct CloudVoiceFallbackAnnouncer {
    static let defaultsKey = "cloudVoiceFallbackAnnounced"

    var defaults: UserDefaults = .standard

    /// The tokens already said. Read from a list, or from the single string stored before there
    /// was more than one cloud voice.
    private var announced: [String] {
        if let list = defaults.stringArray(forKey: Self.defaultsKey) { return list }
        return defaults.string(forKey: Self.defaultsKey).map { [$0] } ?? []
    }

    private func store(_ tokens: [String]) {
        if tokens.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(tokens, forKey: Self.defaultsKey)
        }
    }

    /// The line to add to this utterance, or nil when this rejection has been said already or the
    /// utterance is not one to append to.
    ///
    /// - Parameter plainReply: an ordinary reply at neutral urgency. An alert or a warning is
    ///   never lengthened with housekeeping, and stays unannounced until the next ordinary reply.
    mutating func lineToSpeak(for notice: CloudVoiceNotice, plainReply: Bool) -> String? {
        let token = notice.announcementToken
        let said = announced
        guard plainReply, !said.contains(token) else { return nil }
        // One reason per cloud voice: a different reason from the same vendor is news.
        store(said.filter { CloudVoiceNotice.engine(ofToken: $0) != notice.engine } + [token])
        return notice.spokenLine
    }

    /// That cloud voice is working, or its key or voice has changed: its next rejection is news.
    /// With no engine, every cloud voice's episode ends.
    func episodeEnded(for engine: TTSEngine? = nil) {
        guard let engine else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let said = announced
        let kept = said.filter { CloudVoiceNotice.engine(ofToken: $0) != engine }
        if kept.count != said.count { store(kept) }
    }
}

/// The cloud voices whose key was refused this process, each with the key it refused (Plan KL P3).
///
/// A refused key used to be asked again on every line: every utterance paid a round trip for the
/// refusal before the next engine spoke, and every visit to the voice settings fetched a list the
/// key could not have. Now the first refusal latches that voice off for that key. A latched voice is
/// skipped like one out of credit, with no request, its voice list is not fetched, and Settings says
/// the vendor didn't accept the key.
///
/// Kept per voice and per key: the latch holds only a fingerprint of the key it refused, so a key
/// that changes anywhere (the ElevenLabs field, a saved model's key, a refreshed xAI sign-in) is
/// tried again without anything having to clear it. The fingerprint is the key's `hashValue`, which
/// is seeded per process, and the latch is never persisted: no key material is stored or logged,
/// the same arrangement as `CredentialNoticeLatch`.
struct CloudVoiceKeyLatch: Equatable {
    private var refused: [TTSEngine: Int] = [:]

    /// A key as the voice sends it. An empty key has nothing to refuse and is never latched.
    private static func fingerprint(_ key: String) -> Int? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.hashValue
    }

    /// Whether `key` is the one `engine` refused.
    func isLatched(_ engine: TTSEngine, key: String) -> Bool {
        guard let mark = Self.fingerprint(key) else { return false }
        return refused[engine] == mark
    }

    /// `engine` refused `key`. Returns true when a different key from the same voice was latched
    /// before, so its refusal is news again rather than an episode already told.
    @discardableResult
    mutating func latch(_ engine: TTSEngine, key: String) -> Bool {
        guard let mark = Self.fingerprint(key) else { return false }
        let previous = refused.updateValue(mark, forKey: engine)
        return previous != nil && previous != mark
    }

    /// The wearer changed that voice's key: try it again.
    mutating func clear(_ engine: TTSEngine) {
        refused.removeValue(forKey: engine)
    }

    /// The voices with a latched key, whichever key it was.
    var engines: Set<TTSEngine> { Set(refused.keys) }

    /// The voice row's line while the latch holds, naming the vendor.
    static func settingsLine(for engine: TTSEngine) -> String {
        let vendor = engine.vendorName ?? String(localized: "The cloud voice")
        return String(localized: "\(vendor) didn't accept the key")
    }
}

/// The voice list was not fetched, or was refused, because the vendor does not accept the key
/// (Plan KL P3). The picker shows the latch's own line instead of an error, so this describes itself
/// the same way.
struct CloudVoiceKeyNotAccepted: LocalizedError, Equatable {
    let engine: TTSEngine

    var errorDescription: String? { CloudVoiceKeyLatch.settingsLine(for: engine) }
}
