import Foundation

/// When the OpenAI voice stops: OpenAI removes every model its speech endpoint takes on 2027-01-06
/// and names no replacement on that endpoint (Plan KB). A pure value with the clock passed in.
/// The Settings footer reads it; the engine chain does not yet.
enum OpenAIVoiceRetirement {

    enum Phase: Equatable {
        /// Still answering. `daysLeft` rounds up, so the last day counts as one.
        case announced(daysLeft: Int)
        case retired
    }

    /// The same day `ModelShutdownCalendar` lists for `CloudVoiceRequests.openAISpeechModel`.
    static let shutdown = ModelShutdown(year: 2027, month: 1, day: 6)

    static var retirementInstant: Date { shutdown.date }

    static func phase(now: Date) -> Phase {
        guard !shutdown.hasPassed(on: now) else { return .retired }
        let seconds = retirementInstant.timeIntervalSince(now)
        return .announced(daysLeft: Int((seconds / 86_400).rounded(.up)))
    }

    /// The line added to the voice's description while it is still answering.
    static func pickerNote(now: Date) -> String? {
        guard case .announced = phase(now: now) else { return nil }
        return String(localized: "OpenAI is retiring this voice on \(shutdown.displayDate).")
    }
}
