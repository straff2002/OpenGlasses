import Foundation

/// The choices Plan MM leaves to the owner, each taken at the plan's recommendation and kept here
/// so that changing one is a one-line edit (Plan MM, "Decisions for Greig"). Decision 1 (which
/// system comes first) is taken, and its adapter lives in a subfolder of its own: nothing directly
/// in this folder names a vendor (`StockSystemAdapterSeamTests`).
///
/// Where a decision is enforced by the shape of a type rather than by a value, the comment says
/// which type, so the place to change it is still one obvious place.
enum StockSystemPolicy {

    // MARK: Decision 2 — a firm with the office

    // The existing `organizationFieldServiceRoute = office` ceiling stops direct stock connectors
    // as well. `StockAuthority.resolve(officeRoute:connection:)` takes it as its first input.

    // MARK: Decision 3 — the phone's list beside a system

    /// What the phone's own list for a place becomes while a system holds that place's count: kept,
    /// read-only, as the previous list, and given back when the connection is removed. Never both
    /// counting at once (`StockAuthority.phoneList`).
    static let phoneListWhileSystemHolds: StockAuthority.PhoneList = .previous

    // MARK: Decision 4 — how used parts go back

    // Part lines on the system's job when the system has jobs and the job carries that system's
    // reference; otherwise adjustments with the organisation's reason; never both for one line.
    // `PartsUsedWritePlan.route(capabilities:reference:)` is the one place the choice is made.

    // MARK: Decision 5 — who confirms

    // The person at job close (or the person keeping a premises list), one yes per batch.
    // `StockUseConfirmation` has no case for an agent, so no agent path can produce a batch.

    // MARK: Decisions 6 and 7 — no counts, no sales

    // `PartsUsedWritePlan.Step` has no case for a count, a set level, a sale, a price, a new
    // catalogue item or a change to a job's status, so none of them can be written.

    // MARK: Decision 8 — quantities

    // Plan ML's `StockQuantity` throughout. `StockSystemQuantityConversion` refuses a figure finer
    // than its scale, or in a unit the phone does not keep, rather than rounding it.

    // MARK: Decision 9 — prices

    /// Prices are dropped when a snapshot is built or decoded unless the organisation enables them.
    static let pricesEnabledByDefault = false

    // MARK: Decision 10 — the live check

    /// A `check` asks the system for just the asked-about lines once the snapshot is older than
    /// this, when there is signal (Plan MM §2).
    static let checkNowAfter: TimeInterval = 10 * 60

    /// How long a `check` waits for those lines. A later reply only refreshes the store, and the
    /// answer comes from the snapshot with its age.
    static let checkNowBudget: TimeInterval = 3

    // MARK: Decision 11 — the provenance word

    // `StockSystemProvenance` has the one case `system`, said as "in <system>", never "counted".

    // MARK: Limits (HF's, unchanged)

    /// A snapshot answered older than this says its age first (HF Decision 3).
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// The most lines a snapshot holds (HF's cap).
    static let lineCap = 20_000

    /// The decimal places a system may say it keeps for an item. A value outside this is not one a
    /// system means, and is dropped rather than trusted; three or more is no limit beyond the
    /// phone's own scale.
    static let decimalPlacesRange = 0...9

    /// Text is cut to these lengths; an identifier longer than its cap makes the row unreadable
    /// instead, because a cut identifier could name another item.
    enum Cap {
        static let identifier = 128
        static let part = 64
        static let description = 200
        static let locationName = 120
        static let sourceText = 120
        static let systemUnit = 32
        static let price = 24
        static let reason = 200
    }
}
