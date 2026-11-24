#if DAT_EXPERIMENTAL
import SwiftUI

// Plan JV P1. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// Devices & Privacy › Glasses, in a flagged build only: the wearer's switches for Meta's experimental
/// glasses features.
struct DATExperimentalSettingsSection: View {
    @State private var voiceInvocationOn = DATExperimentalPolicy.isSwitchOn(.voiceInvocation)
    @State private var pageSwipesOn = DATExperimentalPolicy.isSwitchOn(.lensPageSwipes)
    @State private var twistZoomOn = DATExperimentalPolicy.isSwitchOn(.lensTwistZoom)
    @State private var twistReversed = DATExperimentalPolicy.isTwistReversed()
    @State private var armPanOn = DATExperimentalPolicy.isSwitchOn(.lensArmPan)

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
            Toggle("Swipe through manual pages", isOn: $pageSwipesOn)
                .onChange(of: pageSwipesOn) { _, on in
                    DATExperimentalPolicy.setSwitch(.lensPageSwipes, on: on)
                    DATExperimentalFeatures.settingChanged()
                }
            Text("On glasses with a display, swipe left or right with the Neural Band to move between the two halves of a close-up of a manual page, to the page before or after when a page is shown full width, or across a page you have zoomed into.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Twist to zoom manual pages", isOn: $twistZoomOn)
                .onChange(of: twistZoomOn) { _, on in
                    DATExperimentalPolicy.setSwitch(.lensTwistZoom, on: on)
                    DATExperimentalFeatures.settingChanged()
                }
            if twistZoomOn {
                Toggle("Reverse the twist", isOn: $twistReversed)
                    .onChange(of: twistReversed) { _, reversed in
                        DATExperimentalPolicy.setTwistReversed(reversed)
                    }
            }
            Text("Pinch and hold with the Neural Band, then turn your wrist like a dial: clockwise zooms in, anticlockwise zooms out. Reverse the twist if it goes the wrong way for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Pinch and move your arm to pan", isOn: $armPanOn)
                .onChange(of: armPanOn) { _, on in
                    DATExperimentalPolicy.setSwitch(.lensArmPan, on: on)
                    DATExperimentalFeatures.settingChanged()
                }
            Text("Pinch and hold with the Neural Band, then move your arm to move across a zoomed-in manual page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let heldReason {
                Text(heldReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Say “Hey Meta, open Avenkin” to the glasses to start talking to Avenkin, with your phone in your pocket.")
        }
    }
}
#endif
