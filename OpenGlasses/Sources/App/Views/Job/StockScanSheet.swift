import SwiftUI
import VisionKit

/// Scan a carton on the Stock screen (Plan MY §5): the phone's camera reads its 2D code (Data
/// Matrix) or GS1-128 barcode, the code resolves to a line, a lot and an expiry, and the person
/// says what happened to it: Given, Wasted, Received or Count.
///
/// The phone's camera only (Decision 10). A product number not on the list starts a new line on
/// Received or Count; a lot not on the line comes in the same way, never on Given. The same code
/// recorded again within ten seconds asks "Another one?" first. Nothing here takes or shows who a
/// dose was given to: this is the stock, not the patient's record.
@MainActor
struct StockScanSheet: View {
    @ObservedObject var store: VanStockStore
    var service: VanStockService = .shared

    @Environment(\.dismiss) private var dismiss

    /// The code being dealt with, read.
    @State private var scan: StockScan?
    /// Why the last code was not taken.
    @State private var unreadable: GS1ElementString.Failure?
    /// The line the person picked when several share the product number.
    @State private var pickedItemID: String?
    @State private var choice = StockScanText.Choice.given
    @State private var wasteReason = VanStockMovement.WasteReason.other
    @State private var doses = 1
    @State private var inCartons = false
    @State private var cartons = 1
    @State private var newName = ""
    @State private var newDosesPerCarton = 10
    @State private var pendingRepeat: StockScan?
    @State private var repeatGuard = StockScanRepeatGuard()
    @State private var outcome: VanStockService.ScanOutcome?
    /// A new identity restarts the camera for the next carton.
    @State private var scannerID = UUID()

    private var today: StockDay { StockDay(Date(), calendar: .current) }

    var body: some View {
        NavigationStack {
            Form {
                if let scan {
                    scannedSections(scan)
                } else {
                    scannerSection
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("This is a stock record, not the immunisation record. Nothing about a patient is kept here.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Scan a carton")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Another one?", isPresented: Binding(
                get: { pendingRepeat != nil }, set: { if !$0 { pendingRepeat = nil } }),
                                titleVisibility: .visible) {
                Button("Yes, another one") {
                    if let again = pendingRepeat { take(again) }
                    pendingRepeat = nil
                }
                Button("No, the same one", role: .cancel) {
                    pendingRepeat = nil
                    scannerID = UUID()
                }
            } message: {
                Text("That carton was recorded a moment ago.")
            }
        }
    }

    // MARK: - Scanning

    @ViewBuilder
    private var scannerSection: some View {
        Section {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                StockCartonScannerView(onCode: read)
                    .id(scannerID)
                    .frame(minHeight: 280)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel(Text("Camera, reading the carton's code"))
            } else {
                Text("This phone can't scan a code here.")
            }
            if let unreadable {
                Label(StockScanText.unreadable(unreadable), systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        } footer: {
            Text("Point the camera at the square code on the carton.")
        }
    }

    private func read(_ raw: String) {
        switch StockScan.read(raw, referenceYear: today.year) {
        case .failure(let failure):
            unreadable = failure
            scannerID = UUID()
        case .success(let read):
            unreadable = nil
            if repeatGuard.asksAgain(read.raw, at: Date()) {
                pendingRepeat = read
            } else {
                take(read)
            }
        }
    }

    private func take(_ read: StockScan) {
        scan = read
        pickedItemID = nil
        outcome = nil
        doses = 1
        cartons = 1
        inCartons = false
        newName = ""
        let allowed = StockScanFlow.allowed(resolution(read), expiry: read.expiry, today: today)
        apply(StockScanFlow.defaultAction(allowed))
    }

    private func apply(_ action: StockScanFlow.Action?) {
        switch action {
        case .given, nil: choice = .given
        case .wasted(let reason): choice = .wasted; wasteReason = reason
        case .received: choice = .received
        case .counted: choice = .counted
        }
    }

    // MARK: - What was scanned

    /// The resolution, with a picked line standing in for "several lines".
    private func resolution(_ scan: StockScan) -> StockScanFlow.Resolution {
        let resolved = StockScanFlow.resolve(scan, in: store.log)
        guard case .severalLines = resolved, let pickedItemID, let item = store.log.item(id: pickedItemID) else {
            return resolved
        }
        guard let code = scan.lot else { return .known(item: item, lot: nil, newLot: nil) }
        let lot = store.log.lots(of: item.id).first { $0.code == code }
        return .known(item: item, lot: lot, newLot: lot == nil ? code : nil)
    }

    @ViewBuilder
    private func scannedSections(_ scan: StockScan) -> some View {
        let resolved = resolution(scan)
        let allowed = StockScanFlow.allowed(resolved, expiry: scan.expiry, today: today)
        Section {
            switch resolved {
            case .known(let item, _, _):
                LabeledContent("Line") { Text(item.name) }
            case .newProduct:
                Text("This product isn't on the list yet.")
                    .font(.headline)
            case .severalLines(let items):
                Picker("Which line?", selection: $pickedItemID) {
                    Text("Choose").tag(String?.none)
                    ForEach(items) { item in Text(item.name).tag(String?.some(item.id)) }
                }
                .onChange(of: pickedItemID) { _, _ in
                    apply(StockScanFlow.defaultAction(StockScanFlow.allowed(resolution(scan), expiry: scan.expiry, today: today)))
                }
            }
            if let lot = scan.lot {
                LabeledContent("Lot") { Text(verbatim: lot) }
            }
            if let expiry = scan.expiry {
                LabeledContent("Expires") {
                    Text(verbatim: StockScanText.day(expiry))
                        .foregroundStyle(expiry < today ? .red : .primary)
                }
                if expiry < today {
                    Label("This lot has expired. It can't be recorded as given; record it as wasted.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
            if case .known(_, nil, let newLot?) = resolved {
                Text("Lot \(newLot) isn't on this line yet. It's added when it's received or counted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let gtin = scan.gtin {
                LabeledContent("Product number") { Text(verbatim: gtin).monospacedDigit() }
            }
        } header: {
            Text("Scanned")
        }

        if case .newProduct = resolved {
            Section {
                TextField("Name, such as the flu vaccine", text: $newName)
                    .frame(minHeight: OGMetrics.minTouchTarget)
                Stepper(value: $newDosesPerCarton, in: 1...500) {
                    LabeledContent("Doses per carton") { Text("\(newDosesPerCarton)").monospacedDigit() }
                }
            } header: {
                Text("New line")
            } footer: {
                Text("A new product is added when it's received or counted.")
            }
        }

        if !allowed.isEmpty {
            actionSection(resolved, allowed: allowed, scan: scan)
        }

        if let outcome {
            Section {
                Label(outcome.recorded ? "Recorded." : "Nothing was recorded.",
                      systemImage: outcome.recorded ? "checkmark.circle" : "xmark.circle")
                if !outcome.recorded {
                    Text(verbatim: outcome.answer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Scan the next carton") {
                    self.scan = nil
                    self.outcome = nil
                    scannerID = UUID()
                }
            }
        }
    }

    @ViewBuilder
    private func actionSection(_ resolved: StockScanFlow.Resolution, allowed: [StockScanFlow.Action],
                               scan: StockScan) -> some View {
        let choices = StockScanText.Choice.offered(allowed)
        let perCarton = knownDosesPerCarton(resolved)
        Section {
            Picker("What happened", selection: $choice) {
                ForEach(choices, id: \.self) { Text(StockScanText.name($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            if choice == .wasted {
                Picker("Why", selection: $wasteReason) {
                    ForEach(VanStockMovement.WasteReason.allCases, id: \.self) {
                        Text(StockScanText.wasteReasonName($0)).tag($0)
                    }
                }
            }
            if choice == .received, perCarton != nil {
                Toggle("Count in cartons", isOn: $inCartons)
            }
            if choice == .received, inCartons, let perCarton {
                Stepper(value: $cartons, in: 1...200) {
                    LabeledContent("Cartons") { Text("\(cartons) × \(perCarton)").monospacedDigit() }
                }
            } else {
                Stepper(value: $doses, in: choice == .counted ? 0...9_999 : 1...9_999) {
                    LabeledContent(choice == .counted ? "Doses counted" : "Doses") { Text("\(doses)").monospacedDigit() }
                }
            }
            Button("Record") { record(resolved, scan: scan, perCarton: perCarton) }
                .disabled(outcome != nil || !choices.contains(choice) || isNewLineIncomplete(resolved))
        } header: {
            Text("What happened")
        }
    }

    private func knownDosesPerCarton(_ resolved: StockScanFlow.Resolution) -> Int? {
        switch resolved {
        case .known(let item, _, _): return item.dosesPerCarton
        case .newProduct: return newDosesPerCarton
        case .severalLines: return nil
        }
    }

    private func isNewLineIncomplete(_ resolved: StockScanFlow.Resolution) -> Bool {
        guard case .newProduct = resolved else { return false }
        return newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func record(_ resolved: StockScanFlow.Resolution, scan: StockScan, perCarton: Int?) {
        let action: StockScanFlow.Action
        switch choice {
        case .given: action = .given
        case .wasted: action = .wasted(wasteReason)
        case .received: action = .received
        case .counted: action = .counted
        }
        let amount = choice == .received && inCartons ? cartons * (perCarton ?? 1) : doses
        let itemID: String?
        var newLine: VanStockService.NewScannedLine?
        switch resolved {
        case .known(let item, _, _): itemID = item.id
        case .newProduct:
            itemID = nil
            newLine = .init(name: newName, dosesPerCarton: newDosesPerCarton)
        case .severalLines: return
        }
        let result = service.recordScan(action, scan: scan, itemID: itemID, newLine: newLine,
                                        quantity: StockQuantity(whole: amount))
        outcome = result
        if result.recorded { repeatGuard.recorded(scan.raw, at: Date()) }
    }
}

/// The live scanner: Data Matrix and GS1-128 cartons, and the plain barcodes some boxes carry.
/// Hands back the first code it reads, then stops until it is given a new identity.
struct StockCartonScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.dataMatrix, .code128, .ean13, .ean8, .upce, .itf14])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            deliver(from: addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver(from: [item], scanner: dataScanner)
        }

        private func deliver(from items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue, !text.isEmpty {
                    delivered = true
                    scanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}

/// What the scan sheet and the line page say, localised (Plan MY). The model's words are
/// `StockLotComposer`'s; these are the screen's.
enum StockScanText {

    /// The four choices, as the sheet's picker shows them.
    enum Choice: Hashable {
        case given, wasted, received, counted

        static func offered(_ allowed: [StockScanFlow.Action]) -> [Choice] {
            var choices: [Choice] = []
            for action in allowed {
                let choice: Choice
                switch action {
                case .given: choice = .given
                case .wasted: choice = .wasted
                case .received: choice = .received
                case .counted: choice = .counted
                }
                if !choices.contains(choice) { choices.append(choice) }
            }
            return choices
        }
    }

    static func name(_ choice: Choice) -> String {
        switch choice {
        case .given: return String(localized: "Given")
        case .wasted: return String(localized: "Wasted")
        case .received: return String(localized: "Received")
        case .counted: return String(localized: "Count")
        }
    }

    static func wasteReasonName(_ reason: VanStockMovement.WasteReason) -> String {
        switch reason {
        case .expired: return String(localized: "Expired")
        case .coldChain: return String(localized: "Cold chain")
        case .drawnUpNotGiven: return String(localized: "Drawn up, not given")
        case .broken: return String(localized: "Broken or dropped")
        case .openedVialDiscarded: return String(localized: "Opened vial discarded")
        case .other: return String(localized: "Other")
        }
    }

    /// Why a code was not taken, in a sentence for the person holding the carton.
    static func unreadable(_ failure: GS1ElementString.Failure) -> String {
        switch failure {
        case .badCheckDigit: return String(localized: "That code's product number doesn't check out. Scan it again.")
        case .impossibleDate: return String(localized: "That code's date isn't a real date. Scan it again.")
        case .truncated, .tooLong: return String(localized: "That code was read only in part. Scan it again.")
        case .empty, .unknownAI, .notDigits, .repeatedAI, .badCharacters:
            return String(localized: "That code couldn't be read safely. Scan it again.")
        }
    }

    /// An expiry as the phone's locale shows a date.
    static func day(_ day: StockDay) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else {
            return day.description
        }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc.timeZone)
        return date.formatted(style)
    }
}
