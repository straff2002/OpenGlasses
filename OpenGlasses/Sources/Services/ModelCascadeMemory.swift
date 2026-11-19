import Foundation

/// What the cascade learned from the last turn, carried into the next ones.
///
/// `ModelCascade` is single-turn: every turn starts on the active model and hops only after that
/// model has failed. When a provider is degraded for a while — a 503 that takes eight seconds to
/// arrive, a request that hangs for the whole timeout — every turn pays that wait again before
/// the hop, and a wearer who has already heard "switching to ChatGPT" waits forty seconds for
/// "OK" to be acknowledged (tester report, 2026-10-20: four such turns in twenty minutes).
///
/// This type remembers one thing: the lead the chain hopped away from, and the model that then
/// answered. For a bounded hold the chain starts on that model instead, with the lead moved to
/// second place so a failure there still finds it. The hold ends on its own, or at once when the
/// lead answers a turn again (the wearer picked it back, or the hold expired and it recovered).
/// The active model setting is never changed; this is start order, not selection.
///
/// Headless-testable: time is a parameter.
struct ModelCascadeMemory: Equatable {

    /// How long the chain starts on the model that answered. Long enough that a degraded
    /// provider is not re-probed every turn (the probe is the slow turn being avoided); short
    /// enough that a blip does not keep the wearer off their chosen model for the afternoon.
    static let holdSeconds: TimeInterval = 10 * 60

    struct Deferral: Equatable {
        /// The model the wearer chose, which failed with a transient error.
        let lead: String
        /// The model that answered after the hop.
        let preferred: String
        /// When the chain goes back to starting on `lead`.
        let until: Date
    }

    private(set) var deferral: Deferral?

    init(deferral: Deferral? = nil) {
        self.deferral = deferral
    }

    /// Record how a turn ended.
    ///
    /// - Parameters:
    ///   - lead: the model the chain was asked to start on (the active model, or the job route).
    ///   - answeredBy: the model whose attempt returned the reply.
    ///   - hop: how the chain left `lead`, when it did (`nil` when `lead` answered or was never
    ///     hopped from). Only a transient failure starts a hold: a bad key or a model that cannot
    ///     see a photo is not "degraded", and the chain already handles those per turn.
    mutating func recordTurn(lead: String, answeredBy: String,
                             hop: ModelFallbackChain.FailureClass?, now: Date) {
        if answeredBy == lead {
            if deferral?.lead == lead { deferral = nil }
            return
        }
        guard hop == .retryOtherModel else { return }
        deferral = Deferral(lead: lead, preferred: answeredBy,
                            until: now.addingTimeInterval(Self.holdSeconds))
    }

    /// The deferral that applies to a chain led by `lead` at `now`, if any.
    func activeDeferral(lead: String, now: Date) -> Deferral? {
        guard let deferral, deferral.lead == lead, now < deferral.until else { return nil }
        return deferral
    }

    /// `candidates` in the order the chain should try them. Without an applicable hold, or when
    /// the preferred model is no longer in the chain, the order is unchanged.
    func ordered(_ candidates: [ModelFallbackChain.Candidate], lead: String,
                 now: Date) -> [ModelFallbackChain.Candidate] {
        guard let deferral = activeDeferral(lead: lead, now: now),
              let preferred = candidates.first(where: { $0.id == deferral.preferred }),
              candidates.first?.id != preferred.id else { return candidates }
        return [preferred] + candidates.filter { $0.id != preferred.id }
    }

    /// The order a turn's `chain` is tried in. A chosen Vision model at the front of a photo
    /// turn's chain keeps its place, since the hold is about the assistant's lead; any other
    /// chain is `ordered`. The cascade and the routing line said before it both read this, so the
    /// line never names a model the turn will not start on.
    func startOrder(_ chain: [ModelFallbackChain.Candidate], lead: String, visionModelId: String?,
                    now: Date) -> [ModelFallbackChain.Candidate] {
        if let visionModelId, chain.first?.id == visionModelId { return chain }
        return ordered(chain, lead: lead, now: now)
    }
}
