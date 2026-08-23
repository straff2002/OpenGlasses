import Foundation

/// The rolling grounding context for continuous scene narration (Plan CV P2): what the loop has
/// recently looked at, kept bounded, rendered as a prompt fragment a later question is answered
/// against.
///
/// This is the half of the feature that benefits every wearer in the mode rather than only the one
/// who asked for speech. The loop's default state is watching *silently*, and the reason that is
/// worth spending inferences on is here: when the wearer then asks *"what's that?"*, the model
/// answers against a scene it has already looked at instead of paying a fresh capture-and-describe
/// round trip.
///
/// Bounded on three axes deliberately, because this is fed by a loop that never stops on its own:
/// count, age, and rendered characters. Age matters most and is the least obvious — a description
/// of a room the wearer walked out of four minutes ago is not grounding, it is a wrong answer with
/// evidence attached.
///
/// Pure value type: time is injected via `now`, no clock inside, so every branch is deterministic
/// and headless-testable — the same shape as `NarrationGate` and `FrameGate`, which it partners.
struct NarrationContext: Equatable {

    /// One thing the loop saw.
    struct Observation: Equatable {
        let description: String
        let at: TimeInterval
        /// Whether this one was actually said out loud. Kept because the two halves of the feature
        /// are separable: everything here is grounding, only some of it was narration.
        let wasSpoken: Bool
    }

    /// Why a description did or didn't join the context.
    enum Admission: Equatable {
        case recorded
        /// Too close to what is already the most recent observation — a rephrase of a scene the
        /// context already holds. Recording it would crowd the budget with no new grounding.
        case redundant(similarity: Double)
        /// Nothing describable (empty, or boilerplate with no content words).
        case empty

        var isRecorded: Bool { self == .recorded }
    }

    /// Most observations retained regardless of age.
    var maxObservations: Int = 12

    /// Oldest observation worth grounding against (seconds). Past this a description describes
    /// somewhere the wearer no longer is.
    var maxAge: TimeInterval = 240

    /// Ceiling on the rendered prompt fragment. A continuous loop would otherwise spend an
    /// ever-growing share of the context window on its own history.
    var maxPromptCharacters: Int = 1200

    /// Similarity at or above which a new description adds nothing to what is already held.
    ///
    /// Compared only against the **most recent** observation, not all of them: the point is to
    /// avoid a run of rephrases of one unchanged scene, and a scene the wearer returns to after
    /// walking elsewhere genuinely is worth recording again — it is where they are now.
    var redundantAbove: Double = 0.5

    private(set) var observations: [Observation] = []

    init() {}

    // MARK: - Recording

    /// Offer a generated description to the context.
    ///
    /// Similarity reuses `NarrationGate`'s word-overlap scoring rather than defining a second one.
    /// It deliberately does **not** touch the gate's spoken baseline — that baseline moves only
    /// when something is actually said, and a silent grounding write must not disturb it.
    @discardableResult
    mutating func record(_ description: String, at now: TimeInterval, spoken: Bool) -> Admission {
        let words = NarrationGate.contentWords(description)
        guard !words.isEmpty else { return .empty }

        if let latest = observations.last {
            let score = NarrationGate.similarity(words, NarrationGate.contentWords(latest.description))
            if score >= redundantAbove {
                return .redundant(similarity: score)
            }
        }

        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        observations.append(Observation(description: trimmed, at: now, wasSpoken: spoken))
        prune(at: now)
        return .recorded
    }

    /// Drop what is too old or beyond the count cap. Called on every record, and worth calling
    /// before rendering too — a loop that has been idle should not ground against stale scenes
    /// merely because nothing new arrived to push them out.
    mutating func prune(at now: TimeInterval) {
        observations.removeAll { now - $0.at > maxAge }
        if observations.count > maxObservations {
            observations.removeFirst(observations.count - maxObservations)
        }
    }

    mutating func reset() {
        observations.removeAll()
    }

    // MARK: - Reading

    var latest: Observation? { observations.last }

    var isEmpty: Bool { observations.isEmpty }

    /// The context as a prompt fragment, newest last so it reads as a chronology, trimmed from the
    /// **oldest** end to fit `maxPromptCharacters`.
    ///
    /// Returns nil rather than an empty fragment when there is nothing to say, so the caller
    /// appends nothing rather than an empty header — a heading with no body reads to a model as an
    /// assertion that the wearer has been somewhere featureless.
    func promptFragment(at now: TimeInterval) -> String? {
        var pruned = self
        pruned.prune(at: now)
        guard !pruned.observations.isEmpty else { return nil }

        var lines: [String] = []
        var budget = maxPromptCharacters
        // Newest first while filling, so the newest survives the budget; reversed on the way out.
        for observation in pruned.observations.reversed() {
            let line = "- \(Self.relativeAge(now - observation.at)): \(observation.description)"
            guard budget - line.count >= 0 else { break }
            budget -= line.count + 1
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }

        return """
        What you have recently seen through the wearer's glasses, oldest first:
        \(lines.reversed().joined(separator: "\n"))
        """
    }

    /// Coarse relative age. Coarse on purpose: the model needs "a moment ago" versus "a few
    /// minutes ago" to answer *"what's that?"* sensibly, and a false-precision "137 seconds ago"
    /// invites it to reason about timings the loop's own cadence doesn't support.
    static func relativeAge(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<20: return "just now"
        case ..<90: return "a moment ago"
        case ..<240: return "a few minutes ago"
        default: return "earlier"
        }
    }
}
