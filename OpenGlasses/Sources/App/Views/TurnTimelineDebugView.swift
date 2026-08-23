import SwiftUI

/// Developer → Turn Timeline (Plan CU P1): the sealed turns in `TurnLedger`, each expandable to
/// its full stage-by-stage breakdown, plus the aggregate the plan insists on — perceived latency
/// split by `backend` × `ttsEngine` × `micRoute`, never pooled (see `TurnTimeline.Cohort`).
///
/// Reads `TurnLedger` directly rather than through a view model — the same "pure core + thin view"
/// split `SubsystemTestRunner`/`DeveloperPanelView` already use. This screen has nothing to add to
/// that core beyond formatting.
struct TurnTimelineDebugView: View {
    @ObservedObject var ledger: TurnLedger
    @Environment(\.appAccent) private var accent
    @State private var expandedTurnIDs: Set<UUID> = []

    /// The ring already caps at `ledger.maxCount`; this caps what one screen renders at once. A
    /// non-lazy `VStack` (what `OGCard` builds on) holding 200 expandable rows is a lot of view
    /// identity to keep alive for a "last N" list nobody scrolls that far into.
    private static let displayLimit = 25

    private var recentTurns: [TurnTimeline] {
        Array(ledger.sealed.suffix(Self.displayLimit).reversed())
    }

    private var cohortEntries: [(key: TurnTimeline.Cohort, value: TurnLedger.Stats)] {
        ledger.perceivedLatencyByCohort.sorted { cohortLabel($0.key) < cohortLabel($1.key) }
    }

    var body: some View {
        OGScrollPage {
            OGNotice(
                text: "Measured on this device only — no telemetry is sent anywhere. Perceived latency is speech end → first audio: the dead air you actually hear.",
                systemImage: "gauge"
            )

            recentTurnsSection
            cohortSection
            exportSection
        }
        .textSelection(.enabled)
        .tint(accent)
        .navigationTitle("Turn Timeline")
    }

    // MARK: - Recent turns

    private var recentTurnsSection: some View {
        OGSection(
            header: "Recent Turns",
            footer: "Newest \(recentTurns.count) of \(ledger.sealed.count) sealed · \(ledger.inFlightCount) in flight. Tap a turn for its stage-by-stage breakdown."
        ) {
            if recentTurns.isEmpty {
                Text(ledger.inFlightCount > 0
                     ? "No sealed turns yet — \(ledger.inFlightCount) in flight."
                     : "No sealed turns yet. A turn appears here once it's sealed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(recentTurns.enumerated()), id: \.element.id) { index, turn in
                    if index > 0 {
                        // OGDivider's 57pt inset clears OGRow's icon tile; this row has none, so
                        // it aligns to the row's own 16pt content edge instead.
                        Rectangle()
                            .fill(OGTheme.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                    turnRow(turn)
                }
            }
        }
    }

    private func turnRow(_ turn: TurnTimeline) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(for: turn.id)) {
            turnDetail(turn)
        } label: {
            turnHeaderLabel(turn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func expandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedTurnIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedTurnIDs.insert(id)
                } else {
                    expandedTurnIDs.remove(id)
                }
            }
        )
    }

    private func turnHeaderLabel(_ turn: TurnTimeline) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(Self.formatOptionalSeconds(turn.perceivedLatency))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                if turn.abandoned {
                    OGStatusPill(text: "Abandoned", dot: OGTheme.error, tinted: false)
                }
                if turn.interrupted {
                    OGStatusPill(text: "Interrupted", dot: OGTheme.warn, tinted: false)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                OGChip(text: turn.backend?.label ?? "unknown", available: turn.backend != nil)
                OGChip(text: turn.ttsEngine?.rawValue ?? "unknown", available: turn.ttsEngine != nil)
                OGChip(text: turn.micRoute?.shortLabel ?? "unknown", available: turn.micRoute != nil)
                // Plan CU P2: which signal ended the wearer's speech. Shown only when there was
                // one — a typed turn has no endpointing story, and "unknown" would imply it did.
                if let reason = turn.endOfTurnReason {
                    OGChip(text: reason.rawValue, available: true)
                }
                Spacer(minLength: 0)
                Text(turn.id.uuidString.prefix(8))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func turnDetail(_ turn: TurnTimeline) -> some View {
        let anchor = TurnTimeline.Stage.allCases.first { turn[$0] != nil }
        return VStack(alignment: .leading, spacing: 10) {
            clusterHeader("Stage marks")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TurnTimeline.Stage.allCases, id: \.self) { stage in
                    HStack {
                        Text(stage.label)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        stageMarkValue(turn, stage, anchor: anchor)
                    }
                }
            }

            clusterHeader("Derived")
            derivedMetricsList(turn)

            clusterHeader("Spans")
            spansCluster(turn)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clusterHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
    }

    /// A stage mark is one of three completely different facts, and the row must not blur them:
    /// never landed ("not recorded"), landed but nothing precedes it to measure from ("starts
    /// here" — this turn's first mark), or landed with a measurable gap since the previous mark.
    @ViewBuilder
    private func stageMarkValue(_ turn: TurnTimeline, _ stage: TurnTimeline.Stage, anchor: TurnTimeline.Stage?) -> some View {
        if turn[stage] == nil {
            Text("not recorded")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .italic()
        } else if stage == anchor {
            Text("starts here")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .italic()
        } else if let segment = turn.segments.first(where: { $0.stage == stage }) {
            Text(Self.formatSigned(segment.seconds))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        } else {
            // Unreachable: a landed, non-anchor stage always has an earlier landed mark to gap
            // from, so `segments` always carries an entry for it. Kept as a safe fallback rather
            // than force-unwrapping.
            Text("—")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func derivedMetricsList(_ turn: TurnTimeline) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            metricRow("Endpointing delay", turn.endpointingDelay)
            metricRow("Time to first token", turn.timeToFirstToken)
            metricRow("  model only, frame grab out", turn.modelTimeToFirstToken)
            metricRow("Backend total", turn.backendSeconds)
            metricRow("  model only, tools + frame grab out", turn.modelSeconds)
            ttsLeadInRow(turn)
            metricRow("TTS time to first byte", turn.ttsTimeToFirstByte)
            metricRow("Playback", turn.playbackSeconds)
            metricRow("HUD latency", turn.hudLatency)
            metricRow("Total, speech end to done", turn.totalSeconds)
            HStack {
                Text("Generation rate")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if let rate = turn.tokensPerSecond {
                    Text(String(format: "%.1f tok/s", rate))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("not recorded")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
    }

    /// Signed on purpose, mirroring `TurnTimeline.ttsLeadIn` itself: negative means speech started
    /// before generation finished, which is the good case and the entire point of sentence-
    /// streaming TTS. A bare "-0.80s" reads as an error, so the good case gets a checkmark and a
    /// plain-English gloss rather than relying on the sign alone.
    @ViewBuilder
    private func ttsLeadInRow(_ turn: TurnTimeline) -> some View {
        HStack(alignment: .top) {
            Text("TTS lead-in")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let leadIn = turn.ttsLeadIn {
                    HStack(spacing: 4) {
                        if leadIn < 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(OGTheme.ok)
                        }
                        Text(Self.formatSigned(leadIn))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(leadIn < 0 ? "spoke before generation finished" : "waited after generation finished")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("not recorded")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
    }

    private func spansCluster(_ turn: TurnTimeline) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Frame grab")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.formatSeconds(turn.frameGrabSeconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Tool time (\(turn.toolIterations)×)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.formatSeconds(turn.toolSeconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("App work in backend leg")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.formatSeconds(turn.nonModelSeconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Held before this turn")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.formatSeconds(turn.heldSeconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            metricRow("Wait including hold", turn.waitIncludingHold)
        }
    }

    private func metricRow(_ label: String, _ seconds: TimeInterval?) -> some View {
        HStack {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            if let seconds {
                Text(Self.formatSeconds(seconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("not recorded")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
    }

    // MARK: - Cohort aggregate

    /// `TurnTimeline.Cohort` exists precisely so this can't be flattened into one number — see its
    /// own doc comment. One `OGStatTile` per cohort, full width, keeps every combination legible
    /// instead of cramming labels into a grid that would tempt someone to eyeball an average
    /// across them.
    private var cohortSection: some View {
        OGSection(
            header: "Perceived Latency by Cohort",
            footer: "Split by backend × TTS engine × mic route — never pooled. An 8 kHz glasses mic and a cloud TTS engine are a different population from a phone mic and on-device TTS; averaging across them would describe neither."
        ) {
            if cohortEntries.isEmpty {
                Text("No cohort has a sealed turn with a recorded perceived latency yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(cohortEntries, id: \.key) { entry in
                        OGStatTile(
                            value: Self.formatSeconds(entry.value.median),
                            caption: "\(cohortLabel(entry.key)) · median · n=\(entry.value.count) · mean \(Self.formatSeconds(entry.value.mean))"
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private func cohortLabel(_ cohort: TurnTimeline.Cohort) -> String {
        "\(cohort.backend?.label ?? "unknown") · \(cohort.ttsEngine?.rawValue ?? "unknown") · \(cohort.micRoute?.shortLabel ?? "unknown")"
    }

    // MARK: - Export

    private var exportSection: some View {
        let text = ledger.debugExport()
        return OGSection(
            header: "Export",
            footer: "Plain text — turn history plus per-cohort latency stats. Copying it is the only way these numbers leave the device."
        ) {
            Button {
                UIPasteboard.general.string = text
            } label: {
                OGRow("Copy Diagnostics", icon: "doc.on.doc", mutedIcon: true, showsChevron: false) {
                    OGRowValue(value: "\(ledger.sealed.count) turns")
                }
            }
            .buttonStyle(.plain)

            OGDivider()

            ShareLink(item: text, subject: Text("OpenGlasses turn ledger")) {
                OGRow("Share Diagnostics", icon: "square.and.arrow.up", mutedIcon: true, showsChevron: false) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Formatting

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private static func formatOptionalSeconds(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "not recorded" }
        return formatSeconds(seconds)
    }

    private static func formatSigned(_ seconds: TimeInterval) -> String {
        String(format: "%+.2fs", seconds)
    }
}
