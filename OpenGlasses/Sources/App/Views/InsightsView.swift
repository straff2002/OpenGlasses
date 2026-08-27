import SwiftUI

/// On-device usage insights (Memory & Recall Phase 4): a private recap of how you've been
/// using the assistant — activity, top topics, top tools — computed locally from conversation
/// history. Read-only; nothing leaves the device.
struct InsightsView: View {
    @EnvironmentObject var appState: AppState

    @State private var days = 7
    @State private var report: InsightsReport?
    @State private var usage: UsageRollup.Result?

    var body: some View {
        Form {
            Section {
                Picker("Window", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .onChange(of: days) { _, _ in refresh() }
            }

            if let report, report.totalTurns > 0 {
                Section("Activity") {
                    HStack(spacing: 12) {
                        OGStatTile(value: "\(report.userTurns)", caption: "Exchanges")
                        OGStatTile(value: "\(report.totalTurns)", caption: "Total turns")
                    }
                }
                if !report.topTopics.isEmpty {
                    Section("Top topics") {
                        ForEach(report.topTopics, id: \.name) { topic in
                            LabeledContent(topic.name, value: "\(topic.count)")
                        }
                    }
                }
                if !report.topTools.isEmpty {
                    Section("Most-used tools") {
                        ForEach(report.topTools, id: \.name) { tool in
                            LabeledContent(tool.name, value: "\(tool.count)")
                        }
                    }
                }
                Section {
                    Button {
                        let text = InsightsService.shared.recapText(report, days: days)
                        Task { await appState.speechService.speak(text) }
                    } label: {
                        Label("Speak recap", systemImage: "speaker.wave.2.fill")
                    }
                }
            } else {
                ContentUnavailableView("No activity yet",
                                       systemImage: "chart.bar",
                                       description: Text("Have a few conversations and your usage recap will show up here."))
            }

            if let usage, !usage.perModel.isEmpty {
                Section {
                    ForEach(usage.perModel, id: \.model) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.model).font(.subheadline)
                                Spacer()
                                Text(Self.costLabel(m.costUSD)).foregroundStyle(.secondary)
                            }
                            Text("\(Self.tokenLabel(m.tokensIn)) in · \(Self.tokenLabel(m.tokensOut)) out")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Estimated total", value: Self.costLabel(usage.totalUSD))
                    NavigationLink {
                        ModelPricingEditorView()
                    } label: {
                        Label("Edit model pricing", systemImage: "slider.horizontal.3")
                    }
                } header: {
                    Text("Tokens & estimated cost")
                } footer: {
                    Text("Estimated from each provider's reported token usage at list prices. Local-only — never leaves your device. Realtime voice sessions and streamed Chat replies aren't counted yet.")
                }
            }
        }
        .ogFormStyle()
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        report = InsightsService.shared.report(days: days)
        usage = UsageTracker.shared.rollup(days: days)
    }

    /// "$1.23", "<$0.01" for a tiny non-zero cost, or "—" when unpriced.
    private static func costLabel(_ usd: Double?) -> String {
        guard let usd else { return "—" }
        if usd > 0 && usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    /// Compact token count: "1,234", "12.3K", "1.2M".
    private static func tokenLabel(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...: return String(format: "%.1fK", Double(count) / 1_000)
        default:
            let f = NumberFormatter(); f.numberStyle = .decimal
            return f.string(from: NSNumber(value: count)) ?? "\(count)"
        }
    }
}
