#if DAT_EXPERIMENTAL
import AVFoundation
import Combine
import Foundation
import UIKit

// Plan JV. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight only,
// never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// The one entry point the glasses services' start-up calls in a flagged build
/// (`AppState.setupServiceCallbacks`), and what the experimental features hold while they run.
@MainActor
enum DATExperimentalFeatures {
    private(set) static var voiceInvocations: GlassesVoiceInvocationService?
    /// The Developer panel's Inputs probe (P2). Idle until the wearer presses Start.
    private(set) static var inputsProbe: InputsProbe?
    /// Plan MU §7: the band's left and right on the manual page view.
    private(set) static var lensBandNav: LensBandNavService?
    private static var cancellables: [AnyCancellable] = []

    /// Starts following the connected glasses. Idempotent. Nothing reaches the SDK until a pair's
    /// link is connected and `DATExperimentalPolicy` lets the feature run.
    static func start(appState: AppState) {
        guard voiceInvocations == nil else { return }
        let service = GlassesVoiceInvocationService(
            source: MetaVoiceInvocationSource(),
            ledger: .shared,
            isEnabled: { DATExperimentalPolicy.current(.voiceInvocation) == .runs },
            arrival: {
                let runState: VoiceInvocationArrival.RunState
                switch UIApplication.shared.applicationState {
                case .active: runState = .active
                case .inactive: runState = .inactive
                case .background: runState = .background
                @unknown default: runState = .background
                }
                return VoiceInvocationArrival(runState: runState,
                                              protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
            })
        service.performer = appState
        voiceInvocations = service
        let probe = InputsProbe(
            source: MetaInputsSource(),
            ledger: .shared,
            verdict: { DATExperimentalPolicy.currentForDiagnostics() },
            battery: { [weak appState] in appState?.glassesService.batteryLevel },
            // The media trigger's reading: another app's audio is audible.
            userAudioPlaying: { AVAudioSession.sharedInstance().isOtherAudioPlaying })
        inputsProbe = probe
        let lensPage = appState.lensPage
        let bandNav = LensBandNavService(
            source: MetaInputsSource(purpose: .lensBandNav),
            isEnabled: { DATExperimentalPolicy.current(.lensPageSwipes) == .runs },
            onInput: { [weak lensPage] kind in lensPage?.handleBand(kind) },
            onListening: { [weak lensPage] in lensPage?.noteBandListening() },
            onFailed: { [weak lensPage] in lensPage?.noteBandFailed() })
        lensBandNav = bandNav
        cancellables.append(lensPage.$held
            .map { $0 == .view }
            .removeDuplicates()
            .sink { onLens in
                DispatchQueue.main.async { bandNav.update(viewOnLens: onLens) }
            })
        cancellables.append(probe.$phase
            .map { $0 != .idle }
            .removeDuplicates()
            .sink { running in
                DispatchQueue.main.async { bandNav.update(probeRunning: running) }
            })
        // `@Published` fires in willSet, so the value is handed over; the hop lets the connection
        // service finish publishing first.
        cancellables.append(appState.glassesService.$connectedDeviceIds
            .removeDuplicates()
            .sink { ids in
                DispatchQueue.main.async {
                    service.update(connectedDeviceIds: ids)
                    probe.update(connectedDeviceIds: ids)
                    bandNav.update(connectedDeviceIds: ids)
                }
            })
    }

    /// The wearer's switch changed in Settings.
    static func settingChanged() {
        voiceInvocations?.refresh()
        lensBandNav?.refresh()
    }

    /// The Developer panel's Start: the page view's band channel hands the one Inputs capability
    /// back first, and listens again once the run is over (or was refused).
    static func startInputsProbe() async {
        guard let probe = inputsProbe else { return }
        if !probe.isRunning { await lensBandNav?.yield() }
        await probe.start()
        lensBandNav?.update(probeRunning: probe.isRunning)
    }
}

/// A request means what "start talking" means everywhere else: the same reading the temple taps
/// decide on, and the same entry points they call (`performTempleEffect(.startListening)`), with
/// its own source for a live session.
extension AppState: VoiceInvocationPerforming {

    func voiceInvocationContext() -> VoiceInvocationContext {
        VoiceInvocationContext(
            temple: templeContext(),
            otherPartyOnLine: MediaTriggerPolicy.classify(AudioSessionCoordinator.shared.currentOwner) == .otherParty)
    }

    func performVoiceInvocation(_ action: VoiceInvocationAction) async -> Bool {
        switch action {
        case .startListening:
            if currentMode == .direct {
                await handleWakeWordDetected(manual: true)
            } else {
                let outcome = await requestLiveSession(currentMode, source: .voiceInvocation)
                return outcome == .started || outcome == .alreadyActive
            }
        case .interruptAndListen:
            await interruptSpeechAndListen()
        }
        return VoiceInvocationResolver.isListening(templeContext().activity)
    }
}
#endif
