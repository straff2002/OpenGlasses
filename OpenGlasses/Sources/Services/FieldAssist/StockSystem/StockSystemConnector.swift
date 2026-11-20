import Foundation

/// What a read-back found of a plan's writes in the system (Plan MM §6): the idempotency keys the
/// system shows as already applied, from the job's part lines or the adjustments since the batch
/// was queued. A retry sends only what is not here (`PartsUsedWritePlan.remaining(after:)`).
struct StockSystemReadBack: Equatable, Sendable {
    let applied: Set<String>

    init(applied: Set<String>) {
        self.applied = applied
    }
}

/// The seam every stock connector sits behind (Plan MM P0). One per system; each is plain HTTPS
/// through its own transport (Plan MM §7), and none exists yet: P1 builds the first. Tests use a
/// fake.
///
/// A connector reads stock and locations, and writes only what a `PartsUsedWritePlan` holds: part
/// lines on a job, or adjustments with a reason (`Contracts/stock-systems.md`). It reads back
/// before any retry.
protocol StockSystemConnector: Sendable {
    /// What the system can take back.
    var capabilities: StockSystemCapabilities { get }

    /// The system's locations, for "Which stock is here?".
    func locations() async throws -> [StockSystemLocation]

    /// A whole snapshot of the chosen locations' stock.
    func pullSnapshot(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshot

    /// Sends the plan's steps, each with its idempotency key, and returns what the system
    /// accepted. Throws when the outcome is uncertain, so the caller reads back before trying
    /// again.
    func apply(_ steps: [PartsUsedWritePlan.Step]) async throws -> StockSystemReadBack

    /// Which of the plan's steps the system already shows.
    func readBack(_ plan: PartsUsedWritePlan) async throws -> StockSystemReadBack
}
