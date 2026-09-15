import Foundation

/// What the wearer's saved memory contributed to one assembled prompt — counts, sizes, case names
/// and a timestamp, and nothing else.
///
/// Plan FC P3. The prompt path could not previously answer *"did this turn see any memory?"*.
/// `SemanticMemoryStore.systemPromptContext(query:)` returns `nil`, and so does the call site when
/// the wearer has memory switched off — so "memory is disabled", "there is nothing saved yet",
/// "the database would not open" and "a block was built but the tier clipped it" all arrived at
/// the backend as the same absent parameter. A wearer reporting *"it doesn't remember me"* left us
/// nothing to read back. This type is that missing distinction, measured **after** filtering and
/// rendering so every number describes the block that was actually appended to the prompt.
///
/// Privacy (Plan DM): a memory key, a memory value, a person's name and the wearer's query have no
/// field to arrive in. Everything here is an `Int`, a `TimeInterval`, a `Date`, or the name of a
/// case declared in this file.
struct MemoryContextSnapshot: Equatable {

    // MARK: - Availability

    /// Why the prompt did, or did not, carry a memory block. The four absent cases are the point:
    /// they are indistinguishable at the call site and have completely different fixes.
    enum Availability: Equatable {
        /// The wearer turned memory off. Nothing was read.
        case disabled
        /// Memory is on and readable, and there is nothing saved to inject.
        case empty
        /// Memory is on, and the store could not be read. A wearer who saved facts yesterday and
        /// gets none today is looking at this case, not at `empty`.
        case unavailable(Unavailable)
        /// A block was rendered and handed to the prompt.
        case available
        /// This route never carries wearer memory at all — a fact about the route, not about the
        /// store. The live backends are here: their instruction is assembled at connect and has
        /// never included a memory block.
        case notInjected

        var label: String {
            switch self {
            case .disabled: return "disabled"
            case .empty: return "empty"
            case .unavailable: return "unavailable"
            case .available: return "available"
            case .notInjected: return "notInjected"
            }
        }

        var unavailableReason: Unavailable? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Why the store could not be read. A case name, never a path and never an SQLite message.
    enum Unavailable: String {
        /// The database did not open, so the caches behind every section are empty for a reason
        /// that has nothing to do with what the wearer saved.
        case storageUnreadable
    }

    // MARK: - Route

    /// Which assembly produced the snapshot. Not a cohort key — it exists so a reader can tell a
    /// wearer's voice turn from the app's own background work, and either from a live session.
    enum Route: String {
        /// A turn the wearer is waiting on.
        case turn
        /// The app's own work — a scheduled agent run, a notification digest — which runs through
        /// the same prompt builder off-turn.
        case background
        case liveGemini
        case liveOpenAI
    }

    // MARK: - Freshness

    /// When the block in the prompt was assembled, relative to the turn using it.
    ///
    /// The live backends build their system instruction **once, at connect**, and reuse it for
    /// every turn of the session. Reporting those turns as per-turn retrieval would be a lie with
    /// a specific cost: it would send someone looking for a retrieval bug when the real answer is
    /// that the instruction is an hour old.
    enum Freshness: Equatable {
        case perTurn
        case connectSnapshot(age: TimeInterval)

        var label: String {
            switch self {
            case .perTurn: return "perTurn"
            case .connectSnapshot: return "connectSnapshot"
            }
        }

        var ageSeconds: TimeInterval? {
            if case .connectSnapshot(let age) = self { return age }
            return nil
        }
    }

    // MARK: - Truncation

    /// What the rendering and the prompt tier removed from what retrieval offered.
    ///
    /// A struct rather than one enum case, because the shapes co-occur: a store with more entries
    /// than the per-section cap *and* one over-long value truncates both ways in a single render,
    /// and an enum would force the report to name one and hide the other.
    struct Truncation: Equatable {
        /// Entries retrieval offered that the per-section cap (`maxMemoryLines`) did not render.
        var droppedEntries: Int
        /// Values that were rendered, cut to `maxValueChars`. A clamp is truncation: the model saw
        /// part of that fact.
        var clampedValues: Int
        /// What the prompt tier did to the assembled block after the store handed it over.
        var omission: Omission?

        /// The prompt did not take the block whole.
        enum Omission: Equatable {
            /// A lean tier clipped the block to fit its own budget (see
            /// `LLMService.leanMemoryClipLimit`).
            case clippedForPromptBudget(droppedCharacters: Int)

            var label: String {
                switch self {
                case .clippedForPromptBudget: return "clippedForPromptBudget"
                }
            }

            var droppedCharacters: Int {
                switch self {
                case .clippedForPromptBudget(let dropped): return dropped
                }
            }
        }

        init(droppedEntries: Int = 0, clampedValues: Int = 0, omission: Omission? = nil) {
            self.droppedEntries = max(0, droppedEntries)
            self.clampedValues = max(0, clampedValues)
            self.omission = omission
        }

        static let none = Truncation()

        var isNone: Bool { droppedEntries == 0 && clampedValues == 0 && omission == nil }

        /// Case names joined by `.`, or `none`. Never a count — the counts travel in their own
        /// fields so a reader does not have to parse this. Dot-joined rather than `+`-joined
        /// because this string is also a `PrivacyToken`, whose vocabulary is letters, digits,
        /// `_`, `.` and `-`: a `+` here would be silently replaced by `unnamed` in the log.
        var label: String {
            var parts: [String] = []
            if droppedEntries > 0 { parts.append("cappedEntries") }
            if clampedValues > 0 { parts.append("clampedValues") }
            if let omission { parts.append(omission.label) }
            return parts.isEmpty ? "none" : parts.joined(separator: ".")
        }
    }

    // MARK: - Fields

    var availability: Availability
    /// Entries held in the store across every section, whether or not this turn used them. The
    /// number that separates "nothing is saved" from "plenty is saved and none of it came back".
    var stored: Int
    /// Entries retrieval handed to rendering, before the per-section cap.
    ///
    /// The semantic branch's own `limit:` is part of *retrieval*, not truncation — a query turn
    /// against a 200-entry store legitimately reports a small `retrieved`, and `stored` is what
    /// says the store was not empty.
    var retrieved: Int
    /// Entries that reached the rendered block.
    var included: Int
    /// Characters — not bytes, not scalars — of the block as the prompt received it. Compared
    /// against the prompt in `MemoryContextDiagnosticsTests`, so it cannot drift into an estimate.
    var renderedCharacters: Int
    var truncation: Truncation
    /// When this block was built. For a live session this is connect time, and it is the whole
    /// reason the field exists.
    var assembledAt: Date
    var freshness: Freshness

    /// Four characters to a token — the same ratio `HistoryHygiene.estimatedTokens` already uses
    /// for history, so the two numbers in a report are on one scale. Computed rather than stored:
    /// an estimate that can disagree with the character count it came from is worse than no
    /// estimate. Monotonic in `renderedCharacters` by construction.
    var estimatedTokens: Int { Self.estimatedTokens(characters: renderedCharacters) }

    static func estimatedTokens(characters: Int) -> Int {
        guard characters > 0 else { return 0 }
        return max(characters / 4, 1)
    }

    init(availability: Availability,
         stored: Int = 0,
         retrieved: Int = 0,
         included: Int = 0,
         renderedCharacters: Int = 0,
         truncation: Truncation = .none,
         assembledAt: Date,
         freshness: Freshness = .perTurn) {
        self.availability = availability
        self.stored = max(0, stored)
        self.retrieved = max(0, retrieved)
        self.included = max(0, included)
        self.renderedCharacters = max(0, renderedCharacters)
        self.truncation = truncation
        self.assembledAt = assembledAt
        self.freshness = freshness
    }

    // MARK: - The absent cases

    static func disabled(at time: Date) -> MemoryContextSnapshot {
        MemoryContextSnapshot(availability: .disabled, assembledAt: time)
    }

    static func empty(at time: Date, stored: Int = 0) -> MemoryContextSnapshot {
        MemoryContextSnapshot(availability: .empty, stored: stored, assembledAt: time)
    }

    static func unavailable(_ reason: Unavailable, at time: Date) -> MemoryContextSnapshot {
        MemoryContextSnapshot(availability: .unavailable(reason), assembledAt: time)
    }

    /// A route that carries no memory block at all. `freshness` is the caller's, because the live
    /// backends' "no memory here" is still a statement about a connect-time instruction.
    static func notInjected(at time: Date,
                            freshness: Freshness = .perTurn) -> MemoryContextSnapshot {
        MemoryContextSnapshot(availability: .notInjected, assembledAt: time, freshness: freshness)
    }

    // MARK: - Derivations

    /// The same snapshot as read at `now`: a connect-time snapshot's age is recomputed, a per-turn
    /// one is returned unchanged.
    ///
    /// Age is never negative — a clock that stepped backwards under a live session should read as
    /// "just now", not as a snapshot from the future.
    func asOf(_ now: Date) -> MemoryContextSnapshot {
        guard case .connectSnapshot = freshness else { return self }
        var copy = self
        copy.freshness = .connectSnapshot(age: max(0, now.timeIntervalSince(assembledAt)))
        return copy
    }

    /// The prompt tier took only `characters` of the block. Records the clip as truncation and
    /// re-points `renderedCharacters` at what was actually sent.
    ///
    /// `dropped` is passed explicitly where the clipper knows it, because a clip that substitutes
    /// an ellipsis for what it removed makes the two sizes disagree by that ellipsis: 500
    /// characters cut to a 400-character prefix plus "…" is 401 characters in the prompt and 100
    /// characters the model can no longer see. Subtracting the sizes would report 99 and be wrong
    /// in the one direction that matters. Without it, the difference is the best available answer.
    func clipped(to characters: Int, dropped: Int? = nil) -> MemoryContextSnapshot {
        let kept = max(0, characters)
        let lost = max(0, dropped ?? (renderedCharacters - kept))
        guard lost > 0 else { return self }
        var copy = self
        copy.truncation.omission = .clippedForPromptBudget(droppedCharacters: lost)
        copy.renderedCharacters = kept
        return copy
    }

    // MARK: - Reporting

    /// One line for the developer turn-ledger export. Fixed vocabulary and numbers only.
    var reportLine: String {
        var parts = ["availability=\(availability.label)"]
        if let reason = availability.unavailableReason { parts.append("reason=\(reason.rawValue)") }
        parts.append("stored=\(stored)")
        parts.append("retrieved=\(retrieved)")
        parts.append("included=\(included)")
        parts.append("characters=\(renderedCharacters)")
        parts.append("tokens=\(estimatedTokens)")
        parts.append("truncation=\(truncation.label)")
        if truncation.droppedEntries > 0 { parts.append("dropped=\(truncation.droppedEntries)") }
        if truncation.clampedValues > 0 { parts.append("clamped=\(truncation.clampedValues)") }
        if let omission = truncation.omission {
            parts.append("clippedCharacters=\(omission.droppedCharacters)")
        }
        parts.append("freshness=\(freshness.label)")
        if let age = freshness.ageSeconds {
            parts.append("age=\(String(format: "%.0fs", age))")
        }
        return parts.joined(separator: " ")
    }
}
