import SwiftUI

/// The stock report on the Stock screen (Plan MY §7): today or this week in one tap, or any range
/// of days. Given, wasted by reason, received, what is on hand by line and lot with expiry, the
/// lots expiring soon, the counts that differed and the latest check against the EMR. Shared as a
/// spreadsheet only when the person chooses; nothing is sent by itself.
@MainActor
struct StockReportView: View {
    @ObservedObject var store: VanStockStore
    var service: VanStockService = .shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    enum Period: Hashable {
        case today, thisWeek, range
    }

    @State private var period = Period.thisWeek
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var sharing: ShareItem?
    @State private var exportFailed = false

    private var range: StockReportRange {
        let calendar = Calendar.current
        switch period {
        case .today: return .today(now: Date(), calendar: calendar)
        case .thisWeek: return .thisWeek(now: Date(), calendar: calendar)
        case .range: return StockReportRange(first: StockDay(from, calendar: calendar), last: StockDay(to, calendar: calendar))
        }
    }

    var body: some View {
        // Read again whenever the list changes.
        let report = service.report(for: range)
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $period) {
                        Text("Today").tag(Period.today)
                        Text("This week").tag(Period.thisWeek)
                        Text("Dates").tag(Period.range)
                    }
                    .pickerStyle(.segmented)
                    if period == .range {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                } footer: {
                    Text(verbatim: range.first == range.last
                         ? StockScanText.day(range.first)
                         : "\(StockScanText.day(range.first)) – \(StockScanText.day(range.last))")
                }
                if let report {
                    totalsSection(report)
                    onHandSection(report)
                    expirySection(report)
                    countSection(report)
                    emrSection(report)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("This is a stock record, not the immunisation record. Nothing about a patient is kept here.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Stock report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: export) {
                        Label("Share as a spreadsheet…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(report == nil)
                }
            }
            .sheet(item: $sharing) { item in
                ShareSheet(items: item.items, onComplete: item.onComplete)
            }
            .alert("The spreadsheet couldn't be made", isPresented: $exportFailed) {
                Button("OK") {}
            }
        }
    }

    private func figure(_ quantity: StockQuantity, _ item: VanStockItem) -> String {
        VanStockRow.figure(quantity, unit: item.unit, locale: locale)
    }

    private func number(_ quantity: StockQuantity) -> String {
        VanStockRow.figure(quantity, unit: .each, locale: locale)
    }

    // MARK: - Sections

    private func totalsSection(_ report: StockPeriodReport) -> some View {
        Section {
            LabeledContent("Given", value: number(report.given))
            ForEach(report.wastedByReason, id: \.reason) { entry in
                LabeledContent {
                    Text(verbatim: number(entry.quantity))
                } label: {
                    Text("Wasted · \(StockScanText.wasteReasonName(entry.reason))")
                }
            }
            if report.wastedByReason.isEmpty {
                LabeledContent("Wasted", value: number(.zero))
            }
            LabeledContent("Received", value: number(report.received))
            ForEach(report.lines.filter(\.hasActivity), id: \.item.id) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: line.item.name)
                    Text("Given \(figure(line.given, line.item)) · wasted \(figure(line.wastedTotal, line.item)) · received \(figure(line.received, line.item))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Given, wasted and received")
        }
    }

    private func onHandSection(_ report: StockPeriodReport) -> some View {
        Section {
            ForEach(report.lines, id: \.item.id) { line in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text(verbatim: figure(line.onHand, line.item))
                    } label: {
                        Text(verbatim: line.item.name)
                    }
                    ForEach(line.lots, id: \.lotID) { lot in
                        HStack {
                            Text("Lot \(lot.code)")
                            if let expiry = lot.expiry {
                                Text("· expires \(StockScanText.day(expiry))")
                            }
                            Spacer()
                            Text(verbatim: figure(lot.onHand, line.item))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("On hand")
        }
    }

    @ViewBuilder
    private func expirySection(_ report: StockPeriodReport) -> some View {
        Section {
            if report.expired.isEmpty && report.expiringSoon.isEmpty {
                Text("No lot in stock expires within \(VaccineStockPolicy.expiringSoonDays) days.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(report.expired.enumerated()), id: \.offset) { _, lot in
                Label {
                    Text("\(lot.item.name), lot \(lot.code): expired \(StockScanText.day(lot.expiry)), \(figure(lot.onHand, lot.item)) left")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.red)
            }
            ForEach(Array(report.expiringSoon.enumerated()), id: \.offset) { _, lot in
                Label {
                    Text("\(lot.item.name), lot \(lot.code): expires \(StockScanText.day(lot.expiry)), \(figure(lot.onHand, lot.item)) left")
                } icon: {
                    Image(systemName: "clock")
                }
            }
        } header: {
            Text("Expiring soon")
        }
    }

    private func countSection(_ report: StockPeriodReport) -> some View {
        Section {
            if report.countsMade == 0 {
                Text("No count was made in this period.")
                    .foregroundStyle(.secondary)
            } else if report.countDifferences.isEmpty {
                Text("Every count matched the log.")
            }
            ForEach(Array(report.countDifferences.enumerated()), id: \.offset) { _, difference in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: difference.item.name + (difference.lotCode.map { " · \($0)" } ?? ""))
                    Text(verbatim: StockReportView.describe(difference.check, counted: difference.counted, unit: difference.item.unit, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Counts")
        }
    }

    static func describe(_ check: VanStockCountCheck, counted: StockQuantity, unit: VanStockUnit, locale: Locale) -> String {
        let figure = { (q: StockQuantity) in VanStockRow.figure(q, unit: unit, locale: locale) }
        switch check {
        case .matches: return String(localized: "Counted \(figure(counted)), as expected")
        case .short(let expected, let by): return String(localized: "Counted \(figure(counted)), \(figure(by)) short of \(figure(expected))")
        case .over(let expected, let by): return String(localized: "Counted \(figure(counted)), \(figure(by)) over \(figure(expected))")
        case .unreliable: return String(localized: "Counted \(figure(counted)), replacing a figure that couldn't be trusted")
        }
    }

    @ViewBuilder
    private func emrSection(_ report: StockPeriodReport) -> some View {
        if let check = report.emrCheck {
            Section {
                LabeledContent("Given here, not in the EMR on that day", value: "\(check.givenNotInEMR)")
                LabeledContent("In the EMR, not given here", value: "\(check.inEMRNotGiven)")
                LabeledContent("Same day, different lot", value: "\(check.differentLot)")
                LabeledContent("Nearby day", value: "\(check.nearby)")
            } header: {
                Text("Last check against the EMR")
            } footer: {
                Text(verbatim: "\(StockScanText.day(check.first)) – \(StockScanText.day(check.last))")
            }
        }
    }

    private func export() {
        guard let url = service.reportFile(for: range) else {
            exportFailed = true
            return
        }
        sharing = ShareItem(items: [url]) { _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}
