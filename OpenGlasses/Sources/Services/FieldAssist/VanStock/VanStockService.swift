import Foundation

/// What a technician says about the van, turned into movements and a read-back (Plan IH §3).
///
/// The tool parses arguments and the screen shows rows; this is the one place a spoken line is
/// matched, recorded and answered, so the voice and the phone cannot disagree about what a load or
/// a use means. Nothing here touches the network. Every word about the place comes from the
/// place in force (`StockPlaceWording`, Plan MK §3), so a store's list is spoken of as a store's.
@MainActor
final class VanStockService {

    static let shared = VanStockService()

    /// One spoken line: "four flame sensors, part 62-23543-01".
    struct Line: Equatable {
        var part: String?
        var description: String?
        /// In thousandths of the line's unit (`StockQuantity`).
        var quantity: StockQuantity?
        var unit: String?
        var code: String?
        /// The technician said this is a different part from the similar line already on the van.
        /// Only its number or its code may then match; its description starts a new line.
        var asNew: Bool
        /// The lot said, typed or scanned (Plan MY §1). A spoken one is matched only against the
        /// line's own lots; only a scanned one (`lotFromScan`) may add a lot, on a delivery or a
        /// count.
        var lot: String?
        /// The lot came from a scanned code, with its expiry.
        var lotFromScan: Bool
        var expiry: StockDay?
        /// Cartons received, multiplied by the line's doses per carton (Plan MY §2).
        var cartons: Int?
        /// How many doses a carton holds, for a line that does not know yet.
        var dosesPerCarton: Int?
        /// The line the scan sheet already chose; matching is skipped.
        var itemID: String?

        init(part: String? = nil, description: String? = nil, quantity: StockQuantity? = nil,
             unit: String? = nil, code: String? = nil, asNew: Bool = false, lot: String? = nil,
             lotFromScan: Bool = false, expiry: StockDay? = nil, cartons: Int? = nil,
             dosesPerCarton: Int? = nil, itemID: String? = nil) {
            self.part = part?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.quantity = quantity
            self.unit = unit?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.code = code?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.asNew = asNew
            self.lot = lot?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.lotFromScan = lotFromScan
            self.expiry = expiry
            self.cartons = cartons
            self.dosesPerCarton = dosesPerCarton.flatMap { $0 > 0 ? $0 : nil }
            self.itemID = itemID
        }

        /// What to call the line when nothing on the van matches it.
        var reference: String { part ?? description ?? "that code" }
    }

    /// The job that is open, when one is.
    struct Job: Equatable {
        let sessionID: String
        let reference: String?
    }

    /// A model that retries must not load four sensors twice: the same write inside this many
    /// seconds is one write.
    static let duplicateWindow: TimeInterval = 10

    private let store: VanStockStore
    /// A bare verifier injected the way callers before Plan MK did: it does not say which book it
    /// searched, so it records found or not checked (`VanStockLookup(legacy:)`). Nil in the app,
    /// which looks numbers up through `books`.
    private let legacyVerify: (@MainActor (String) -> TaskPart)?
    /// Where a number is looked up, by Plan MK §4's order: the job's vault, the list's named
    /// vault, or none.
    private let books: VanStockBooks
    /// The place in force (Plan MK §2): the organisation's profile over the list's own choice.
    private let placeKind: @MainActor () -> StockPlace.Kind
    /// Whether the list is a clinic's (Plan MY §9): the organisation's profile over the list's own
    /// choice.
    private let clinicalFlag: @MainActor () -> Bool
    /// The older lot is pointed out once a day per line (Plan MY §4).
    private var oldestFirst = OldestFirstReminder()
    private let partsIndex: @MainActor () -> VaultPartsIndex
    private let activeJob: @MainActor () -> Job?
    private let now: () -> Date
    private let calendar: Calendar
    private let makeID: () -> String
    /// The open job's own record of what came off the van (Plan IH P4): told of a use, of uses an
    /// undo took back, and of a part that did not come from the van.
    private let jobUses: JobUses

    /// How a use reaches the job it was recorded on.
    @MainActor
    struct JobUses {
        var record: @MainActor (VanStockUse) -> Void
        var remove: @MainActor (Set<String>) -> Void
        /// False when there is no job open to say it about.
        var notFromVan: @MainActor (String) -> Bool
        /// The names of the parts on the open job that still have no stock entry.
        var unrecorded: @MainActor () -> [TaskPart]

        static let none = JobUses(record: { _ in }, remove: { _ in }, notFromVan: { _ in false }, unrecorded: { [] })
        static let shared = JobUses(
            record: { FieldSessionService.shared.recordVanStockUse($0) },
            remove: { FieldSessionService.shared.removeVanStockUses(movementIDs: $0) },
            notFromVan: { FieldSessionService.shared.markNotFromVan(part: $0) },
            unrecorded: { FieldSessionService.shared.unrecordedVanParts })
    }

    /// The business's own stock system, as van stock needs it (Plan MM P3): the connection, its
    /// snapshot and its staged uses, and the book its figures are joined against.
    @MainActor
    struct SystemLink {
        var service: @MainActor () -> StockSystemService?
        /// The book for the join, by Plan MK §4's order; `namedVaultID` is the list's own choice.
        var book: @MainActor (_ namedVaultID: String?) -> StockSystemBook?

        static let none = SystemLink(service: { nil }, book: { _ in nil })
        static let shared = SystemLink(service: { AppStateProvider.shared?.stockSystem },
                                       book: { FieldSessionService.shared.stockSystemBook(namedVaultID: $0) })
    }

    private let systemLink: SystemLink

    private var lastWrite: (signature: String, at: Date, answer: String)?
    /// Why the write in hand was refused, as the scan sheet can say it. Only `recordScan` reads
    /// it, having cleared it first; a spoken write's answer is its sentence.
    private var scanProblem: StockScanFlow.Problem?

    init(store: VanStockStore? = nil,
         verify: (@MainActor (String) -> TaskPart)? = nil,
         books: VanStockBooks? = nil,
         place: (@MainActor () -> StockPlace.Kind)? = nil,
         partsIndex: (@MainActor () -> VaultPartsIndex)? = nil,
         activeJob: (@MainActor () -> Job?)? = nil,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         makeID: @escaping () -> String = { UUID().uuidString },
         jobUses: JobUses? = nil,
         stockSystem: SystemLink? = nil,
         clinical: (@MainActor () -> Bool)? = nil) {
        let resolvedStore = store ?? .shared
        self.store = resolvedStore
        self.legacyVerify = verify
        // A service built for a test with its own store searches no book unless it is given one.
        self.books = books ?? (store == nil ? .shared : .none)
        self.placeKind = place ?? { resolvedStore.resolvedPlace.kind }
        self.clinicalFlag = clinical ?? { resolvedStore.resolvedClinical.clinical }
        self.partsIndex = partsIndex ?? { FieldSessionService.shared.partsIndex }
        self.activeJob = activeJob ?? {
            FieldSessionService.shared.activeSession.map { Job(sessionID: $0.id, reference: $0.jobReference) }
        }
        self.now = now
        self.calendar = calendar
        self.makeID = makeID
        // A service built for a test with its own store speaks to no job unless it is given one.
        self.jobUses = jobUses ?? (store == nil ? .shared : .none)
        // Nor to a stock system.
        self.systemLink = stockSystem ?? (store == nil ? .shared : .none)
    }

    // MARK: - Who holds the count (Plan MM P3)

    /// Who answers for the place: a connected system, or the phone (`StockAuthority.resolve`).
    var authority: StockAuthority { systemLink.service()?.authority ?? .phone }

    /// The system's name while it holds the count; nil while the phone does.
    var systemName: String? {
        guard authority.isSystem, let service = systemLink.service() else { return nil }
        return service.snapshot?.source.displayName ?? service.displayName
    }

    /// `van_stock` as the system answers it, while a system holds the count. The phone's own list
    /// is then the previous list: kept, read-only, and never written (Decision 3).
    var systemDesk: StockSystemVanStock? {
        let authority = self.authority
        guard case .system(let connectorID, let here) = authority, let service = systemLink.service() else { return nil }
        let snapshot = service.snapshot.flatMap { $0.source.connectorID == connectorID ? $0 : nil }
        return StockSystemVanStock(
            snapshot: snapshot, system: snapshot?.source.displayName ?? service.displayName, connectorID: connectorID,
            here: here, capabilities: service.capabilities, staged: service.staged, kind: place,
            job: activeJob().map { .init(sessionID: $0.sessionID, reference: $0.reference) },
            book: systemLink.book(store.van?.checkVaultID), now: now(), calendar: calendar, makeID: makeID)
    }

    /// A check that may first ask the system for just the lines asked about (Decision 10): when
    /// a system holds the count and its figures for them are over ten minutes old, with signal,
    /// within three seconds. Otherwise, and after, the same answer as `check(_:)`.
    func checkNow(_ line: Line) async -> String {
        if let desk = systemDesk, let service = systemLink.service() {
            let ids = desk.itemIDs(for: line)
            if !ids.isEmpty { _ = await service.checkNow(itemIDs: ids) }
        }
        return check(line)
    }

    /// One noting of uses while the system holds the count, with the same retry guard as a write.
    private func stage(_ action: String, _ lines: [Line], _ run: () -> (answer: String, done: [String])) -> String {
        let at = now()
        let signature = "system:" + action + "|" + lines.map {
            "\($0.part ?? "")~\($0.description ?? "")~\($0.quantity.map { String($0.scaled) } ?? "")~\($0.unit ?? "")~\($0.code ?? "")"
        }.joined(separator: "|")
        if let last = lastWrite, last.signature == signature, at.timeIntervalSince(last.at) < Self.duplicateWindow {
            return "Already noted a moment ago, not noted twice. " + last.answer
        }
        let result = run()
        let answer = Self.saying(result.answer, result.done)
        lastWrite = result.done.isEmpty ? nil : (signature, at, answer)
        return answer
    }

    /// The place in force for this list (Plan MK §2), read fresh each time so a place changed on
    /// the screen is in the next sentence and the next turn's tool description.
    var place: StockPlace.Kind { placeKind() }

    /// Whether the list is a clinic's, read fresh like the place.
    var isClinical: Bool { clinicalFlag() }

    /// The words for that place.
    var wording: StockPlaceWording { StockPlaceWording(place, clinical: isClinical) }

    /// The job a movement is recorded against: none on a clinic's list (Plan NJ §1), so no job
    /// reference, session or job record ever joins a dose. A van's movement takes the open job.
    private func movementJob() -> Job? { isClinical ? nil : activeJob() }

    /// The staff code kept on a clinic's movement (Plan NJ Decision 3): only on a clinic's list,
    /// and only a code `StaffCode` takes. Never on a van's.
    private func keptStaffCode(_ raw: String?) -> String? { isClinical ? StaffCode.clean(raw) : nil }

    private var lotComposer: StockLotComposer { StockLotComposer(wording: wording) }

    /// Today, as an expiry is compared with it.
    private var today: StockDay { StockDay(now(), calendar: calendar) }

    private var composer: VanStockAnswerComposer {
        VanStockAnswerComposer(now: now(), calendar: calendar, wording: wording)
    }

    private var unreadable: String {
        let w = wording
        return "The \(w.stockName) list on this phone could not be read, so nothing "
            + "was looked up or changed. Tell \(w.person); do not guess what is \(w.location)."
    }

    // MARK: - Reading

    func check(_ line: Line) -> String {
        if let desk = systemDesk { return desk.check(line) }
        guard !store.isUnreadable else { return unreadable }
        let log = store.log
        guard !log.isEmpty else { return composer.emptyVan() }
        switch match(line, in: log) {
        case .one(let item):
            let level = log.level(of: item.id)
            let answer = composer.check(item, level: level)
            guard let lots = lotComposer.lotsSummary(item, lots: log.lots(of: item.id), levels: level.lots,
                                                     today: today, calendar: calendar) else { return answer }
            return answer + " " + lots
        case .several(let items): return composer.candidates(items, levels: log.levels)
        // Not "none on the van": the line that sounds like it is read out, to be asked about.
        case .near(let items): return composer.closest(items, to: line.reference, levels: log.levels)
        case .none: return composer.notCarried(line.reference)
        }
    }

    /// What is there: everything, or the lines in the bins `bin` names (Plan MK §8). Writes
    /// nothing.
    func list(bin: String?) -> String {
        if let desk = systemDesk { return desk.list(bin: bin) }
        guard !store.isUnreadable else { return unreadable }
        return composer.list(store.log, bin: bin)
    }

    func low() -> String {
        if let desk = systemDesk { return desk.low() }
        guard !store.isUnreadable else { return unreadable }
        let log = store.log
        guard !log.isEmpty else { return composer.emptyVan() }
        let levels = log.levels
        return composer.low(log.lowItems.map { (item: $0, level: levels[$0.id] ?? VanStockLevel(itemID: $0.id)) })
    }

    // MARK: - Writing

    func load(_ lines: [Line], source: VanStockMovement.Source = .spoken) -> String {
        if let desk = systemDesk { return desk.composer.refused(.load) }
        return write("load", lines) { log, said, batch, at in
            let line: Line
            switch self.scanned(said, in: log) {
            case .failure(let refusal): return (refusal.sentence, nil)
            case .success(let read): line = read
            }
            var quantity = line.quantity ?? StockQuantity(whole: 1)
            if let cartons = line.cartons {
                // Cartons are counted in doses (Plan MY §2): the line's size, or the one said now.
                guard cartons > 0 else { return ("Nothing \(self.wording.putVerb) for \(line.reference): the quantity has to be at least 1.", nil) }
                let known = self.matchedItem(line, in: log, mayCreate: true)?.dosesPerCarton
                guard let perCarton = known ?? line.dosesPerCarton else {
                    if let item = self.matchedItem(line, in: log, mayCreate: true) { return (self.lotComposer.noCartonSize(item), nil) }
                    return ("Say how many \(self.wording.goods) a carton of \(line.reference) holds ('doses_per_carton'). Nothing was recorded.", nil)
                }
                guard cartons <= StockQuantity.maximumUnits / perCarton else { return ("Nothing \(self.wording.putVerb) for \(line.reference): \(Self.tooLarge).", nil) }
                quantity = StockQuantity(whole: cartons * perCarton)
            }
            guard quantity > .zero else { return ("Nothing loaded for \(line.reference): the quantity has to be at least 1.", nil) }
            guard quantity.isInRange else { return ("Nothing loaded for \(line.reference): \(Self.tooLarge).", nil) }
            if let refusal = self.stepRefusal(quantity, line, in: log, mayCreate: true, verb: "loaded") { return (refusal, nil) }
            // A lot refused after the line was matched leaves the list as it was.
            let snapshot = log
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: true) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let lotsBefore = log.lots.count
                let lot: StockLot?
                switch self.lotChoice(.receive, item: found.item, line: line, log: &log, batch: batch, at: at) {
                case .failure(let refusal):
                    log = snapshot
                    return (refusal.sentence, nil)
                case .success(let chosen): lot = chosen
                }
                let before = log.level(of: found.item.id)
                let job = self.movementJob()
                log.record(.loaded, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID(), jobSessionID: job?.sessionID,
                           jobReference: job?.reference, lotID: lot?.id)
                let item = log.item(id: found.item.id) ?? found.item
                if lot != nil || self.wording.clinical {
                    var answer = self.lotComposer.received(item, quantity: quantity, lot: lot,
                                                           newLot: log.lots.count > lotsBefore,
                                                           after: log.level(of: item.id))
                    if found.created { answer += " " + self.composer.newLineNote(item) }
                    return (answer, "\(self.wording.amount(quantity, of: item)) \(self.wording.putVerb)"
                        + (lot.map { ", \(self.wording.lotNoun) \($0.code)" } ?? ""))
                }
                return (self.composer.loaded(item, quantity: quantity, before: before,
                                             after: log.level(of: item.id), created: found.created),
                        "\(item.phrase(quantity)) \(self.wording.putThere)")
            }
        }
    }

    func use(_ lines: [Line], source: VanStockMovement.Source = .spoken) -> String {
        // A system-held place notes the use for the system and writes no movement of its own.
        if let desk = systemDesk { return stage("use", lines) { desk.use(lines, source: source) } }
        return write("use", lines) { log, said, batch, at in
            let line: Line
            switch self.scanned(said, in: log) {
            case .failure(let refusal): return (refusal.sentence, nil)
            case .success(let read): line = read
            }
            let quantity = line.quantity ?? StockQuantity(whole: 1)
            guard quantity > .zero else { return ("Nothing recorded for \(line.reference): the quantity has to be at least 1.", nil) }
            guard quantity.isInRange else { return ("Nothing recorded for \(line.reference): \(Self.tooLarge).", nil) }
            if let refusal = self.stepRefusal(quantity, line, in: log, mayCreate: false, verb: "recorded") { return (refusal, nil) }
            // A lot refused after the line was matched leaves the list as it was.
            let snapshot = log
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: false) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let lot: StockLot?
                switch self.lotChoice(.give, item: found.item, line: line, log: &log, batch: batch, at: at) {
                case .failure(let refusal):
                    log = snapshot
                    return (refusal.sentence, nil)
                case .success(let chosen): lot = chosen
                }
                let before = log.level(of: found.item.id)
                let job = self.movementJob()
                let movement = log.record(.used, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                                          source: source, id: self.makeID(), jobSessionID: job?.sessionID,
                                          jobReference: job?.reference, lotID: lot?.id)
                if job != nil, let movement {
                    self.jobUses.record(VanStockUse(id: movement.id, number: found.item.number,
                                                    description: found.item.description, quantity: quantity,
                                                    unit: found.item.unit, verified: found.item.verification.isFound, at: at))
                }
                if lot != nil || self.wording.clinical {
                    let older = lot.flatMap { lot -> StockLot? in
                        guard let older = StockExpiry.older(than: lot, among: log.lots(of: found.item.id), levels: before.lots),
                              self.oldestFirst.shouldSay(itemID: found.item.id, today: self.today) else { return nil }
                        return older
                    }
                    return (self.lotComposer.given(found.item, quantity: quantity, lot: lot,
                                                   after: log.level(of: found.item.id), older: older),
                            self.lotComposer.givenDone(found.item, quantity: quantity, lot: lot))
                }
                return (self.composer.used(found.item, quantity: quantity, before: before,
                                           after: log.level(of: found.item.id), jobReference: job?.reference),
                        "\(found.item.phrase(quantity)) \(self.wording.takenFrom)" + (job?.reference.map { " for job \($0)" } ?? ""))
            }
        }
    }

    func remove(_ lines: [Line], reason: VanStockMovement.RemovalReason,
                source: VanStockMovement.Source = .spoken, staffCode: String? = nil) -> String {
        if let desk = systemDesk {
            guard let kept = desk.keptReason(for: reason) else {
                return desk.composer.removalNotKept(keepsDamage: desk.keptReason(for: .damaged) != nil)
            }
            return stage("remove:\(reason.rawValue)", lines) { desk.use(lines, source: source, writeOff: kept) }
        }
        return write("remove:\(reason.rawValue)", lines) { log, said, batch, at in
            let line: Line
            switch self.scanned(said, in: log) {
            case .failure(let refusal): return (refusal.sentence, nil)
            case .success(let read): line = read
            }
            let quantity = line.quantity ?? StockQuantity(whole: 1)
            guard quantity > .zero else { return ("Nothing removed for \(line.reference): the quantity has to be at least 1.", nil) }
            guard quantity.isInRange else { return ("Nothing removed for \(line.reference): \(Self.tooLarge).", nil) }
            if let refusal = self.stepRefusal(quantity, line, in: log, mayCreate: false, verb: "removed") { return (refusal, nil) }
            // A lot refused after the line was matched leaves the list as it was.
            let snapshot = log
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: false) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let lot: StockLot?
                switch self.lotChoice(.remove, item: found.item, line: line, log: &log, batch: batch, at: at) {
                case .failure(let refusal):
                    log = snapshot
                    return (refusal.sentence, nil)
                case .success(let chosen): lot = chosen
                }
                let before = log.level(of: found.item.id)
                log.record(.removed, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID(), reason: reason, lotID: lot?.id,
                           staffCode: self.keptStaffCode(staffCode))
                return (self.composer.removed(found.item, quantity: quantity, reason: reason, before: before,
                                              after: log.level(of: found.item.id)),
                        "\(found.item.phrase(quantity)) \(self.wording.takenFrom) (\(reason.rawValue))")
            }
        }
    }

    /// Doses or stock thrown out, for a reason (Plan MY §3): its own kind, never a removal. An
    /// expired lot may be wasted; that is what the expired refusal on a dose given offers.
    func waste(_ lines: [Line], reason: VanStockMovement.WasteReason,
               source: VanStockMovement.Source = .spoken, staffCode: String? = nil) -> String {
        if systemDesk != nil {
            return "\(StockPlaceWording.capitalised(wording.stockName)) here is held by the business's own system, "
                + "so waste is recorded there, not on the phone. Nothing was changed."
        }
        return write("waste:\(reason.rawValue)", lines) { log, said, batch, at in
            let line: Line
            switch self.scanned(said, in: log) {
            case .failure(let refusal): return (refusal.sentence, nil)
            case .success(let read): line = read
            }
            let quantity = line.quantity ?? StockQuantity(whole: 1)
            guard quantity > .zero else { return ("Nothing \(self.wording.wastedVerb) for \(line.reference): the quantity has to be at least 1.", nil) }
            guard quantity.isInRange else { return ("Nothing \(self.wording.wastedVerb) for \(line.reference): \(Self.tooLarge).", nil) }
            if let refusal = self.stepRefusal(quantity, line, in: log, mayCreate: false, verb: self.wording.wastedVerb) { return (refusal, nil) }
            // A lot refused after the line was matched leaves the list as it was.
            let snapshot = log
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: false) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let lot: StockLot?
                switch self.lotChoice(.waste, item: found.item, line: line, log: &log, batch: batch, at: at) {
                case .failure(let refusal):
                    log = snapshot
                    return (refusal.sentence, nil)
                case .success(let chosen): lot = chosen
                }
                log.record(.wasted, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID(), lotID: lot?.id, wasteReason: reason,
                           staffCode: self.keptStaffCode(staffCode))
                return (self.lotComposer.wasted(found.item, quantity: quantity, reason: reason, lot: lot,
                                                after: log.level(of: found.item.id)),
                        self.lotComposer.wastedDone(found.item, quantity: quantity, reason: reason, lot: lot))
            }
        }
    }

    func count(_ lines: [Line], source: VanStockMovement.Source = .spoken, staffCode: String? = nil) -> String {
        if let desk = systemDesk { return desk.composer.refused(.count) }
        return write("count", lines) { log, said, batch, at in
            let line: Line
            switch self.scanned(said, in: log) {
            case .failure(let refusal): return (refusal.sentence, nil)
            case .success(let read): line = read
            }
            guard let quantity = line.quantity else { return ("Say how many \(line.reference) were counted.", nil) }
            guard quantity >= .zero else { return ("Nothing counted for \(line.reference): a count cannot be below zero.", nil) }
            guard quantity.isInRange else { return ("Nothing counted for \(line.reference): \(Self.tooLarge).", nil) }
            if let refusal = self.stepRefusal(quantity, line, in: log, mayCreate: true, verb: "counted") { return (refusal, nil) }
            // A lot refused after the line was matched leaves the list as it was.
            let snapshot = log
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: true) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let lotsBefore = log.lots.count
                let chosenLot: StockLot?
                switch self.lotChoice(.count, item: found.item, line: line, log: &log, batch: batch, at: at) {
                case .failure(let refusal):
                    log = snapshot
                    return (refusal.sentence, nil)
                case .success(let chosen): chosenLot = chosen
                }
                if let lot = chosenLot {
                    // A count of one lot (Plan MY §6), checked against what the log held in it.
                    let lotBefore = log.level(of: found.item.id).lots[lot.id] ?? StockLotLevel(lotID: lot.id)
                    let check = VanStockCountCheck(before: lotBefore, counted: quantity)
                    log.record(.counted, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                               source: source, id: self.makeID(), lotID: lot.id,
                               staffCode: Self.disagrees(check) ? self.keptStaffCode(staffCode) : nil)
                    let after = log.level(of: found.item.id)
                    let item = log.item(id: found.item.id) ?? found.item
                    var answer = self.lotComposer.lotCounted(item, lot: lot, newLot: log.lots.count > lotsBefore,
                                                             check: check, after: after)
                    if found.created { answer += " " + self.composer.newLineNote(item) }
                    return (answer, "\(item.name) \(self.wording.lotNoun) \(lot.code) counted: "
                        + self.wording.figure(quantity, of: item) + (check?.said(item.unit) ?? ""))
                }
                let before = log.level(of: found.item.id)
                log.record(.counted, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID(),
                           staffCode: Self.disagrees(VanStockCountCheck(before: before, counted: quantity))
                               ? self.keptStaffCode(staffCode) : nil)
                let after = log.level(of: found.item.id)
                let check = VanStockCountCheck(before: before, counted: after.onHand)
                return (self.composer.counted(found.item, before: before, after: after, created: found.created),
                        "\(found.item.name) counted: \(found.item.figure(after.onHand)) \(self.wording.location)" + (check?.said(found.item.unit) ?? ""))
            }
        }
    }

    /// Whether a count disagreed with the log (Plan NJ Decision 3): short or over. A count that
    /// matched, or one with nothing to compare, keeps no staff code.
    nonisolated static func disagrees(_ check: VanStockCountCheck?) -> Bool {
        switch check {
        case .short?, .over?: return true
        case .matches?, .unreliable?, nil: return false
        }
    }

    /// Take back the most recent batch.
    func undo(source: VanStockMovement.Source = .spoken) -> String {
        if let desk = systemDesk {
            lastWrite = nil
            let result = desk.undo()
            return Self.saying(result.answer, result.done)
        }
        guard !store.isUnreadable else { return unreadable }
        lastWrite = nil
        let at = now()
        let undone = store.update { $0.undoLastBatch(at: at, batch: self.makeID(), source: source, makeID: self.makeID) }
        guard let undone = undone ?? nil else { return composer.nothingToUndo() }
        let uses = Set(undone.movements.filter { $0.kind == .used }.map(\.id))
        if !uses.isEmpty { jobUses.remove(uses) }
        return Self.saying(composer.undone(undone, items: store.log.items), ["the last \(wording.stockName) entry taken back"])
    }

    // MARK: - The job's own account

    /// Parts on the open job's finished tasks with no stock entry, for the model to ask about.
    /// These follow an open job, not the place (Plan MK §5): a workshop's car on the hoist is a
    /// job, and a shop that never opens one is told there is none.
    func unrecorded() -> String {
        let w = wording
        let parts = jobUses.unrecorded()
        guard !parts.isEmpty else {
            guard activeJob() != nil else {
                return "There is no job open, so there are no parts on one to check. Nothing was changed."
            }
            return "Every part on this job's finished tasks has a \(w.stockName) entry, or was said not to have \(w.comeFrom)."
        }
        return "No \(w.stockName) entry on this job for " + VanStockReconciler.named(parts)
            + ". Ask \(w.person) whether each \(w.cameFrom); do not record a use they did not confirm."
    }

    /// The technician said a part on the open job did not come off the van.
    func notFromVan(_ line: Line) -> String {
        let w = wording
        guard let part = line.part else { return "Say which part did not \(w.comeFrom), by its part number." }
        guard jobUses.notFromVan(part) else { return "There is no job open to say that about. Nothing was changed." }
        let number = VaultPartsIndex.normalise(part)
        return Self.saying("Noted: \(number) did not \(w.comeFrom) on this job. \(StockPlaceWording.capitalised(w.list)) is unchanged.",
                           ["\(number) noted as \(w.notFrom)"])
    }

    // MARK: - From the screen

    /// Whether there is an entry to take back.
    var canUndo: Bool { !authority.isSystem && !store.isUnreadable && store.log.canUndo }

    /// A count typed on the Van Stock screen. False when nothing was recorded.
    @discardableResult
    func setCount(itemID: String, to quantity: StockQuantity) -> Bool {
        guard !authority.isSystem else { return false }
        // A line with stock in its lots is counted lot by lot (Plan MY §6), never as one figure
        // the lots could not be told from.
        guard !hasLotsInStock(itemID) else { return false }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let recorded = store.update { log in
            log.record(.counted, itemID: itemID, quantity: quantity, at: at, batch: batch,
                       source: .typed, id: self.makeID()) != nil
        }
        return recorded ?? false
    }

    /// Changes typed on the Van Stock screen, as one batch. A new part number is looked up again,
    /// so a corrected number is not left marked as verified on the strength of the old one. A
    /// change of unit that `unitChangeRefusal` refuses is left out, and the rest still apply.
    @discardableResult
    func edit(itemID: String, _ changes: [VanStockLog.Change]) -> Bool {
        guard !authority.isSystem else { return false }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let changed = store.update { log -> Bool in
            var any = false
            for change in changes {
                any = log.edit(itemID: itemID, change, at: at, batch: batch, source: .typed, id: self.makeID()) || any
                if case .number(let number) = change {
                    let verification = number.map { self.lookUp($0).verification } ?? .notChecked
                    any = log.edit(itemID: itemID, .verification(verification), at: at, batch: batch,
                                   source: .typed, id: self.makeID()) || any
                }
            }
            return any
        }
        return changed ?? false
    }

    /// What stops a line being deleted from the screen.
    enum DeletionBlock: Equatable {
        /// A business's own system holds the count, so the phone's list is not written.
        case systemHolds
        /// The list can't be read, or has no such line.
        case unavailable
        /// A clinic's line with doses given or wasted from it: they belong in the stock report,
        /// which reads only lines on the list.
        case clinicalRecord
    }

    /// Why the line can't be deleted now, or nil when it can.
    func deletionBlock(itemID: String) -> DeletionBlock? {
        if authority.isSystem { return .systemHolds }
        guard !store.isUnreadable, store.log.item(id: itemID) != nil else { return .unavailable }
        if isClinical && store.log.hasGivenOrWasted(itemID) { return .clinicalRecord }
        return nil
    }

    /// Delete one line from the Van Stock screen, as its own batch, so Undo puts it back. False
    /// when nothing was deleted (`deletionBlock`).
    @discardableResult
    func deleteLine(itemID: String) -> Bool {
        guard deletionBlock(itemID: itemID) == nil else { return false }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let deleted = store.update { log in
            log.deleteItem(itemID, at: at, batch: batch, source: .typed, id: self.makeID()) != nil
        }
        return deleted ?? false
    }

    // MARK: - The shift (Plan IH P5)

    /// Why a line cannot be counted in `unit` now, or nil when it can: a unit counted whole while
    /// a figure on the line is part of one (`VanStockLog.unitChangeRefusal`).
    func unitChangeRefusal(itemID: String, to unit: VanStockUnit) -> String? {
        guard !store.isUnreadable else { return nil }
        return store.log.unitChangeRefusal(itemID: itemID, to: unit)
    }

    /// Which figure stops a line being counted in `unit` now, or nil when none does, for the
    /// screen to word (`VanStockLog.unitChangeBlock`).
    func unitChangeBlock(itemID: String, to unit: VanStockUnit) -> VanStockLog.UnitChangeBlock? {
        guard !store.isUnreadable else { return nil }
        return store.log.unitChangeBlock(itemID: itemID, to: unit)
    }

    /// The tail of a refusal for a figure over a million units.
    private static var tooLarge: String { StockQuantityRefusal.tooLarge.sentence(for: .each) }

    /// What it takes to bring the van back to its standard load: at premises, its par level.
    func topUp() -> String {
        if let desk = systemDesk { return desk.composer.refused(.topUp) }
        guard !store.isUnreadable else { return unreadable }
        let w = wording
        let log = store.log
        guard !log.isEmpty else { return composer.emptyVan() }
        let shortfalls = VanStockHandover.topUp(log)
        let measured = VanStockHandover.hasStandards(log)
        guard !shortfalls.isEmpty else {
            return measured ? "Nothing to top up: every line is at its \(w.usualFigure)."
                            : "Nothing has run out. No \(w.usualFigure) is set for \(w.this), so there is nothing to top up to."
        }
        let listed = shortfalls.map { shortfall in
            shortfall.short.map { "\(shortfall.item.phrase($0)) (\(shortfall.item.figure(shortfall.onHand)) \(w.aboard))" }
                ?? "\(shortfall.item.name) (\(shortfall.item.figure(shortfall.onHand)) \(w.aboard))"
        }
        let lead = measured ? "\(shortfalls.count) to top up"
                            : "No \(w.usualFigure) is set for \(w.this); \(shortfalls.count) have run out or are below minimum"
        return "\(lead): " + listed.joined(separator: "; ") + "."
    }

    /// "Topped up everything except the flame sensors": every short line but those is brought to
    /// its standard load, as one batch that one undo takes back.
    func loadToStandard(except exceptions: [Line] = [], source: VanStockMovement.Source = .spoken) -> String {
        if let desk = systemDesk { return desk.composer.refused(.topUp) }
        guard !store.isUnreadable else { return unreadable }
        let w = wording
        lastWrite = nil
        let at = now()
        let batch = makeID()
        var skipped: [VanStockItem] = []
        var unmatched: [String] = []
        var filled = 0
        // An exception that only sounds like a line is asked about before anything is loaded:
        // leaving the wrong line short is as much a change as loading it.
        for line in exceptions {
            if case .near(let items) = match(line, in: store.log) {
                return composer.misheard(items, reference: line.reference, levels: store.log.levels, mayCreate: false)
                    + " Once they say, record the top-up again, naming the part as \(w.list) has it."
            }
        }
        store.update { log in
            for line in exceptions {
                switch self.match(line, in: log) {
                case .one(let item): skipped.append(item)
                case .several(let items): skipped.append(contentsOf: items)
                case .near, .none: unmatched.append(line.reference)
                }
            }
            let left = Set(skipped.map(\.id))
            for shortfall in VanStockHandover.topUp(log) {
                guard let short = shortfall.short, !left.contains(shortfall.item.id) else { continue }
                log.record(.loaded, itemID: shortfall.item.id, quantity: short, at: at, batch: batch,
                           source: source, id: self.makeID())
                filled += 1
            }
        }
        guard VanStockHandover.hasStandards(store.log) else {
            return "No \(w.usualFigure) is set for \(w.this), so there is nothing to top up to. Nothing was changed."
        }
        var lines = [filled == 0 ? "Nothing was short of its \(w.usualFigure), so nothing was \(w.putVerb)."
                                 : "\(filled) \(filled == 1 ? "line" : "lines") brought to the \(w.usualFigure)."]
        if !skipped.isEmpty { lines.append("Left as they were: " + skipped.map(\.name).joined(separator: "; ") + ".") }
        if !unmatched.isEmpty {
            lines.append("Not on \(w.list), so not treated as an exception: " + unmatched.joined(separator: "; ") + ".")
        }
        if filled > 0 {
            lines.append("\(StockPlaceWording.capitalised(w.person)) can say 'undo that' to take the whole top-up back.")
        }
        return Self.saying(lines.joined(separator: " "),
                           filled > 0 ? ["\(filled) \(filled == 1 ? "line" : "lines") brought to the \(w.usualFigure)"] : [])
    }

    /// Set what the van should carry of one line. Set by the technician, so it is this truck's own.
    func setStandard(_ line: Line) -> String {
        if let desk = systemDesk { return desk.composer.refused(.setStandard) }
        guard !store.isUnreadable else { return unreadable }
        let w = wording
        guard let quantity = line.quantity, quantity >= .zero else { return "Say how many \(line.reference) \(w.shouldHold)." }
        guard quantity.isInRange else { return "Nothing was changed for \(line.reference): \(Self.tooLarge)." }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        var answer = composer.notOnVan(line.reference)
        var done: [String] = []
        store.update { log in
            switch self.match(line, in: log) {
            case .several(let items): answer = self.composer.candidates(items, levels: log.levels)
            case .near(let items):
                answer = self.composer.misheard(items, reference: line.reference, levels: log.levels, mayCreate: false)
            case .none: break
            case .one(let item) where quantity != .zero && !quantity.fits(item.unit):
                answer = Self.standardRefusal(item.name, unit: item.unit, wording: w) + " Nothing was changed."
            case .one(let item):
                log.edit(itemID: item.id, .standard(quantity == .zero ? nil : quantity, setBy: .van), at: at,
                         batch: batch, source: .spoken, id: self.makeID())
                answer = quantity == .zero ? "\(item.name) has no \(w.usualFigure) now."
                                           : "The \(w.usualFigure) for \(w.setByList) is now \(item.phrase(quantity))."
                done = [quantity == .zero ? "no \(w.usualFigure) for \(item.name) now"
                                      : "the \(w.usualFigure) set to \(item.phrase(quantity))"]
            }
        }
        return Self.saying(answer, done)
    }

    /// A standard the line's unit cannot hold: "No standard load set for Wire nuts: packs are
    /// counted whole."
    static func standardRefusal(_ name: String, unit: VanStockUnit, reason: StockQuantityRefusal = .notWhole,
                                wording w: StockPlaceWording) -> String {
        "No \(w.usualFigure) set for \(name): \(reason.sentence(for: unit))."
    }

    /// What `send_to_base` says before anything is staged: parts with no stock entry, and the
    /// day's extras still on board. Nil when there is nothing left to ask. Premises are asked
    /// about the open job's parts, as a vehicle is, and never about extras: their stock does not
    /// travel (Plan MK §5).
    func handoverQuestions() -> String? {
        let w = wording
        var lines: [String] = []
        let parts = jobUses.unrecorded()
        if !parts.isEmpty {
            lines.append("Before the stock is sent: there is no \(w.stockName) entry on the open job for "
                + VanStockReconciler.named(parts) + ". Ask whether each \(w.cameFrom).")
        }
        if w.family == .vehicle {
            let extras = VanStockHandover.surplus(store.log, since: VanStockHandover.shiftStart(store.log, now: now(), calendar: calendar))
            if !extras.isEmpty, let question = w.extrasQuestion(extras.map { $0.item.phrase($0.extra) }.joined(separator: "; ")) {
                lines.append(question)
            }
        }
        guard !lines.isEmpty else { return nil }
        lines.append("Then call send_to_base again with 'answered' true.")
        return lines.joined(separator: " ")
    }

    /// The text that goes to base with the workbook.
    func handoverMessage() -> String {
        VanStockHandover.message(store.log, van: store.van, now: now(), calendar: calendar, kind: place)
    }

    /// Take a van over from a workbook: its list replaces the phone's.
    func takeOver(_ takeover: VanStockHandover.Takeover) {
        guard !authority.isSystem else { return }
        lastWrite = nil
        store.replace(with: takeover.log, van: takeover.van)
    }

    /// Read a workbook as a van to take over.
    func takeover(from sheets: [XLSXReader.Sheet]) -> Result<VanStockHandover.Takeover, VanStockSheet.Failure> {
        VanStockHandover.takeover(from: sheets, at: now(), batch: makeID(), makeID: makeID)
    }

    /// Apply base's baseline to this van's standards, as one batch.
    @discardableResult
    func apply(baseline changes: [VanStockHandover.BaselineChange], takingBaseFigure: Set<String> = []) -> Bool {
        guard !authority.isSystem else { return false }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let before = store.log
        store.update { log in
            VanStockHandover.apply(changes, to: &log, takingBaseFigure: takingBaseFigure, at: at,
                                   batch: batch, makeID: self.makeID)
        }
        return store.log != before
    }

    // MARK: - The spreadsheet

    /// The van's stock as a workbook, written to a temporary file for the share sheet. The caller
    /// removes it once the share is finished. Nil when there is nothing readable to export.
    func exportFile() -> URL? {
        guard !store.isUnreadable else { return nil }
        let at = now()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-export-\(makeID())", isDirectory: true)
        let kind = place
        // Named for the place, as the sheet inside it is (Plan MK §3): "Store stock 2026-11-19.xlsx".
        let url = folder.appendingPathComponent(VanStockSheet.fileName(exportedAt: at, calendar: calendar, kind: kind))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A clinic's list leaves inventory-only (Plan NJ §2): by day, no times, no jobs.
            try VanStockSheet.data(store.log, van: store.van, exportedAt: at, calendar: calendar, kind: kind,
                                   clinical: isClinical)
                .write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    /// Apply a reviewed workbook as one batch, so one undo takes the whole import back.
    @discardableResult
    func apply(_ proposal: VanStockSheet.Proposal, keepingPhoneFigure: Set<String> = []) -> Bool {
        guard !authority.isSystem else { return false }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let before = store.log
        store.update { log in
            VanStockSheet.apply(proposal, to: &log, keepingPhoneFigure: keepingPhoneFigure, at: at,
                                batch: batch, verify: { self.lookUp($0).part }, makeID: self.makeID)
        }
        return store.log != before
    }

    /// A replacement was asked for: the van now knows something is coming. Nil when the part is
    /// not a line on the van — an order never creates one. A parts request counts whole parts
    /// (Plan ML Decision 8), so the order is that many whole units of the line: 5 is 5,000
    /// thousandths. An order for more than a million is not noted.
    @discardableResult
    func noteOrdered(number: String, quantity: Int, requestID: String) -> String? {
        // A system-held place's orders are the system's: the previous list is never written.
        guard !authority.isSystem, !store.isUnreadable, quantity <= StockQuantity.maximumUnits else { return nil }
        let ordered = StockQuantity(whole: max(quantity, 1))
        let at = now()
        let batch = makeID()
        let recorded = store.update { log -> (item: VanStockItem, level: VanStockLevel)? in
            guard case .one(let item) = VanStockMatcher(items: log.items, partsIndex: self.partsIndex())
                .match(number: number) else { return nil }
            log.record(.ordered, itemID: item.id, quantity: ordered, at: at, batch: batch,
                       source: .spoken, id: self.makeID(), requestID: requestID)
            return (item, log.level(of: item.id))
        } ?? nil
        let w = wording
        // "5 litres asked for" on a measured line; each and pack read as they always have.
        return recorded.map {
            "\(StockPlaceWording.capitalised(w.list)) now shows \($0.item.figure($0.level.onOrder)) asked for and not yet \(w.putVerb)."
        }
    }

    // MARK: - The unit a figure is read in

    /// The unit a spoken line's figure is kept in, and what to call the line in a refusal: the
    /// line it names on the list, by the same match the write makes; otherwise the unit that was
    /// said; otherwise each. The tool reads the model's figure against this before anything is
    /// written, so 4.25 is taken for Engine oil in litres and refused for Wire nuts in packs.
    /// `mayCreate` is true for a load or a count, which match a line said to be new by its number
    /// or code only, as `target` does. Writes nothing.
    func quantityUnit(for line: Line, mayCreate: Bool) -> (unit: VanStockUnit, name: String) {
        if let desk = systemDesk { return desk.quantityUnit(for: line) }
        guard !store.isUnreadable else {
            return (line.unit.flatMap(VanStockUnit.init(spoken:)) ?? .each, line.reference)
        }
        return unit(of: line, in: store.log, mayCreate: mayCreate)
    }

    private func unit(of line: Line, in log: VanStockLog, mayCreate: Bool) -> (unit: VanStockUnit, name: String) {
        if case .one(let item) = match(line, in: log, byWords: !(mayCreate && line.asNew)) {
            return (item.unit, item.name)
        }
        return (line.unit.flatMap(VanStockUnit.init(spoken:)) ?? .each, line.reference)
    }

    /// The refusal for a figure the line's unit cannot hold ("Nothing loaded for Wire nuts: packs
    /// are counted whole."), or nil when it fits. The tool reads every figure against the line's
    /// unit first; this keeps a caller that did not from having its figure dropped without a word.
    private func stepRefusal(_ quantity: StockQuantity, _ line: Line, in log: VanStockLog,
                             mayCreate: Bool, verb: String) -> String? {
        let (unit, name) = unit(of: line, in: log, mayCreate: mayCreate)
        guard !quantity.fits(unit) else { return nil }
        return "Nothing \(verb) for \(name): \(StockQuantityRefusal.notWhole.sentence(for: unit))."
    }

    // MARK: - One write

    /// One spoken write: `apply` returns, per line, its answer and — when it changed the van — what
    /// the reply must say was done (`saying(_:_:)`).
    private func write(_ action: String, _ lines: [Line],
                       _ apply: (inout VanStockLog, Line, _ batch: String, _ at: Date) -> (answer: String, done: String?)) -> String {
        guard !store.isUnreadable else { return unreadable }
        guard !lines.isEmpty else { return "Say which part, and how many." }

        let at = now()
        let signature = action + "|" + lines.map {
            "\($0.part ?? "")~\($0.description ?? "")~\($0.quantity.map { String($0.scaled) } ?? "")~\($0.unit ?? "")~\($0.code ?? "")~\($0.asNew)"
                + "~\($0.lot ?? "")~\($0.cartons.map(String.init) ?? "")~\($0.itemID ?? "")"
        }.joined(separator: "|")
        if let last = lastWrite, last.signature == signature,
           at.timeIntervalSince(last.at) < Self.duplicateWindow {
            return "Already recorded a moment ago, not recorded twice. " + last.answer
        }

        let batch = makeID()
        let answers = store.update { log in lines.map { apply(&log, $0, batch, at) } } ?? []
        let answer = Self.saying(answers.map(\.answer).joined(separator: "\n"), answers.compactMap(\.done))
        lastWrite = (signature, at, answer)
        return answer
    }

    // MARK: - What the reply says was done (Plan KR P7)

    /// Opens the line a stock change's result ends with.
    static let sayPrefix = "Say: "

    /// `answer`, ending with the one line the reply must carry when something on the van changed
    /// (Plan KR P7, owner decision 7). In the partner's run a part came off the van in the same
    /// breath as a question about a test; the stock was recorded and the reply answered only the
    /// question. Worded like `set_job_reference`'s confirmation: what was done, said as done.
    /// Nothing changed, nothing to say: `answer` unchanged.
    static func saying(_ answer: String, _ done: [String]) -> String {
        guard !done.isEmpty else { return answer }
        return answer + "\n" + sayPrefix + done.joined(separator: "; ")
            + ". Put this in the reply, whatever else the technician asked this turn."
    }

    // MARK: - Finding or making the line

    private struct Found {
        let item: VanStockItem
        let created: Bool
    }

    private enum Target {
        case success(Found)
        case failure(String)
    }

    private func match(_ line: Line, in log: VanStockLog, byWords: Bool = true) -> VanStockMatcher.Match {
        let matcher = VanStockMatcher(items: log.items, partsIndex: partsIndex())
        guard byWords else { return matcher.match(number: Self.number(in: line), code: line.code) }
        return matcher.match(number: line.part, description: line.description, code: line.code)
    }

    /// The line a write is about. Only a load or a count may make a new one; anything else that
    /// matches nothing changes nothing. A line that only sounds like what was said is never
    /// written to: the technician is asked which they meant, and a load or a count starts a new
    /// line beside it only once they have said it is a different part (`new_line`).
    private func target(_ line: Line, in log: inout VanStockLog, batch: String, at: Date,
                        source: VanStockMovement.Source, mayCreate: Bool) -> Target {
        // The scan sheet chose the line already.
        if let itemID = line.itemID {
            guard let item = log.item(id: itemID) else {
                scanProblem = .lineGone
                return .failure(composer.notOnVan(line.reference))
            }
            attach(line, to: item, in: &log, batch: batch, at: at, source: source)
            return .success(Found(item: log.item(id: item.id) ?? item, created: false))
        }
        // Funded and private stock of one vaccine share a product code (Decision 6): the lot, or
        // the words said with the code, say which; otherwise ask, once.
        if let code = line.code {
            let sharing = log.items.filter { $0.codes.contains(code) }
            if sharing.count > 1 {
                let holding = line.lot.map { lot in sharing.filter { item in log.lots(of: item.id).contains { $0.code == lot } } } ?? []
                var chosen: VanStockItem?
                if holding.count == 1 { chosen = holding[0] }
                if chosen == nil, line.part != nil || line.description != nil,
                   case .one(let item) = VanStockMatcher(items: holding.count > 1 ? holding : sharing, partsIndex: partsIndex())
                    .match(number: line.part, description: line.description) {
                    chosen = item
                }
                guard let chosen else {
                    return .failure(composer.candidates(holding.count > 1 ? holding : sharing, levels: log.levels)
                        + " They share that code; once \(wording.person) says which, call again with its description.")
                }
                attach(line, to: chosen, in: &log, batch: batch, at: at, source: source)
                return .success(Found(item: log.item(id: chosen.id) ?? chosen, created: false))
            }
        }
        switch match(line, in: log, byWords: !(mayCreate && line.asNew)) {
        case .several(let items):
            return .failure(composer.candidates(items, levels: log.levels))
        case .near(let items):
            if mayCreate, line.asNew { return create(line, in: &log, batch: batch) }
            return .failure(composer.misheard(items, reference: line.reference, levels: log.levels, mayCreate: mayCreate))
        case .one(let item):
            if let raw = line.unit {
                guard let unit = VanStockUnit(spoken: raw) else { return .failure(self.unknownUnit(raw)) }
                guard unit == item.unit else {
                    return .failure("\(item.name) is counted in \(item.unit.unitName), not \(unit.unitName). Nothing was changed.")
                }
            }
            attach(line, to: item, in: &log, batch: batch, at: at, source: source)
            return .success(Found(item: log.item(id: item.id) ?? item, created: false))
        case .none:
            guard mayCreate else { return .failure(composer.notOnVan(line.reference)) }
            return create(line, in: &log, batch: batch)
        }
    }

    /// What a write can add to a line it matched: a number it did not have, a scanned code, and a
    /// fresh look in the book for a number that was not found last time. A look that had no book
    /// to search changes nothing, so it never takes a line's mark away or gives it one; a look that
    /// had one upgrades a line nothing was searched for, as a found number always did (Plan MK §4).
    private func attach(_ line: Line, to item: VanStockItem, in log: inout VanStockLog, batch: String,
                        at: Date, source: VanStockMovement.Source) {
        if item.number == nil, let number = Self.number(in: line) {
            let checked = lookUp(number)
            log.edit(itemID: item.id, .number(checked.part.number), at: at, batch: batch, source: source, id: makeID())
            log.edit(itemID: item.id, .verification(checked.verification), at: at, batch: batch, source: source, id: makeID())
        } else if let number = item.number, !item.verification.isFound {
            let checked = lookUp(number).verification
            if checked.state != .notChecked, checked != item.verification {
                log.edit(itemID: item.id, .verification(checked), at: at, batch: batch, source: source, id: makeID())
            }
        }
        if let code = line.code {
            log.edit(itemID: item.id, .addCode(code), at: at, batch: batch, source: .scanned, id: makeID())
        }
        // Remembered once, the first time it is given (Plan MY §2); never changed by a later one.
        if item.dosesPerCarton == nil, let perCarton = line.dosesPerCarton {
            log.edit(itemID: item.id, .dosesPerCarton(perCarton), at: at, batch: batch, source: source, id: makeID())
        }
    }

    private func create(_ line: Line, in log: inout VanStockLog, batch: String) -> Target {
        let number = Self.number(in: line)
        // Words given where a number goes are the description.
        let described = line.description ?? (number == nil ? line.part : nil)
        guard number != nil || described != nil else {
            if line.code != nil {
                return .failure("That code is not on \(wording.list) yet. Ask \(wording.person) what the part is, "
                    + "then record it again with the code and its part number or description.")
            }
            return .failure("Say what the part is: a part number, a description, or both.")
        }
        var unit = VanStockUnit.each
        if let raw = line.unit {
            guard let spoken = VanStockUnit(spoken: raw) else { return .failure(self.unknownUnit(raw)) }
            unit = spoken
        }
        let checked = number.map(lookUp)
        let item = log.addItem(id: makeID(),
                               number: checked?.part.number ?? number,
                               description: described ?? checked?.part.partDescription ?? "",
                               unit: unit,
                               codes: line.code.map { [$0] } ?? [],
                               verification: checked?.verification ?? .notChecked,
                               dosesPerCarton: line.dosesPerCarton,
                               batch: batch)
        return .success(Found(item: item, created: true))
    }

    /// Look a number up in the book Plan MK §4's order gives: the open job's vault, then the
    /// list's named vault, then none. With none, nothing is searched (the book's verifier is
    /// never called) and the number is not checked.
    private func lookUp(_ number: String) -> VanStockLookup {
        if let legacyVerify { return VanStockLookup(legacy: legacyVerify(number)) }
        return VanStockLookup.look(number, in: books.book(namedID: store.van?.checkVaultID))
    }

    /// The part number in a line, when what was given is one. A part number has no spaces and at
    /// least one digit; words in its place are a description.
    private static func number(in line: Line) -> String? {
        guard let part = line.part, !part.contains(where: \.isWhitespace),
              part.contains(where: \.isNumber) else { return nil }
        let normalised = VaultPartsIndex.normalise(part)
        return normalised.isEmpty ? nil : normalised
    }

    // MARK: - Lots (Plan MY §1, §4, §5)

    /// What a write needs of a lot.
    enum LotPurpose {
        case give, waste, remove, receive, count
    }

    /// Whether a line has stock in any of its lots.
    func hasLotsInStock(_ itemID: String) -> Bool {
        guard !store.isUnreadable else { return false }
        let log = store.log
        return !StockExpiry.inStock(log.lots(of: itemID), levels: log.level(of: itemID).lots).isEmpty
    }

    /// The line a write would match, without writing anything.
    private func matchedItem(_ line: Line, in log: VanStockLog, mayCreate: Bool) -> VanStockItem? {
        if let itemID = line.itemID { return log.item(id: itemID) }
        if case .one(let item) = match(line, in: log, byWords: !(mayCreate && line.asNew)) { return item }
        return nil
    }

    /// A line whose code is a scanned carton's (Plan MY §5): a GS1 code gives its product number
    /// as the code, and its lot and expiry as scanned; a plain code is kept as the list already
    /// knows it. A code that looks like GS1 and fails its checks is refused, so a misread carton is
    /// scanned again rather than filed under a wrong number.
    private func scanned(_ line: Line, in log: VanStockLog) -> Result<Line, StockWriteRefusal> {
        guard let code = line.code, !line.lotFromScan else { return .success(line) }
        switch StockScan.read(code, referenceYear: today.year) {
        case .failure(let failure):
            return .failure(StockWriteRefusal(sentence: "That code could not be read safely: \(failure.sentence). "
                + "Nothing was recorded. Ask \(wording.person) to scan it again."))
        case .success(let scan):
            var read = line
            let forms = scan.gtin.map(StockScan.forms(of:)) ?? [scan.code]
            // A code no line holds yet is kept as read, as it always was, unless it is a GS1
            // element string: then its product number, never the whole string with its lot.
            let elementString = StockScan.looksLikeGS1(code) && GS1ElementString.gtin14(code) == nil
            read.code = forms.first { form in log.items.contains { $0.codes.contains(form) } }
                ?? (elementString ? scan.code : code)
            if let lot = scan.lot {
                read.lot = lot
                read.lotFromScan = true
                read.expiry = scan.expiry
            }
            return .success(read)
        }
    }

    /// Which of the line's lots a write is about, or why it cannot be said. A lot said is matched
    /// only against the line's own; a scanned lot the line does not hold is added on a delivery or
    /// a count and refused on anything else. With no lot said, a line with one lot in stock uses
    /// it, and one with several asks which, oldest expiry first. A dose given from an expired lot
    /// is refused, with the offer to record it as wasted (Decision 4).
    private func lotChoice(_ purpose: LotPurpose, item: VanStockItem, line: Line, log: inout VanStockLog,
                           batch: String, at: Date) -> Result<StockLot?, StockWriteRefusal> {
        func refused(_ problem: StockScanFlow.Problem, _ sentence: String) -> Result<StockLot?, StockWriteRefusal> {
            scanProblem = problem
            return .failure(.init(sentence: sentence))
        }
        func several(_ candidates: [StockLot]) -> StockScanFlow.Problem {
            .whichLot(line: item.name, lots: StockExpiry.oldestFirst(candidates).map(\.code))
        }
        let lots = log.lots(of: item.id)
        let levels = log.level(of: item.id).lots
        let chosen: StockLot?
        if let said = line.lot {
            switch StockLotMatch.match(said, in: lots) {
            case .one(let lot):
                chosen = lot
            case .several(let candidates):
                return refused(several(candidates), lotComposer.whichLot(item, lots: candidates, levels: levels, today: today))
            case .none:
                guard line.lotFromScan else {
                    return refused(.lotNotOnLine(lot: said, line: item.name), lotComposer.lotNotHeld(item, said: said, lots: lots))
                }
                switch purpose {
                case .receive, .count:
                    guard let lot = log.addLot(id: makeID(), itemID: item.id, code: said, expiry: line.expiry,
                                               receivedAt: at, batch: batch) else {
                        return refused(.other, lotComposer.lotNotHeld(item, said: said, lots: lots))
                    }
                    return .success(lot)
                case .give:
                    return refused(.lotNotOnLine(lot: said, line: item.name), lotComposer.newLotOnGiven(item, code: said))
                case .waste, .remove:
                    return refused(.lotNotOnLine(lot: said, line: item.name), lotComposer.lotNotHeld(item, said: said, lots: lots))
                }
            }
        } else {
            let inStock = StockExpiry.inStock(lots, levels: levels)
            switch purpose {
            case .receive:
                chosen = nil
            case .give, .waste, .remove, .count:
                if inStock.count > 1 {
                    return refused(several(inStock), lotComposer.whichLot(item, lots: inStock, levels: levels, today: today))
                }
                chosen = inStock.first
            }
        }
        if purpose == .give, VaccineStockPolicy.refusesExpiredGiven, let lot = chosen,
           StockExpiry.isExpired(lot, today: today) {
            return refused(.lotExpired(lot: lot.code, line: item.name), lotComposer.expiredOnGiven(item, lot: lot))
        }
        return .success(chosen)
    }

    // MARK: - The scan sheet (Plan MY §5)

    /// What a tap on the scan sheet did: whether anything was recorded, and the read-back. The
    /// read-back is English, as everything the assistant reads is; the sheet shows `problem`,
    /// which is set exactly when nothing was recorded.
    struct ScanOutcome: Equatable {
        let recorded: Bool
        let answer: String
        var problem: StockScanFlow.Problem?
    }

    /// A new line the scan sheet is adding: its name and how many doses a carton holds.
    struct NewScannedLine: Equatable {
        var name: String
        var dosesPerCarton: Int?
    }

    /// Record one scanned carton as the sheet's choice says: on the line it resolved to, or as a
    /// new line. The sheet asks "Another one?" itself (`StockScanRepeatGuard`), so a tap is never
    /// taken for a model's retry. A line the person chose for a code it did not carry ("Which line
    /// is this?") keeps the code from now on, in the same entry as the movement, so one Undo takes
    /// both back; a code already on another line is refused (`StockScanFlow.linkConflict`).
    func recordScan(_ action: StockScanFlow.Action, scan: StockScan, itemID: String?,
                    newLine: NewScannedLine? = nil, quantity: StockQuantity) -> ScanOutcome {
        guard !store.isUnreadable else {
            return ScanOutcome(recorded: false, answer: unreadable, problem: .listUnreadable)
        }
        if let itemID, let holder = StockScanFlow.linkConflict(scan, itemID: itemID, in: store.log) {
            return ScanOutcome(recorded: false, answer: "That code is already on \(holder.name). Nothing was changed.",
                               problem: .codeOnAnotherLine(holder.name))
        }
        lastWrite = nil
        scanProblem = nil
        defer { scanProblem = nil }
        let line = Line(description: newLine?.name, quantity: quantity, code: scan.code, asNew: newLine != nil,
                        lot: scan.lot, lotFromScan: scan.lot != nil, expiry: scan.expiry,
                        dosesPerCarton: newLine?.dosesPerCarton, itemID: itemID)
        let before = store.log.movements.count
        let answer: String
        switch action {
        case .given: answer = use([line], source: .scanned)
        case .wasted(let reason): answer = waste([line], reason: reason, source: .scanned)
        case .received: answer = load([line], source: .scanned)
        case .counted: answer = count([line], source: .scanned)
        }
        lastWrite = nil
        guard store.log.movements.count == before else { return ScanOutcome(recorded: true, answer: answer) }
        let problem: StockScanFlow.Problem
        if let systemName {
            problem = .heldBySystem(systemName)
        } else if !quantity.isInRange || (quantity == .zero && action != .counted) {
            problem = .amountOutOfRange
        } else {
            problem = scanProblem ?? .other
        }
        return ScanOutcome(recorded: false, answer: answer, problem: problem)
    }

    private func unknownUnit(_ raw: String) -> String {
        "'\(raw)' is not a unit \(wording.list) keeps. Use one of: "
            + VanStockUnit.allCases.map(\.rawValue).joined(separator: ", ") + ". Nothing was changed."
    }
}

private extension String {
    var vanStockNonEmpty: String? { isEmpty ? nil : self }
}

/// A sentence a lot or scan check refused a write with.
struct StockWriteRefusal: Error, Equatable {
    let sentence: String
}

// MARK: - The weekly count and the report (Plan MY §6, §7)

extension VanStockService {

    /// The weekly count's entries: every lot, oldest expiry first within its line.
    func countRound() -> [StockCountRound.Entry] {
        guard !store.isUnreadable else { return [] }
        return StockCountRound.entries(store.log)
    }

    /// Record a count of several lots (or lines with no lots) as one entry, so one Undo takes the
    /// whole count back, each compared with what the log held in it just before (Plan MY §6). Nil,
    /// and nothing recorded, when any figure is not one the line can hold, an entry is no longer in
    /// the round, or the business's own system holds the count.
    func recordCounts(_ counts: [(entryID: String, quantity: StockQuantity)]) -> [StockCountRound.Result]? {
        guard !authority.isSystem, !store.isUnreadable, !counts.isEmpty else { return nil }
        let round = Dictionary(StockCountRound.entries(store.log).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for count in counts {
            guard let entry = round[count.entryID], count.quantity >= .zero, count.quantity.isInRange,
                  count.quantity.fits(entry.item.unit) else { return nil }
        }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        var results: [StockCountRound.Result] = []
        let recorded = store.update { log -> Bool in
            var working = log
            for count in counts {
                guard let entry = round[count.entryID] else { return false }
                let before = working.level(of: entry.item.id)
                let check: VanStockCountCheck?
                if let lot = entry.lot {
                    check = VanStockCountCheck(before: before.lots[lot.id] ?? StockLotLevel(lotID: lot.id), counted: count.quantity)
                } else {
                    check = VanStockCountCheck(before: before, counted: count.quantity)
                }
                guard working.record(.counted, itemID: entry.item.id, quantity: count.quantity, at: at, batch: batch,
                                     source: .typed, id: makeID(), lotID: entry.lot?.id) != nil else { return false }
                results.append(StockCountRound.Result(entry: entry, counted: count.quantity, check: check))
            }
            log = working
            return true
        }
        return recorded == true ? results : nil
    }

    /// Hide an empty lot from the count (Plan MY §6). False for a lot with something in it, which
    /// stays listed until it is empty.
    @discardableResult
    func hideLot(_ lotID: String) -> Bool {
        guard !store.isUnreadable, let lot = store.log.lot(id: lotID),
              (store.log.level(of: lot.itemID).lots[lotID]?.onHand ?? .zero) == .zero else { return false }
        return store.update { $0.setLot(lotID, hidden: true) } ?? false
    }

    /// The report for `range` (Plan MY §7), with the latest check against the EMR. Nil while the
    /// list can't be read.
    func report(for range: StockReportRange) -> StockPeriodReport? {
        guard !store.isUnreadable else { return nil }
        return StockPeriodReport.make(store.log, range: range, now: now(), calendar: calendar, clinical: isClinical,
                                      emrCheck: ImmunisationCheckSummary.stored())
    }

    /// The report as a spreadsheet in a temporary folder, for the share sheet; the caller removes
    /// the folder when the share is done. Nothing is sent by itself.
    func reportFile(for range: StockReportRange) -> URL? {
        guard let report = report(for: range) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stock-report-\(makeID())", isDirectory: true)
        let url = folder.appendingPathComponent(report.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try report.spreadsheet(modified: now()).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    /// The periods the spoken report takes.
    enum ReportPeriod: String, CaseIterable {
        case today
        case thisWeek = "this_week"
    }

    /// The report's one-sentence summary, for `van_stock`'s `report` action (Plan MY §7).
    func spokenReport(_ period: ReportPeriod) -> String {
        guard !store.isUnreadable else { return unreadable }
        let range: StockReportRange
        switch period {
        case .today: range = .today(now: now(), calendar: calendar)
        case .thisWeek: range = .thisWeek(now: now(), calendar: calendar)
        }
        guard let report = report(for: range) else { return unreadable }
        return report.spokenSummary() + " Read this back as given. To share the full report, the person opens "
            + "the stock report on the Stock screen; nothing is sent from here."
    }
}
