import SwiftUI

/// The weekly count on the Stock screen (Plan MY §6): every lot, oldest expiry first within its
/// line, with what the log expects in it. The figures typed in are recorded together as one entry,
/// so one Undo takes the whole count back, and each is compared with what the log held. An empty
/// lot stays here, to be counted at zero, until it is hidden.
@MainActor
struct StockCountSheet: View {
    @ObservedObject var store: VanStockStore
    var service: VanStockService = .shared
    var reminders: StockCountReminderScheduler = .shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var typed: [String: String] = [:]
    @State private var results: [StockCountRound.Result]?
    @State private var failed = false
    @State private var reminder = StockCountReminderSettings()
    @State private var reminderRefused = false

    private var entries: [StockCountRound.Entry] { StockCountRound.entries(store.log) }

    var body: some View {
        NavigationStack {
            Form {
                if let results {
                    resultSection(results)
                } else {
                    countSections
                }
                reminderSection
            }
            .ogFormStyle()
            .navigationTitle("Count the stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(results == nil ? "Cancel" : "Done") { dismiss() }
                }
                if results == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(counted.isEmpty)
                    }
                }
            }
            .alert("The count couldn't be saved", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("Check each figure is a whole number of the line's unit. Nothing was recorded.")
            }
            .task { reminder = reminders.settings }
        }
    }

    // MARK: - Counting

    @ViewBuilder
    private var countSections: some View {
        if entries.isEmpty {
            Section {
                Text("Nothing on the list to count yet.")
            }
        }
        let byLine = Dictionary(grouping: entries, by: { $0.item.id })
        ForEach(store.log.items.filter { byLine[$0.id] != nil }) { item in
            Section {
                ForEach(byLine[item.id] ?? []) { entry in
                    row(entry)
                }
            } header: {
                Text(verbatim: item.name)
            }
        }
        if !entries.isEmpty {
            Section {
                EmptyView()
            } footer: {
                Text("Oldest expiry first. Leave a figure empty to skip it. An empty lot stays here until you hide it.")
            }
        }
    }

    private func row(_ entry: StockCountRound.Entry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let lot = entry.lot {
                    Text("Lot \(lot.code)")
                    if let expiry = lot.expiry {
                        Text("Expires \(StockScanText.day(expiry))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("The whole line")
                }
                if entry.isKnown {
                    Text("Expected \(VanStockRow.figure(entry.expected, unit: entry.item.unit, locale: locale))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            TextField("Count", text: Binding(get: { typed[entry.id] ?? "" }, set: { typed[entry.id] = $0 }))
                .keyboardType(entry.item.unit == .each ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .accessibilityLabel(Text("Count for \(entry.lot.map { "lot \($0.code)" } ?? entry.item.name)"))
        }
        .swipeActions {
            if entry.mayHide, let lot = entry.lot {
                Button("Hide") { _ = service.hideLot(lot.id) }
            }
        }
    }

    /// The figures typed in so far, read as quantities of each line's unit.
    private var counted: [(entry: StockCountRound.Entry, quantity: StockQuantity)] {
        entries.compactMap { entry in
            guard let raw = typed[entry.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  case .success(let quantity) = StockQuantity.parse(localized: raw, locale: locale, unit: entry.item.unit) else { return nil }
            return (entry, quantity)
        }
    }

    private func save() {
        guard let recorded = service.recordCounts(counted.map { ($0.entry.id, $0.quantity) }) else {
            failed = true
            return
        }
        results = recorded
    }

    // MARK: - After the count

    private func resultSection(_ results: [StockCountRound.Result]) -> some View {
        Section {
            ForEach(results, id: \.entry.id) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: result.entry.item.name)
                    Text(verbatim: StockCountSheet.describe(result, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Counted")
        } footer: {
            Text("The differences are in this week's report. Undo on the Stock screen takes the whole count back.")
        }
    }

    static func describe(_ result: StockCountRound.Result, locale: Locale) -> String {
        let unit = result.entry.item.unit
        let figure = { (q: StockQuantity) in VanStockRow.figure(q, unit: unit, locale: locale) }
        let lot = result.entry.lot.map { String(localized: "Lot \($0.code): ") } ?? ""
        switch result.check {
        case nil: return lot + String(localized: "\(figure(result.counted)), the first figure")
        case .matches: return lot + String(localized: "\(figure(result.counted)), as expected")
        case .short(let expected, let by):
            return lot + String(localized: "\(figure(result.counted)), \(figure(by)) short of \(figure(expected))")
        case .over(let expected, let by):
            return lot + String(localized: "\(figure(result.counted)), \(figure(by)) over \(figure(expected))")
        case .unreliable:
            return lot + String(localized: "\(figure(result.counted)), replacing a figure that couldn't be trusted")
        }
    }

    // MARK: - The reminder

    private var reminderSection: some View {
        Section {
            Toggle("Remind me each week", isOn: Binding(get: { reminder.enabled }, set: { on in
                reminder.enabled = on
                applyReminder()
            }))
            if reminder.enabled {
                Picker("Day", selection: Binding(get: { reminder.weekday }, set: { day in
                    reminder.weekday = day
                    applyReminder()
                })) {
                    ForEach(1...7, id: \.self) { day in
                        Text(verbatim: Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                DatePicker("Time", selection: Binding(get: { reminderTime }, set: { time in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    reminder.minute = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
                    applyReminder()
                }), displayedComponents: .hourAndMinute)
            }
            if reminderRefused {
                Label("Notifications are off for this app in Settings, so no reminder can show.",
                      systemImage: "bell.slash")
                    .font(.callout)
            }
        } header: {
            Text("Weekly count")
        } footer: {
            Text("A reminder on this phone at the time you choose. It says only that the count is due.")
        }
    }

    private var reminderTime: Date {
        Calendar.current.date(bySettingHour: reminder.minute / 60, minute: reminder.minute % 60, second: 0, of: Date()) ?? Date()
    }

    private func applyReminder() {
        let settings = reminder
        Task { @MainActor in
            reminderRefused = !(await reminders.apply(settings, askIfNeeded: true))
        }
    }
}
