import Foundation

/// One LLM API call's token usage + estimated cost (Plan AU). Persisted by
/// `UsageStore`; aggregated by `UsageRollup`. Local-only — never leaves the device.
struct UsageRecord: Equatable {
    let id: String
    let sessionId: String
    let provider: String
    let model: String
    let tokensIn: Int
    let tokensOut: Int
    /// Anthropic prompt-cache counts (separate from `tokensIn`): tokens written to and
    /// read from the cache. 0 on providers/turns without caching. Priced into `costUSD`.
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    /// Estimated USD, or `nil` when the model is unpriced (tokens still recorded).
    let costUSD: Double?
    let at: Date
    /// The Field Assist job the call served, when one was active (Plan GB P5) — so cost can be
    /// split per job. Nil for calls outside a job and for rows written before the column existed.
    let fieldSessionId: String?

    init(id: String = UUID().uuidString,
         sessionId: String,
         provider: String,
         model: String,
         tokensIn: Int,
         tokensOut: Int,
         cacheWriteTokens: Int = 0,
         cacheReadTokens: Int = 0,
         costUSD: Double?,
         at: Date,
         fieldSessionId: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
        self.at = at
        self.fieldSessionId = fieldSessionId
    }
}

/// What one job cost in model usage (Plan GB P5): the internal record's usage line and the Job
/// tab's figure. Never on the customer's page. Codable with every field optional-friendly so a work
/// record can carry it decode-if-present.
struct JobUsageSummary: Codable, Equatable {
    let requests: Int
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
    /// Sum of the priced requests; nil when none was priced.
    let estimatedUSD: Double?
    /// Requests whose model had no price — the dollar figure leaves them out.
    let unpricedRequests: Int

    var isEmpty: Bool { requests == 0 }

    /// Pure rollup of the rows tagged with `fieldSessionId`.
    static func summarise(_ records: [UsageRecord], fieldSessionId: String) -> JobUsageSummary {
        let rows = records.filter { $0.fieldSessionId == fieldSessionId }
        let priced = rows.compactMap(\.costUSD)
        return JobUsageSummary(
            requests: rows.count,
            inputTokens: rows.reduce(0) { $0 + $1.tokensIn },
            cachedTokens: rows.reduce(0) { $0 + $1.cacheReadTokens },
            outputTokens: rows.reduce(0) { $0 + $1.tokensOut },
            estimatedUSD: priced.isEmpty ? nil : priced.reduce(0, +),
            unpricedRequests: rows.filter { $0.costUSD == nil }.count)
    }
}

/// Pure aggregation of `UsageRecord`s into per-model + total tokens/cost over a
/// window. No I/O. A model with no priced records reports `costUSD == nil` (tokens
/// only); the grand `totalUSD` sums the priced records and is `nil` only when none
/// in the window are priced.
enum UsageRollup {

    struct ModelTotal: Equatable {
        let model: String
        let tokensIn: Int
        let tokensOut: Int
        let costUSD: Double?
    }

    struct Result: Equatable {
        let perModel: [ModelTotal]
        let totalTokensIn: Int
        let totalTokensOut: Int
        let totalUSD: Double?
    }

    /// Roll up records with `at >= since`. `perModel` is sorted by total tokens
    /// (descending), then model id for a stable order.
    static func rollup(_ records: [UsageRecord], since: Date) -> Result {
        let inWindow = records.filter { $0.at >= since }

        var byModel: [String: (tIn: Int, tOut: Int, cost: Double?)] = [:]
        for r in inWindow {
            var acc = byModel[r.model] ?? (0, 0, nil)
            acc.tIn += r.tokensIn
            acc.tOut += r.tokensOut
            if let c = r.costUSD {
                acc.cost = (acc.cost ?? 0) + c
            }
            byModel[r.model] = acc
        }

        let perModel = byModel
            .map { ModelTotal(model: $0.key, tokensIn: $0.value.tIn, tokensOut: $0.value.tOut, costUSD: $0.value.cost) }
            .sorted { lhs, rhs in
                let l = lhs.tokensIn + lhs.tokensOut
                let r = rhs.tokensIn + rhs.tokensOut
                return l != r ? l > r : lhs.model < rhs.model
            }

        let totalIn = inWindow.reduce(0) { $0 + $1.tokensIn }
        let totalOut = inWindow.reduce(0) { $0 + $1.tokensOut }
        let pricedCosts = inWindow.compactMap { $0.costUSD }
        let totalUSD: Double? = pricedCosts.isEmpty ? nil : pricedCosts.reduce(0, +)

        return Result(perModel: perModel,
                      totalTokensIn: totalIn,
                      totalTokensOut: totalOut,
                      totalUSD: totalUSD)
    }
}
