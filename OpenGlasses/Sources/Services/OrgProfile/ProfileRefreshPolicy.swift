import Foundation

/// Plan ND — when the phone asks the profile's address whether the company changed anything.
///
/// The daily full fetch is the lease's: only a verified copy renews it. Between those, on launch and
/// every foreground, a **conditional** fetch (`If-None-Match: "<generation>"`) costs a `304` with no
/// body when nothing changed, so an administrator's edit reaches a phone the next time it is opened
/// rather than the next day. A `304` is unsigned, so it renews and changes nothing.
enum ProfileRefreshPolicy {

    enum Trigger: Equatable, Sendable {
        /// Launch, foreground, the routine pass.
        case routine
        /// *Check for Updates*, or anything else the person asked for.
        case forced
    }

    enum Action: Equatable, Sendable {
        case skip
        /// Ask whether the copy at the address is still this generation.
        case conditional(generation: Int)
        /// Fetch the whole document; a verified copy renews the lease.
        case full
    }

    /// The most often a conditional fetch is made.
    static let conditionalInterval: TimeInterval = 15 * 60

    static func action(trigger: Trigger, lastFullAttempt: Date?, lastConditionalCheck: Date?,
                       knownGeneration: Int?, now: Date,
                       fullInterval: TimeInterval = ProfileLease.renewalInterval) -> Action {
        if trigger == .forced { return .full }
        // Never fetched, a day gone, or a clock wound back past the last attempt: the lease's fetch.
        guard let lastFull = lastFullAttempt, lastFull <= now,
              now.timeIntervalSince(lastFull) < fullInterval else { return .full }
        // A profile from before ND carries no generation to compare against, so there is no cheap
        // question to ask; the daily fetch is all it gets, as before.
        guard let generation = knownGeneration else { return .skip }
        if let lastCheck = lastConditionalCheck, lastCheck <= now,
           now.timeIntervalSince(lastCheck) < conditionalInterval {
            return .skip
        }
        return .conditional(generation: generation)
    }

    /// The `If-None-Match` value for a generation. The contract has the host send
    /// `ETag: "<generation>"` with every copy (`Contracts/company-settings.md`).
    static func entityTag(for generation: Int) -> String { "\"\(generation)\"" }
}

/// What a conditional fetch of the profile's address came back with.
enum ProfileConditionalFetch: Equatable, Sendable {
    /// `304`: the copy at the address is the generation asked about.
    case notModified
    /// `200`: a document, to be verified like any other.
    case document(Data)
    /// Anything else — no network, an error status, a redirect. Changes nothing; the daily fetch
    /// still runs.
    case unavailable
}
