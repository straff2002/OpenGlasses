import SwiftUI

/// Settings → Advanced → Developer (Plan CL P2): one-tap cold-start
/// verification that each subsystem is alive — glasses link, camera,
/// HUD, AI round-trip, TTS, wake word — plus the live debug-event tail.
/// Field debugging starts here instead of "say the wake word and guess".
struct DeveloperPanelView: View {
    @ObservedObject var appState: AppState
    @StateObject private var runner: SubsystemTestRunner
    @Environment(\.appAccent) private var accent

    init(appState: AppState) {
        self.appState = appState
        _runner = StateObject(wrappedValue: Self.makeRunner(appState: appState))
    }

    var body: some View {
        OGScrollPage {
            OGNotice(
                text: "Each test exercises the real path — the camera takes a photo, the AI answers a tiny query, the lens renders a card.",
                systemImage: "stethoscope"
            )

            OGSection(header: "Subsystems") {
                ForEach(Array(runner.tests.enumerated()), id: \.element.id) { index, test in
                    if index > 0 { OGDivider() }
                    Button {
                        Task { await runner.run(test.id) }
                    } label: {
                        OGRow(test.name, icon: test.icon, showsChevron: false) {
                            trailingState(for: test.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(runner.running.contains(test.id))
                }

                if let failure = runner.lastFailure {
                    OGDivider()
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.error)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }

            Button {
                Task { await runner.runAll() }
            } label: {
                HStack(spacing: 8) {
                    if runner.isRunning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checklist")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(runner.isRunning ? "Running…" : "Run All")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(runner.isRunning ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(accent), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(runner.isRunning)

            OGSection(header: "Turn Latency") {
                NavigationLink {
                    TurnTimelineDebugView(ledger: appState.turnLedger)
                } label: {
                    OGRow(
                        "Turn Timeline", icon: "waveform.path.ecg",
                        subtitle: "Recorded voice turns, stage breakdown, cohort latency"
                    )
                }
                .buttonStyle(.plain)
            }

            OGSection(
                header: "Debug Events",
                footer: "The persistent field log lives in Documents/debug-events.log and survives relaunches."
            ) {
                if appState.debugEvents.isEmpty {
                    Text("No events yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(appState.debugEvents.suffix(60).reversed(), id: \.self) { event in
                                Text(event)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 260)
                    OGDivider()
                    Button {
                        UIPasteboard.general.string = appState.debugEvents.joined(separator: "\n")
                    } label: {
                        OGRow("Copy Log", icon: "doc.on.doc", mutedIcon: true, showsChevron: false) {
                            OGRowValue(value: "\(appState.debugEvents.count) events")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Developer")
    }

    @ViewBuilder
    private func trailingState(for id: String) -> some View {
        if runner.running.contains(id) {
            ProgressView()
        } else if let outcome = runner.outcomes[id] {
            HStack(spacing: 6) {
                if outcome.passed {
                    Text("\(outcome.detail) · \(SubsystemTestRunner.format(outcome.seconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.passed ? OGTheme.ok : OGTheme.error)
            }
        } else {
            Image(systemName: "play.circle")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Live probes

    /// The live edge: each probe exercises the real service. Kept here so
    /// `SubsystemTestRunner` stays a pure, unit-tested core.
    private static func makeRunner(appState: AppState) -> SubsystemTestRunner {
        let tests: [SubsystemTest] = [
            SubsystemTest(id: "glasses", name: "Glasses Link", icon: "eyeglasses") { @MainActor in
                guard appState.isConnected else {
                    return .fail("Not connected — pair via the Meta AI app")
                }
                let name = appState.glassesService.deviceName ?? "Glasses"
                let battery = appState.glassesService.batteryLevel.map { " · \($0)%" } ?? ""
                return .pass("\(name)\(battery)")
            },
            SubsystemTest(id: "camera", name: "Camera Photo", icon: "camera") { @MainActor in
                guard appState.isConnected else {
                    return .fail("Needs connected glasses")
                }
                do {
                    let data = try await appState.cameraService.capturePhoto()
                    return .pass("\(max(1, data.count / 1024)) KB photo")
                } catch {
                    return .fail(error.localizedDescription)
                }
            },
            SubsystemTest(id: "hud", name: "HUD Render", icon: "rectangle.dashed") { @MainActor in
                guard appState.glassesDisplay.hasDisplayCapability else {
                    return .fail("No display on this device")
                }
                appState.glassesDisplay.showNotification(
                    title: "Test", body: "Developer panel render check", icon: .info, duration: 4
                )
                return .pass("Card sent to lens")
            },
            SubsystemTest(id: "query", name: "AI Query", icon: "brain.head.profile") { @MainActor in
                guard Config.activeModel != nil else {
                    return .fail("No model configured")
                }
                do {
                    let reply = try await appState.llmService.completeStateless(
                        "Reply with exactly: OK",
                        system: "You are a connectivity probe. Reply with exactly: OK"
                    )
                    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.localizedCaseInsensitiveContains("ok")
                        ? .pass(Config.activeModel?.name ?? "Model answered")
                        : .fail("Unexpected reply: \(String(trimmed.prefix(60)))")
                } catch {
                    return .fail(error.localizedDescription)
                }
            },
            SubsystemTest(id: "tts", name: "Text to Speech", icon: "speaker.wave.2") { @MainActor in
                await appState.speechService.speak("Test okay", urgency: .low, mirrorToHUD: false)
                return .pass("Spoken")
            },
            SubsystemTest(id: "telemetry", name: "SDK Telemetry", icon: "antenna.radiowaves.left.and.right.slash") { @MainActor in
                // Verifies on-device what only a packet capture could otherwise tell us: that the
                // glasses SDK's data collection is off in the *shipped* bundle, and that nothing
                // has had to be blocked at the network layer to keep it that way.
                let optOut = MetaTelemetryBlock.bundleOptOut
                let blocked = MetaTelemetryBlock.blockedCount
                if !optOut.analytics || !optOut.crashReporting {
                    let missing = [optOut.analytics ? nil : "Analytics",
                                   optOut.crashReporting ? nil : "CrashReporting"].compactMap { $0 }
                    return .fail("Opt-out missing from Info.plist: \(missing.joined(separator: ", "))")
                }
                if blocked > 0 {
                    return .fail("Opt-out set but ignored — \(blocked) upload(s) blocked at the network layer")
                }
                return .pass("Opt-out set · no uploads attempted")
            },
            SubsystemTest(id: "wakeword", name: "Wake Word", icon: "waveform.badge.mic") { @MainActor in
                appState.wakeWordService.isListening
                    ? .pass("Listening for “\(Config.wakePhrase.capitalized)”")
                    : .fail("Not listening — check mic permission or silent mode")
            },
        ]
        return SubsystemTestRunner(tests: tests, log: { [weak appState] message in
            appState?.addDebugEvent(message)
        })
    }
}
