#if DAT_MOCK_DISPLAY
import SwiftUI

/// Developer › Simulated Display (Plan KV P4): present only in a build generated with
/// `AVENKIN_DAT_MOCK_DISPLAY=1`, which runs on the iOS Simulator alone.
struct SimulatedDisplaySection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var lab = SimulatedDisplayLab.shared
    @State private var walking = false

    var body: some View {
        OGSection(
            header: "Simulated Display",
            footer: "A development tool for the Simulator: simulated Display glasses, paired, switched on and worn, so the HUD and the manual page view draw on a simulated lens through the real display path. The lens is in the floating square, and in Chrome at the address shown with Meta's Display simulator extension. It adds an invented test manual to open pages from. Never in a build that ships."
        ) {
            OGRow("Simulated Display", isOn: Binding(
                get: { lab.isOn },
                set: { on in
                    Task { @MainActor in
                        if on { await lab.switchOn(appState: appState) } else { await lab.switchOff(appState: appState) }
                    }
                }), icon: "eyeglasses")
            if lab.isOn {
                OGDivider()
                OGRow("Show the lens preview", isOn: $lab.previewVisible, icon: "square.on.square")
                if let address = lab.serverAddress {
                    OGDivider()
                    OGRow("Chrome address", icon: "globe", verbatimValue: address, showsChevron: false)
                }
                ForEach(SimulatedDisplayExample.allCases) { example in
                    OGDivider()
                    Button {
                        lab.previewVisible = true
                        example.open(on: appState)
                    } label: {
                        OGRow(LocalizedStringKey(example.title), icon: example.icon, showsChevron: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(walking)
                }
                OGDivider()
                Button {
                    walking = true
                    Task { @MainActor in
                        await SimulatedDisplayWalkthrough(appState: appState, lab: lab).run()
                        walking = false
                    }
                } label: {
                    OGRow(walking ? "Running page walkthrough…" : "Run page walkthrough",
                          icon: "play.rectangle", mutedIcon: walking, showsChevron: false)
                }
                .buttonStyle(.plain)
                .disabled(walking)
            }
            if !lab.status.isEmpty, lab.status != "On" {
                Text(verbatim: lab.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
