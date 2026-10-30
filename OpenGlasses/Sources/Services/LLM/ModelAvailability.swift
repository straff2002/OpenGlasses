import Foundation

// Plan KA P2 — whether a listed or saved model can be chosen for a job, beyond what kind it is:
// whether the provider has shut it down (or says when it will), and whether the app has a
// connection that can reach it. A model can be the right kind and still be unusable: OpenAI's
// `gpt-live-1` is a live voice model, but it speaks a session API the app doesn't have.

/// The day a provider shuts a model down, as its list reports it (OpenAI's `shutdown_date`) or as
/// its deprecations page dates it. Compared in UTC: on or after this day the id no longer answers.
struct ModelShutdown: Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Read `YYYY-MM-DD`, or the date at the front of a longer ISO string. Nil for anything else.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let parts = trimmed.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// Midnight UTC at the start of the shutdown day.
    var date: Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantFuture
    }

    /// Whether the model is already shut down on `today`.
    func hasPassed(on today: Date) -> Bool { today >= date }

    /// Whether the model is still answering on `today` but stops within `days`.
    func isWithin(days: Int, of today: Date) -> Bool {
        !hasPassed(on: today) && date.timeIntervalSince(today) <= Double(days) * 86_400
    }

    /// The day as the wearer reads it ("6 January 2027"), in UTC so it never slips a day.
    var displayDate: String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: Self.utc.timeZone))
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// Where a model's shutdown day comes from: the list's own field when a list is loaded, else the
/// dates the provider has published. Only OpenAI's list sends one today; the field is generic.
enum ModelShutdownCalendar {

    /// A model retiring within this many days stays choosable and says when it goes.
    static let warningDays = 90

    /// The shutdown day for `id`, or nil when none is known. `listed` (the list's own field) wins.
    static func shutdown(provider: LLMProvider, id: String, listed: ModelShutdown? = nil) -> ModelShutdown? {
        if let listed { return listed }
        guard provider == .openai else { return nil }
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let day = openAIDates[key] { return day }
        // Realtime ids the list no longer carries (removed previews) are dated by Plan KC's table.
        if let entry = OpenAIRealtimeModelRetirement.entry(for: key), let year = entry.removal.year,
           let month = entry.removal.month, let day = entry.removal.day {
            return ModelShutdown(year: year, month: month, day: day)
        }
        return nil
    }

    /// The warning a saved model's row shows when its provider has shut it down or will within
    /// `warningDays`. Nil otherwise.
    static func savedModelWarning(provider: LLMProvider, id: String, today: Date = Date()) -> String? {
        warning(for: shutdown(provider: provider, id: id), today: today)
    }

    /// The warning for a shutdown day: retired, or retiring within `warningDays`. Nil otherwise.
    static func warning(for day: ModelShutdown?, today: Date = Date()) -> String? {
        guard let day else { return nil }
        if day.hasPassed(on: today) {
            return String(localized: "Retired on \(day.displayDate) — this model no longer answers. Choose another.")
        }
        if day.isWithin(days: warningDays, of: today) {
            return String(localized: "Retires \(day.displayDate) — choose another model before then.")
        }
        return nil
    }

    /// OpenAI's dated models: every id its `/v1/models` list returned with a `shutdown_date` on
    /// 2026-10-30, the dates its deprecations page publishes. An id the list later carries with a
    /// date of its own uses that date instead. Re-read when OpenAI announces a deprecation.
    static let openAIDates: [String: ModelShutdown] = {
        var dates: [String: ModelShutdown] = [:]
        for (day, ids) in openAIDatedIds {
            guard let shutdown = ModelShutdown(day) else { continue }
            for id in ids { dates[id] = shutdown }
        }
        return dates
    }()

    private static let openAIDatedIds: [(String, [String])] = [
        ("2026-07-23", [
            "gpt-4o-mini-search-preview-2025-03-11", "gpt-4o-search-preview-2025-03-11",
            "gpt-5-chat-latest", "gpt-5-codex", "gpt-5.1-chat-latest", "gpt-5.1-codex",
            "gpt-5.1-codex-max", "gpt-5.1-codex-mini", "gpt-5.2-codex", "gpt-audio-mini-2025-10-06",
            "o3-deep-research", "o3-deep-research-2025-06-26", "o4-mini-deep-research",
            "o4-mini-deep-research-2025-06-26"
        ]),
        ("2026-08-10", [
            "gpt-5.2-chat-latest", "gpt-5.3-chat-latest"
        ]),
        ("2026-09-24", [
            "sora-2", "sora-2-pro"
        ]),
        ("2026-09-28", [
            "babbage-002", "davinci-002", "gpt-3.5-turbo-1106", "gpt-3.5-turbo-instruct"
        ]),
        ("2026-10-23", [
            "gpt-3.5-turbo", "gpt-3.5-turbo-0125", "gpt-4", "gpt-4-0613", "gpt-4-turbo",
            "gpt-4-turbo-2024-04-09", "gpt-4.1-nano", "gpt-4.1-nano-2025-04-14", "gpt-4o-2024-05-13",
            "gpt-image-1", "o1", "o1-2024-12-17", "o1-pro", "o1-pro-2025-03-19", "o3-mini",
            "o3-mini-2025-01-31", "o4-mini", "o4-mini-2025-04-16"
        ]),
        ("2026-12-01", [
            "chatgpt-image-latest", "gpt-image-1-mini", "gpt-image-1.5"
        ]),
        ("2026-12-11", [
            "gpt-5", "gpt-5-2025-08-07", "gpt-5-mini", "gpt-5-mini-2025-08-07", "gpt-5-nano",
            "gpt-5-nano-2025-08-07", "gpt-5-pro", "gpt-5-pro-2025-10-06", "o3", "o3-2025-04-16",
            "o3-pro", "o3-pro-2025-06-10"
        ]),
        ("2027-01-06", [
            "gpt-4o-mini-tts", "gpt-4o-mini-tts-2025-03-20", "gpt-4o-mini-tts-2025-12-15", "tts-1",
            "tts-1-hd"
        ]),
        ("2027-01-14", [
            "gpt-4.1", "gpt-4.1-2025-04-14", "gpt-4.1-mini", "gpt-4.1-mini-2025-04-14", "gpt-4o",
            "gpt-4o-2024-08-06", "gpt-4o-2024-11-20", "gpt-4o-mini", "gpt-4o-mini-2024-07-18"
        ]),
        ("2027-01-20", [
            "gpt-4o-mini-transcribe-2025-03-20", "gpt-audio", "gpt-audio-2025-08-28", "gpt-audio-mini",
            "gpt-audio-mini-2025-12-15", "gpt-realtime", "gpt-realtime-2025-08-28", "gpt-realtime-mini",
            "gpt-realtime-mini-2025-12-15"
        ]),
        ("2027-02-26", [
            "gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe-2025-12-15", "gpt-4o-transcribe",
            "gpt-4o-transcribe-diarize", "whisper-1"
        ]),
        ("2027-04-01", [
            "gpt-5.1", "gpt-5.1-2025-11-13", "gpt-5.3-codex", "gpt-5.4-nano", "gpt-5.4-nano-2026-03-17"
        ]),
    ]
}

/// Whether the app has a connection that can use a model for a job — separate from its kind
/// (`ModelKindClassifier`). Keyed by provider and id, pure.
///
/// - Voice: OpenAI's `/v1/audio/speech`, Gemini's speech models through `generateContent`, and
///   xAI's `/v1/tts`. A streaming-only speech model (`voxtral-mini-tts-realtime-3-0`) has none.
/// - Live: OpenAI's realtime socket takes the `gpt-realtime…` models, not `gpt-live-1` (a separate
///   sessions API) or `gpt-realtime-translate` (the translations endpoint). Gemini Live takes its
///   live models except the translation ones; the Qwen live connection takes Qwen's.
/// - Dictation: OpenAI's upload endpoint (`/v1/audio/transcriptions`) only. Its streaming-session
///   models (`gpt-live-transcribe`, `gpt-realtime-whisper`) and the diarizing one, which needs a
///   different reply format, can't be used; nor can Gemini's `…-transcribe-live`.
enum ModelTransport {

    static func canUse(provider: LLMProvider, id: String, kind: ModelKind, for role: ModelRole) -> Bool {
        guard kind == role.kind else { return false }
        let words = ModelKindClassifier.words(in: id)
        switch role {
        case .assistant, .vision:
            return true
        case .images:
            // No image tool yet (Design 12).
            return false
        case .voice:
            guard !isStreamingOnly(words) else { return false }
            return [.openai, .gemini, .xai].contains(provider)
        case .dictation:
            guard !isStreamingOnly(words), !words.contains("diarize") else { return false }
            return provider == .openai
        case .live:
            guard !words.contains("translate") else { return false }
            switch provider {
            case .openai: return words.contains("realtime")
            case .gemini, .qwen: return true
            default: return false
            }
        }
    }

    /// The same, reading the kind from the id.
    static func canUse(provider: LLMProvider, id: String, for role: ModelRole) -> Bool {
        canUse(provider: provider, id: id, kind: ModelKindClassifier.kind(provider: provider, id: id), for: role)
    }

    /// A speech or transcription model that only runs inside a streaming session.
    private static func isStreamingOnly(_ words: [String]) -> Bool {
        words.contains("realtime") || words.contains("live") || words.contains("streaming")
    }
}

/// Whether a model can be chosen for a role, and what its row says.
enum ModelChoiceStatus: Equatable {
    /// Choosable; `retiring` when its provider shuts it down within the warning window.
    case choosable(retiring: ModelShutdown?)
    /// Not the role's kind (a speech model in the assistant's list).
    case wrongKind(ModelKind)
    /// The provider has shut it down.
    case retired(ModelShutdown)
    /// The right kind, but the app has no connection that can reach it.
    case needsConnection

    var isChoosable: Bool {
        if case .choosable = self { return true }
        return false
    }

    /// The line a choosable row adds: "Retires 6 January 2027". Nil when there is nothing to say.
    var note: String? {
        guard case .choosable(let retiring?) = self else { return nil }
        return ModelChoiceStatus.retiresLabel(retiring)
    }

    /// The label a dimmed, unchoosable row shows. Nil for a choosable one.
    var unavailableLabel: String? {
        switch self {
        case .choosable: return nil
        case .wrongKind(let kind): return kind.label
        case .retired: return ModelChoiceStatus.retiredLabel
        case .needsConnection: return ModelChoiceStatus.needsConnectionLabel
        }
    }

    static var retiredLabel: String { String(localized: "Retired") }
    static var needsConnectionLabel: String { String(localized: "Needs a connection the app doesn't have yet") }
    static func retiresLabel(_ day: ModelShutdown) -> String { String(localized: "Retires \(day.displayDate)") }

    /// A model's status for `role`: its kind first, then its shutdown day, then the connection.
    static func of(provider: LLMProvider, id: String, kind: ModelKind, shutdown listed: ModelShutdown? = nil,
                   for role: ModelRole, today: Date = Date()) -> ModelChoiceStatus {
        guard kind == role.kind else { return .wrongKind(kind) }
        let day = ModelShutdownCalendar.shutdown(provider: provider, id: id, listed: listed)
        if let day, day.hasPassed(on: today) { return .retired(day) }
        guard ModelTransport.canUse(provider: provider, id: id, kind: kind, for: role) else { return .needsConnection }
        if let day, day.isWithin(days: ModelShutdownCalendar.warningDays, of: today) {
            return .choosable(retiring: day)
        }
        return .choosable(retiring: nil)
    }

    /// The label a chat picker's dimmed section shows for a model that can't be the assistant:
    /// what it is for, and — where the app has that job — whether it is retired or out of reach
    /// ("Live voice · Needs a connection the app doesn't have yet").
    static func assistantSectionLabel(provider: LLMProvider, id: String, kind: ModelKind,
                                      shutdown listed: ModelShutdown? = nil, today: Date = Date()) -> String {
        // A chat model is out of the assistant's list only once it is retired.
        guard !kind.isChat else { return retiredLabel }
        var parts = [kind.label]
        let day = ModelShutdownCalendar.shutdown(provider: provider, id: id, listed: listed)
        if let day, day.hasPassed(on: today) {
            parts.append(retiredLabel)
        } else if let role = ModelRole.shown.first(where: { $0 != .assistant && $0 != .vision && $0.kind == kind }),
                  !ModelTransport.canUse(provider: provider, id: id, kind: kind, for: role) {
            parts.append(needsConnectionLabel)
        }
        return parts.joined(separator: " · ")
    }
}

extension ModelFetcher.RemoteModel {
    /// Whether this listed model can be chosen as the assistant.
    func assistantStatus(provider: LLMProvider, today: Date = Date()) -> ModelChoiceStatus {
        ModelChoiceStatus.of(provider: provider, id: id, kind: kind, shutdown: shutdown, for: .assistant, today: today)
    }

    /// What its row in a chat picker's dimmed section says.
    func unavailableLabel(provider: LLMProvider, today: Date = Date()) -> String {
        ModelChoiceStatus.assistantSectionLabel(provider: provider, id: id, kind: kind, shutdown: shutdown, today: today)
    }
}
