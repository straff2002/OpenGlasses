import SwiftUI

/// Everything this phone can try, by situation (Plan KH P1). One row in the Settings hub reaches it.
/// It is the same catalogue the cards read, so a card that has left is still here.
struct ThingsToTryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ScenarioProgressStore.shared

    private var entries: [ScenarioEntry] {
        ScenarioReadiness.visible(ScenarioCatalog.all, in: appState.scenarioContext)
    }

    /// These are Direct-mode turns, on the grid's own rule.
    private var canRunHere: Bool { HomeSurfaceVisibility.showsActionTiles(mode: appState.currentMode) }

    var body: some View {
        OGScrollPage {
            if !canRunHere {
                OGNotice(text: "These run in the standard voice mode. Switch out of the live session to try them.",
                         systemImage: "waveform")
            }
            let entries = entries
            ForEach(ScenarioIntent.allCases, id: \.self) { intent in
                let group = entries.filter { $0.scenario.intent == intent }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: intent.title)
                            .textCase(.uppercase)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .accessibilityAddTraits(.isHeader)
                        OGCard {
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { OGDivider() }
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Things to Try")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ entry: ScenarioEntry) -> some View {
        let tried = store.progress.tried.contains(entry.id)
        Button { open(entry) } label: {
            OGRow(entry.scenario.title, icon: entry.scenario.icon, subtitle: entry.detail,
                  showsChevron: isActionable(entry)) {
                if tried {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isActionable(entry))
        .accessibilityValue(tried ? Text("Tried") : Text(verbatim: ""))
    }

    private func isActionable(_ entry: ScenarioEntry) -> Bool {
        switch entry.readiness {
        case .ready: return canRunHere
        case .needsSetup(let step): return step.destination != nil
        case .hidden: return false
        }
    }

    private func open(_ entry: ScenarioEntry) {
        if case .needsSetup(let step) = entry.readiness {
            guard let destination = step.destination else { return }
            // Back to the hub first: the request lands there, and pushing a category on top of
            // this page would leave two ways back to the same place.
            dismiss()
            appState.openSettings(destination)
            return
        }
        // Busy, a turn sent now is dropped without a word, and must not count as tried.
        guard canRunHere, appState.acceptsTypedTurn else { return }
        store.markTried(entry.id)
        appState.requestedTab = .voice
        Task { await HomeGridDispatcher.run(.builtIn(entry.scenario.action), on: appState) }
    }
}
