import Foundation
import NaturalLanguage

/// The two languages of a spoken interpreter session.
///
/// The interpreter is a cloud live session that listens to the wearer and the person in front of
/// them and speaks each line in the other language: the wearer's language to the glasses, the other
/// person's from the phone's loudspeaker. Unlike `live_translate` it sends the room's audio to
/// Google, so everything here is opt-in and `InterpreterGate` is asked before a session starts.
struct InterpreterPair: Equatable, Sendable {
    let wearer: String
    let other: String

    private static func language(_ code: String) -> String {
        String(code.replacingOccurrences(of: "_", with: "-").lowercased()
            .split(separator: "-", maxSplits: 1).first ?? "")
    }

    /// Two languages to go between. A pair of one language has nothing to translate.
    var isUsable: Bool {
        let a = Self.language(wearer), b = Self.language(other)
        return !a.isEmpty && !b.isEmpty && a != b
    }

    /// The pair for a spoken request, which may name the language or give its code. No request
    /// falls back to the language set in Settings; one the curated list doesn't hold is `nil`.
    static func resolving(requested: String?, wearer: String, fallbackOther: String) -> InterpreterPair? {
        let asked = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !asked.isEmpty else { return InterpreterPair(wearer: wearer, other: fallbackOther) }
        let match = TranslationLanguages.curated.first {
            $0.code == language(asked) || $0.name.lowercased() == asked
        }
        return match.map { InterpreterPair(wearer: wearer, other: $0.code) }
    }
}

/// Where a line is played. The ear is the private one, and the default for anything undecided.
enum InterpreterOutput: Equatable, Sendable {
    case ear
    case speaker
}

/// Whether an interpreter session may start.
///
/// Off by default: the audio of someone who never chose the app goes to the cloud. `live_translate`
/// stays the on-device default and is not gated by any of this.
enum InterpreterGate {

    enum Refusal: String, Equatable {
        case pinnedOff, medicalMode, localOnly, switchedOff, needsGeminiKey, needsGeminiLive, sameLanguage

        /// Said to the wearer, so each one says what stands in the way.
        var spokenReason: String {
            switch self {
            case .pinnedOff:
                return String(localized: "Your organisation has turned the spoken interpreter off.")
            case .medicalMode:
                return String(localized: "The spoken interpreter sends audio to the cloud, so it can't run in HIPAA mode.")
            case .localOnly:
                return String(localized: "The spoken interpreter sends audio to the cloud, so it can't run while the app is set to local models only.")
            case .switchedOff:
                return String(localized: "The spoken interpreter is off. Turn it on in Settings, under Translation.")
            case .needsGeminiKey:
                return String(localized: "The spoken interpreter needs a Gemini API key. Add one in AI Models.")
            case .needsGeminiLive:
                return String(localized: "The spoken interpreter only runs on Gemini Live.")
            case .sameLanguage:
                return String(localized: "The spoken interpreter needs two different languages.")
            }
        }
    }

    struct Inputs: Equatable {
        var optedIn: Bool
        var orgPinnedOff: Bool
        var hipaaMode: Bool
        var localOnly: Bool
        var geminiConfigured: Bool
        var usesGeminiLive: Bool
        var pairIsUsable: Bool
    }

    /// `nil` means it may start. An organisation's pin and the medical gates come first: they are
    /// not things the wearer can change by following the reason.
    static func refusal(_ inputs: Inputs) -> Refusal? {
        if inputs.orgPinnedOff { return .pinnedOff }
        if inputs.hipaaMode { return .medicalMode }
        if inputs.localOnly { return .localOnly }
        if !inputs.optedIn { return .switchedOff }
        if !inputs.geminiConfigured { return .needsGeminiKey }
        if !inputs.usesGeminiLive { return .needsGeminiLive }
        if !inputs.pairIsUsable { return .sameLanguage }
        return nil
    }
}

/// Reads whose language a line of translation is in, and so who it is for: a line in the wearer's
/// language came from the other person and belongs in the ear, and the reverse from the speaker.
///
/// A different script settles it within a couple of letters. Two languages in the same script need
/// `NLLanguageRecognizer`, constrained to the pair, and enough text for it to mean something, so a
/// short line reads as nothing at all and stays private.
enum InterpreterLanguageReader {

    /// Letters of a shared alphabet needed before the recogniser is asked.
    static let minimumAlphabeticLetters = 10
    /// Characters of a shared logographic script needed before the recogniser is asked.
    static let minimumLogographicLetters = 4
    static let minimumConfidence = 0.75

    private enum Script: Hashable {
        case latin, han, kana, hangul, devanagari, thai, cyrillic, arabic, hebrew, greek
    }

    private static func script(of scalar: Unicode.Scalar) -> Script? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: return .latin
        case 0x0370...0x03FF: return .greek
        case 0x0400...0x052F: return .cyrillic
        case 0x0590...0x05FF: return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F: return .arabic
        case 0x0900...0x097F: return .devanagari
        case 0x0E00...0x0E7F: return .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x3040...0x30FF: return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FFFF: return .han
        default: return nil
        }
    }

    private static func baseLanguage(_ code: String) -> String {
        String(code.replacingOccurrences(of: "_", with: "-").lowercased()
            .split(separator: "-", maxSplits: 1).first ?? "")
    }

    private static func scripts(of code: String) -> Set<Script> {
        switch baseLanguage(code) {
        case "zh": return [.han]
        case "ja": return [.kana, .han]
        case "ko": return [.hangul]
        case "hi", "mr", "ne": return [.devanagari]
        case "th": return [.thai]
        case "ru", "uk", "bg", "sr": return [.cyrillic]
        case "ar", "fa", "ur": return [.arabic]
        case "he": return [.hebrew]
        case "el": return [.greek]
        default: return [.latin]
        }
    }

    private static func recognizerLanguages(of code: String) -> [NLLanguage] {
        switch baseLanguage(code) {
        case "zh": return [.simplifiedChinese, .traditionalChinese]
        case "no", "nb": return [.norwegian]
        default: return [NLLanguage(rawValue: baseLanguage(code))]
        }
    }

    /// Who `text` is for, or `nil` while it could be either.
    static func output(for text: String, pair: InterpreterPair) -> InterpreterOutput? {
        var letters: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            if let script = script(of: scalar) { letters[script, default: 0] += 1 }
        }
        let total = letters.values.reduce(0, +)
        guard total > 0 else { return nil }

        let wearerScripts = scripts(of: pair.wearer), otherScripts = scripts(of: pair.other)
        let wearerOnly = wearerScripts.subtracting(otherScripts)
        let otherOnly = otherScripts.subtracting(wearerScripts)
        func count(_ scripts: Set<Script>) -> Int { scripts.reduce(0) { $0 + (letters[$1] ?? 0) } }

        /// A script only one side writes in. Latin needs more than the rest, because names and
        /// brands stay in Latin inside a line of any other script.
        func decided(_ scripts: Set<Script>) -> Bool {
            let seen = count(scripts)
            if scripts == [.latin] {
                return seen >= 4 && Double(seen) / Double(total) >= 0.9
            }
            return seen >= 2 && Double(seen) / Double(total) >= 0.3
        }
        let wearerDecided = decided(wearerOnly), otherDecided = decided(otherOnly)
        switch (wearerDecided, otherDecided) {
        case (true, false): return .ear
        case (false, true): return .speaker
        case (true, true): return count(wearerOnly) >= count(otherOnly) ? .ear : .speaker
        case (false, false): break
        }
        // Apart from Japanese and Chinese, a pair that shares nothing has only this one line to
        // go on, and it matched neither.
        let shared = wearerScripts.intersection(otherScripts)
        guard !shared.isEmpty else { return nil }

        let logographic = shared.contains(.han)
        guard count(shared) >= (logographic ? minimumLogographicLetters : minimumAlphabeticLetters) else {
            return nil
        }

        let wearerLanguages = recognizerLanguages(of: pair.wearer)
        let otherLanguages = recognizerLanguages(of: pair.other)
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = wearerLanguages + otherLanguages
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: wearerLanguages.count + otherLanguages.count)
        let wearer = wearerLanguages.reduce(0) { $0 + (hypotheses[$1] ?? 0) }
        let other = otherLanguages.reduce(0) { $0 + (hypotheses[$1] ?? 0) }
        if wearer >= minimumConfidence, wearer > other { return .ear }
        if other >= minimumConfidence, other > wearer { return .speaker }
        return nil
    }
}
