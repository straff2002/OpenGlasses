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
    /// Plan NB: the Developer panel's Motion probe. Idle until the wearer presses Start.
    private(set) static var motionProbe: MotionProbe?
    /// Plan NB §6: pinch and twist to zoom, pinch and move to pan, on the manual page view.
    private(set) static var lensWrist: LensWristGestureService?
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
        let wrist = LensWristGestureService(
            source: MetaMotionSource(),
            switches: { wristSwitches() },
            sink: LensWristGestureService.Sink(
                twist: { [weak lensPage] rung in lensPage?.handleTwist(rung) },
                pan: { [weak lensPage] step in lensPage?.handleArmPan(step) },
                clutchOpened: { [weak lensPage] in lensPage?.wristClutchOpened() },
                clutchClosed: { [weak lensPage] in lensPage?.wristClutchClosed() },
                listening: { [weak lensPage] in lensPage?.noteWristListening() },
                failed: { [weak lensPage] failure in lensPage?.noteWristFailed(failure.rawValue) },
                ended: { [weak lensPage] in lensPage?.noteWristEnded() }))
        lensWrist = wrist
        let bandNav = LensBandNavService(
            source: LensBandInputsSource(withDrag: { wrist.wantsDrag }),
            // The band channel stays open for a wrist gesture with the swipes switched off: the
            // gestures' clutch rides on it. The page view acts on a swipe only with its switch on.
            isEnabled: { DATExperimentalPolicy.current(.lensPageSwipes) == .runs || wrist.wantsDrag },
            onInput: { [weak lensPage] input in
                wrist.handleBandInput(input)
                // The drag stream is the clutch's alone; the page view never maps it.
                if case .drag = input.kind { return }
                guard DATExperimentalPolicy.current(.lensPageSwipes) == .runs else { return }
                lensPage?.handleBand(input.kind)
            },
            onListening: { [weak lensPage] in lensPage?.noteBandListening() },
            onFailed: { [weak lensPage] failure in lensPage?.noteBandFailed(failure.rawValue) },
            onEnded: { [weak lensPage] reason in lensPage?.noteBandEnded(reason) })
        lensBandNav = bandNav
        let motion = MotionProbe(
            motionSource: MetaMotionSource(),
            inputsSource: MetaInputsSource(purpose: .probe),
            ledger: .shared,
            verdict: { DATExperimentalPolicy.currentForDiagnostics() },
            otherProbeRunning: { [weak probe] in probe?.isRunning ?? false },
            outputVolume: { AVAudioSession.sharedInstance().outputVolume })
        motionProbe = motion
        cancellables.append(lensPage.$held
            .map { $0 == .view }
            .removeDuplicates()
            .sink { onLens in
                DispatchQueue.main.async { bandNav.update(viewOnLens: onLens) }
            })
        cancellables.append(lensPage.$held
            .combineLatest(lensPage.$shownView)
            .map { pair in pair.0 == .view ? pair.1 : nil }
            .removeDuplicates()
            .sink { view in
                DispatchQueue.main.async { wrist.update(view: view) }
            })
        cancellables.append(probe.$phase
            .combineLatest(motion.$phase)
            .map { phases in phases.0 != .idle || phases.1 != .idle }
            .removeDuplicates()
            .sink { running in
                DispatchQueue.main.async {
                    bandNav.update(probeRunning: running)
                    wrist.update(probeRunning: running)
                }
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
                    motion.update(connectedDeviceIds: ids)
                    wrist.update(connectedDeviceIds: ids)
                }
            })
    }

    /// The wearer's switch changed in Settings. The band channel is asked for again, so it carries
    /// the drag stream exactly while a wrist gesture is on.
    static func settingChanged() {
        voiceInvocations?.refresh()
        lensBandNav?.reopen()
        lensWrist?.refresh()
    }

    /// Plan NB §6: the wearer's wrist-gesture switches, as the gestures read them at each clutch.
    static func wristSwitches() -> LensWristGestures.Switches {
        LensWristGestures.Switches(
            twist: DATExperimentalPolicy.current(.lensTwistZoom) == .runs,
            pan: DATExperimentalPolicy.current(.lensArmPan) == .runs,
            direction: TwistDirection.current(reversed: DATExperimentalPolicy.isTwistReversed()))
    }

    /// The Developer panel's Start: the page view's band channel hands the one Inputs capability
    /// back first, and listens again once the run is over (or was refused). Not while the Motion
    /// probe runs: it holds Inputs too.
    static func startInputsProbe() async {
        guard let probe = inputsProbe, motionProbe?.isRunning != true else { return }
        if !probe.isRunning { await lensBandNav?.yield() }
        await probe.start()
        lensBandNav?.update(probeRunning: probe.isRunning)
    }

    /// Plan NB §5: the Motion probe's Start. The page view's band and wrist channels hand Inputs
    /// and Motion back first, and listen again once the run is over (or was refused).
    static func startMotionProbe() async {
        guard let probe = motionProbe else { return }
        if !probe.isRunning, inputsProbe?.isRunning != true {
            await lensBandNav?.yield()
            await lensWrist?.yield()
        }
        await probe.start()
        let running = probe.isRunning || inputsProbe?.isRunning == true
        lensBandNav?.update(probeRunning: running)
        lensWrist?.update(probeRunning: running)
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
