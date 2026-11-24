#if DAT_EXPERIMENTAL
import SwiftUI

// Plan NB §5. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// Settings › Advanced & Support › Advanced › Developer, in a flagged build only, under the Inputs
/// probe: Start and Stop for the Motion probe, with the prompt to follow. What it recorded goes in
/// the support report.
struct MotionProbeSection: View {
    var body: some View {
        if GlassesSupportPolicy.isSupported, let probe = DATExperimentalFeatures.motionProbe {
            MotionProbeRows(probe: probe, ledger: .shared)
        }
    }
}

private struct MotionProbeRows: View {
    @ObservedObject var probe: MotionProbe
    @ObservedObject var ledger: MotionProbeLedger

    var body: some View {
        OGSection(
            header: "Neural Band Motion",
            footer: "A one-minute run with the Neural Band on: follow each step shown here while it records how the band's motion and pinches arrive, for the support report. Counts and angles only."
        ) {
            Button {
                if probe.isRunning {
                    probe.stop()
                } else {
                    Task { @MainActor in await DATExperimentalFeatures.startMotionProbe() }
                }
            } label: {
                if probe.isRunning {
                    OGRow("Stop recording", icon: "stop.circle", showsChevron: false) {
                        OGRowValue(verbatim: countText)
                    }
                } else {
                    OGRow("Record Neural Band motion (1 min)", icon: "hand.pinch", showsChevron: false) {
                        OGRowValue(verbatim: lastRunText)
                    }
                }
            }
            .buttonStyle(.plain)
            if let note = noteText {
                OGDivider()
                Text(note)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    /// Band samples in the prompt's window so far.
    private var countText: String? {
        guard let record = ledger.current?.prompts.last else { return nil }
        return String(localized: "\(record.bandSamples) samples")
    }

    private var lastRunText: String? {
        guard let run = ledger.runs.last, run.stop != nil else { return nil }
        let samples = run.prompts.reduce(0) { $0 + $1.bandSamples }
        return String(localized: "Last run: \(samples) samples")
    }

    /// The step to follow while running; why Start did nothing otherwise.
    private var noteText: String? {
        if let prompt = probe.prompt { return prompt.instruction }
        switch ledger.lastRefusal {
        case nil, .alreadyRunning: return nil
        case .notConnected: return String(localized: "Connect your glasses first.")
        case .otherProbeRunning: return String(localized: "Stop recording glasses inputs first.")
        case .heldOnThisChannel, .notInThisBuild: return String(localized: "Not available in this copy of the app.")
        case .glassesNotSupported: return String(localized: "Smart glasses aren't supported in this version.")
        }
    }
}
#endif
