import SwiftUI

/// Everything this phone can try, by situation (Plan KH P1). One row in Settings reaches it: the
/// first row of Everyday, or beside About where Everyday cannot be reached (Plan KH P2).
/// It is the same catalogue the cards read, so a card that has left is still here.
struct ThingsToTryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ScenarioProgressStore.shared
    /// Set when this page is pushed inside the Voice tab's sheet. Everything that goes somewhere
    /// else leaves through it, because nothing can open from under a sheet and `dismiss` here would
    /// only pop back to it.
    var leaveSheet: ((ScenarioSheetExit) -> Void)? = nil

    private var entries: [ScenarioEntry] {
        ScenarioReadiness.visible(ScenarioCatalog.all, in: appState.scenarioContext)
    }

    /// Plan KH: outside the catalogue on purpose, see `StreamLiveLink`.
    private var showsStreamLive: Bool {
        StreamLiveLink.isVisible(broadcastConfigured: Config.isBroadcastConfigured,
                                 in: appState.scenarioContext)
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
            if showsStreamLive {
                OGCard {
                    Button {
                        if let leaveSheet { leaveSheet(.livePreview) } else { appState.openLivePreview() }
                    } label: {
                        OGRow("Stream live", icon: "dot.radiowaves.left.and.right",
                              subtitle: "Open the preview and go live.")
                    }
                    .buttonStyle(.plain)
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
            if let leaveSheet {
                leaveSheet(.settings(destination))
                return
            }
            // Back out first: the request lands on the hub, and pushing a category on top of this
            // page would leave two ways back to the same place.
            dismiss()
            appState.openSettings(destination)
            return
        }
        // Busy, a turn sent now is dropped without a word, and must not count as tried.
        guard canRunHere, appState.acceptsTypedTurn else { return }
        if let leaveSheet {
            leaveSheet(.run(entry))
            return
        }
        store.markTried(entry.id)
        appState.requestedTab = .voice
        Task { await HomeGridDispatcher.run(.builtIn(entry.scenario.action), on: appState) }
    }
}

/// The row that leads to Things to Try, beside About in Settings and in the Voice tab's sheet.
struct ThingsToTryRow: View {
    var body: some View {
        OGRow("Things to Try", icon: "sparkles", subtitle: "Ideas for what to do with it")
    }
}
