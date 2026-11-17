#if DAT_EXPERIMENTAL
import SwiftUI

// Plan JV P1. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// Devices & Privacy › Glasses, in a flagged build only: the wearer's switches for Meta's beta
/// glasses features.
struct DATExperimentalSettingsSection: View {
    @State private var voiceInvocationOn = DATExperimentalPolicy.isSwitchOn(.voiceInvocation)

    /// Why the feature cannot run in this copy whatever the switch says, if it cannot.
    private var heldReason: String? {
        switch DATExperimentalPolicy.current(.voiceInvocation) {
        case .runs, .switchedOff, .notInThisBuild: return nil
        case .heldOnThisChannel: return String(localized: "Not available in this copy of the app.")
        case .glassesNotSupported: return String(localized: "Smart glasses aren't supported in this version.")
        }
    }

    var body: some View {
        Section {
            Toggle("Hey Meta, open Avenkin", isOn: $voiceInvocationOn)
                .onChange(of: voiceInvocationOn) { _, on in
                    DATExperimentalPolicy.setSwitch(.voiceInvocation, on: on)
                    DATExperimentalFeatures.settingChanged()
                }
            if let heldReason {
                Text(heldReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Beta")
        } footer: {
            Text("Say “Hey Meta, open Avenkin” to the glasses to start talking to Avenkin, with your phone in your pocket. Meta's beta feature, only in this test build.")
        }
    }
}
#endif
