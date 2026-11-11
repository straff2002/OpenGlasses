import SwiftUI

/// Settings › Devices & Privacy › Glasses › Instant Replay: the switch (off by default), how much it
/// keeps, and a footer that says plainly what it keeps, for how long, how big it gets and where it
/// never goes.
struct InstantReplaySettingsSection: View {
    @ObservedObject var replay: ReplayBufferService
    @State private var enabled = Config.instantReplayEnabled
    @State private var bufferSeconds = Config.instantReplayBufferSeconds

    private var locked: Bool { PolicyEnvelope.isLocked(.instantReplayEnabled) }

    /// The size line for the stream as configured now — or, once the buffer runs, as delivered.
    private var plan: ReplayBufferPlan {
        if case .run(let running) = replay.decision, running.bufferSeconds == bufferSeconds {
            return running
        }
        return .estimate(bufferSeconds: bufferSeconds, resolution: Config.cameraResolution,
                         frameRate: Config.cameraFrameRate)
    }

    var body: some View {
        Section {
            Toggle("Instant Replay", isOn: $enabled)
                // An organisation's pin is drawn read-only rather than hidden: a protection for
                // the people in front of the glasses that the wearer must be able to see is off.
                .disabled(locked || Config.hipaaMode)
                .onChange(of: enabled) { _, newValue in
                    Config.instantReplayEnabled = newValue
                    enabled = Config.instantReplayEnabled
                    replay.reconcile()
                }
            ManagedSettingNote(key: .instantReplayEnabled)
            if enabled {
                Picker("Keep", selection: $bufferSeconds) {
                    ForEach(ReplayBufferPlan.bufferChoices, id: \.self) { seconds in
                        Text(Self.choiceLabel(seconds)).tag(seconds)
                    }
                }
                .onChange(of: bufferSeconds) { _, newValue in
                    Config.instantReplayBufferSeconds = newValue
                    replay.reconcile()
                }
                LabeledContent("Now", value: statusValue)
            }
        } header: {
            Text("Instant Replay")
        } footer: {
            Text("Off unless you turn it on. While the glasses camera is already on for something else — a live session, a recording, a broadcast — the last \(ReplaySaveOutcome.length(bufferSeconds)) of what it sees is kept on this phone, with faces blurred when Blur Bystander Faces is on, and no sound. Say \u{201C}keep the last 30 seconds\u{201D} or \u{201C}save the replay\u{201D} to save it to Recordings. It never turns the camera on, a Replay mark shows on the session card while it runs, it is deleted when the camera stops, it is never uploaded, and it is off in Medical Compliance mode. \(plan.footerSizeLine)")
        }
    }

    private var statusValue: String {
        switch replay.decision {
        case .off(let reason): return reason.statusLine
        case .run:
            let held = Int(replay.bufferedSeconds.rounded())
            return held < 1 ? String(localized: "Starting") : String(localized: "Keeping \(held) s")
        }
    }

    static func choiceLabel(_ seconds: TimeInterval) -> String {
        switch Int(seconds) {
        case 30: return String(localized: "30 seconds")
        case 60: return String(localized: "1 minute")
        default: return String(localized: "2 minutes")
        }
    }
}
