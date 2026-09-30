import SwiftUI

/// Daily and monthly spending limits for priced API usage (Plan GB P5). The spoken side lives in
/// `LLMService` (`SpendCapGate`); this is the tap side: set the limits, see where today and the
/// month stand, and agree to go past a limit that has been reached.
struct SpendCapSettingsView: View {
    @State private var daily = Config.dailySpendCapUSD
    @State private var monthly = Config.monthlySpendCapUSD
    @State private var fallback = Config.spendCapFallbackToCheaperModel
    @State private var spent: (today: Double, month: Double) = (0, 0)
    @State private var overrideKey = Config.spendCapOverrideWindow

    private var caps: SpendCapPolicy.Caps {
        SpendCapPolicy.Caps(dailyUSD: daily, monthlyUSD: monthly, fallBackToCheaperModel: fallback)
    }

    private var reachedWindow: SpendCapPolicy.Window? {
        switch SpendCapPolicy.decide(spentToday: spent.today, spentMonth: spent.month,
                                     caps: SpendCapPolicy.Caps(dailyUSD: daily, monthlyUSD: monthly,
                                                               fallBackToCheaperModel: false),
                                     pricing: .priced, overrideKey: overrideKey, now: Date()) {
        case .confirmToContinue(let window): return window
        default: return nil
        }
    }

    var body: some View {
        Form {
            Section {
                limitRow("Daily limit", value: $daily)
                limitRow("Monthly limit", value: $monthly)
            } footer: {
                Text("At 80% of a limit you'll hear a warning. At the limit, you're asked before the next request goes out. Set a limit to 0 to turn it off.")
            }

            Section {
                LabeledContent("Spent today", value: Self.money(spent.today))
                LabeledContent("Spent this month", value: Self.money(spent.month))
                if let window = reachedWindow {
                    Button("Continue past the limit") {
                        let key = window.key(now: Date())
                        Config.spendCapOverrideWindow = key
                        overrideKey = key
                    }
                }
            } footer: {
                Text("Estimated from list prices on this device. Models without a price can't be counted against a limit.")
            }

            Section {
                Toggle("Switch to a cheaper model at the limit", isOn: $fallback)
            } footer: {
                Text("Off by default: you're asked instead, so answers never come from a different model without you knowing.")
            }
        }
        .ogFormStyle()
        .navigationTitle("Spending limits")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { spent = UsageTracker.shared.spend() }
        .onChange(of: daily) { _, value in Config.dailySpendCapUSD = value }
        .onChange(of: monthly) { _, value in Config.monthlySpendCapUSD = value }
        .onChange(of: fallback) { _, value in Config.spendCapFallbackToCheaperModel = value }
    }

    private func limitRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .currency(code: "USD"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private static func money(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD"))
    }
}
