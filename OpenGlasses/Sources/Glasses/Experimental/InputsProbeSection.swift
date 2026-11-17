#if DAT_EXPERIMENTAL
import SwiftUI

// Plan JV P2. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// Settings › Advanced & Support › Advanced › Developer, in a flagged build only: Start and Stop for
/// the Inputs probe, with a live count. What it recorded goes in the support report.
struct InputsProbeSection: View {
    var body: some View {
        if GlassesSupportPolicy.isSupported, let probe = DATExperimentalFeatures.inputsProbe {
            InputsProbeRows(probe: probe, ledger: .shared)
        }
    }
}

private struct InputsProbeRows: View {
    @ObservedObject var probe: InputsProbe
    @ObservedObject var ledger: InputsProbeLedger

    var body: some View {
        OGSection(
            header: "Glasses Inputs",
            footer: "Records each touch the glasses send for up to five minutes, for the support report. Only the touchpad is asked for: the capture button and Back stay with Meta."
        ) {
            Button {
                if probe.isRunning {
                    probe.stop()
                } else {
                    Task { @MainActor in await probe.start() }
                }
            } label: {
                if probe.isRunning {
                    OGRow("Stop recording", icon: "stop.circle", showsChevron: false) {
                        OGRowValue(verbatim: countText)
                    }
                } else {
                    OGRow("Record glasses inputs (5 min)", icon: "hand.tap", showsChevron: false) {
                        OGRowValue(verbatim: lastRunText)
                    }
                }
            }
            .buttonStyle(.plain)
            if let refusal = refusalText {
                OGDivider()
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    /// The run going now: how many inputs so far.
    private var countText: String? {
        guard let run = ledger.current else { return nil }
        return String(localized: "\(run.inputCount) inputs")
    }

    /// The last run's count once it has ended.
    private var lastRunText: String? {
        guard let run = ledger.runs.last, run.stop != nil else { return nil }
        return String(localized: "Last run: \(run.inputCount) inputs")
    }

    private var refusalText: String? {
        switch ledger.lastRefusal {
        case nil, .alreadyRunning: return nil
        case .notConnected: return String(localized: "Connect your glasses first.")
        case .heldOnThisChannel, .notInThisBuild: return String(localized: "Not available in this copy of the app.")
        case .glassesNotSupported: return String(localized: "Smart glasses aren't supported in this version.")
        }
    }
}
#endif
