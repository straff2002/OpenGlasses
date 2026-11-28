import Foundation

/// The check against the EMR (Plan MY §8, Decision 8), as the Stock screen runs it.
///
/// Runs only while medical mode is on: the file in the person's hand carries patient details, even
/// though the app keeps none of them. It takes the file's bytes from the screen, reads the three
/// mapped columns (`ImmunisationListReader`), compares them with the doses given here
/// (`ImmunisationReconciliation`) and keeps only the counts (`ImmunisationCheckSummary`). The bytes
/// are never written, logged, put in a support report or sent to a model; nothing in this type
/// stores them, and nothing it returns carries a value from a column it did not read.
@MainActor
final class ImmunisationCheckService {
    static let shared = ImmunisationCheckService()

    enum Outcome: Equatable {
        /// Medical mode is off, or the list is not the phone's own; nothing was read.
        case refused(String)
        /// The file could not be read as mapped.
        case failed(String)
        case done(ImmunisationReconciliation, skippedRows: Int)
    }

    /// Why the check is refused outside medical mode.
    static var medicalModeRefusal: String {
        String(localized: "The check against the EMR runs only while medical mode is on, because the EMR's list holds patient details. Turn on medical mode in Settings, then try again. Nothing was read.")
    }

    private let store: VanStockStore
    private let medicalMode: () -> Bool
    private let now: () -> Date
    private let calendar: Calendar
    private let defaults: UserDefaults
    private let makeID: () -> String

    init(store: VanStockStore? = nil,
         medicalMode: @escaping () -> Bool = { Config.hipaaMode },
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         defaults: UserDefaults = .standard,
         makeID: @escaping () -> String = { UUID().uuidString }) {
        self.store = store ?? .shared
        self.medicalMode = medicalMode
        self.now = now
        self.calendar = calendar
        self.defaults = defaults
        self.makeID = makeID
    }

    var isAllowed: Bool { medicalMode() }

    /// Called when a check has run to the end (Plan NK, Decision 3): the daily check is one of the
    /// moments the clinic's workbook is sent its rows. Set by the app.
    var onDone: (() -> Void)?

    /// The list's column names, to choose the mapping from. Refused outside medical mode.
    func header(_ data: Data, format: ImmunisationListReader.Format) -> Result<[String], ImmunisationCheckRefusal> {
        guard medicalMode() else { return .failure(.init(sentence: Self.medicalModeRefusal)) }
        switch ImmunisationListReader.header(data, format: format) {
        case .success(let names): return .success(names)
        case .failure(let failure): return .failure(.init(sentence: failure.sentence))
        }
    }

    /// Read the list as mapped and compare it with the doses given here over `range`, or over the
    /// days the list itself covers when no range is given. The mapping is remembered (column names
    /// only) and the counts are kept for the report.
    func check(_ data: Data, format: ImmunisationListReader.Format, mapping: ImmunisationColumnMapping,
               range: StockReportRange? = nil) -> Outcome {
        guard medicalMode() else { return .refused(Self.medicalModeRefusal) }
        guard !store.isUnreadable else {
            return .refused(String(localized: "The stock list on this phone can't be read. Nothing was checked."))
        }
        let list: ImmunisationListReader.List
        switch ImmunisationListReader.read(data, format: format, mapping: mapping) {
        case .failure(let failure): return .failed(failure.sentence)
        case .success(let read): list = read
        }
        mapping.store(defaults)
        let days = list.records.map(\.day)
        guard let first = range?.first ?? days.min(), let last = range?.last ?? days.max() else {
            return .failed(ImmunisationListReader.Failure.noRows.sentence)
        }
        let log = store.log
        let doses = ImmunisationReconciliation.doses(in: log, first: first, last: last, calendar: calendar)
        let result = ImmunisationReconciliation.compare(doses: doses, records: list.records, items: log.items,
                                                        first: first, last: last, calendar: calendar)
        result.summary(ranAt: now()).store(defaults)
        onDone?()
        return .done(result, skippedRows: list.skippedRows)
    }

    /// Remember that the EMR's name or code for a vaccine means a line (Plan MY §8): kept in the
    /// line's codes, one undoable entry. False when medical mode is off, the line is gone, or it
    /// already carries that name.
    @discardableResult
    func match(vaccine: String, to itemID: String) -> Bool {
        guard medicalMode(), !store.isUnreadable else { return false }
        let at = now()
        let batch = makeID()
        return store.update { log in
            log.edit(itemID: itemID, .addCode(vaccine), at: at, batch: batch, source: .typed, id: makeID())
        } ?? false
    }
}

/// A sentence the check refused with. It never repeats a value from the file.
struct ImmunisationCheckRefusal: Error, Equatable {
    let sentence: String
}
