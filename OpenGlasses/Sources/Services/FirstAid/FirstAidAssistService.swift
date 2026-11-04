import Foundation
import UIKit

/// Hands-free first-aid coach (First-Aid / Emergency Assist). Runs a `FirstAidProtocol` step by step —
/// speaking each instruction, mirroring it to the in-lens HUD — and paces CPR with the `CPRMetronome`.
/// **Advisory only, not a medical device:** every protocol opens with the call-emergency-services gate,
/// and nothing here performs a real-world action.
///
/// The pure decision logic lives in `CPRMetronome` / `FirstAidProtocol` / `AEDFinder` (all unit-tested);
/// this is the `@MainActor` layer that drives audio, the HUD, the metronome timer, and the AED lookup.
@MainActor
final class FirstAidAssistService: ObservableObject {

    static let shared = FirstAidAssistService()

    @Published private(set) var isActive = false
    @Published private(set) var currentInstruction = ""

    private weak var tts: TextToSpeechService?
    private weak var glassesDisplay: GlassesDisplayService?
    private weak var location: LocationService?
    private let aedFinder = AEDFinder()

    private var runner: FirstAidProtocolRunner?
    private var metronome = CPRMetronome()
    private var metronomeTimer: Timer?

    func configure(tts: TextToSpeechService, glassesDisplay: GlassesDisplayService?, location: LocationService?) {
        self.tts = tts
        self.glassesDisplay = glassesDisplay
        self.location = location
    }

    // MARK: - Protocol flow

    /// Start a protocol by id (e.g. "cpr", "choking", "bleeding"). Announces the emergency-services gate.
    @discardableResult
    func start(protocolId: String) -> Bool {
        guard let proto = FirstAidProtocol.named(protocolId) else { return false }
        stopMetronome()
        runner = FirstAidProtocolRunner(proto: proto)
        isActive = true
        announce(runner!.current)
        return true
    }

    /// Advance to the next step (voice "next" / band button). Starts the CPR metronome when the step
    /// calls for compressions.
    func next() {
        guard var current = runner else { return }
        guard let step = current.advance() else {
            announce(text: "Keep going until help arrives or they start breathing normally.")
            return
        }
        runner = current
        if step.startsCPR { startMetronome() } else { stopMetronome() }
        announce(step)
    }

    func back() {
        guard var current = runner else { return }
        let step = current.back()
        runner = current
        if !step.startsCPR { stopMetronome() }
        announce(step)
    }

    func stop() {
        stopMetronome()
        runner = nil
        isActive = false
        glassesDisplay?.clear()
    }

    // MARK: - AED

    /// Find the nearest defibrillator and speak the distance; offers a walking route in Maps.
    @discardableResult
    func findNearestAED() async -> String {
        guard let coordinate = location?.currentLocation?.coordinate else {
            announce(text: "I can't get your location right now.")
            return "Location unavailable."
        }
        do {
            guard let aed = try await aedFinder.nearestAED(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
                announce(text: "No defibrillator found nearby.")
                return "No AED found within range."
            }
            let metres = Int(AEDFinder.distanceMeters(fromLat: coordinate.latitude, lon: coordinate.longitude,
                                                       toLat: aed.latitude, lon: aed.longitude))
            let place = aed.name ?? "a defibrillator"
            announce(text: "Nearest defibrillator: \(place), about \(metres) metres away.")
            openWalkingRoute(toLat: aed.latitude, lon: aed.longitude)
            return "Nearest AED: \(place), ~\(metres) m. Walking route opened."
        } catch {
            announce(text: "I couldn't search for a defibrillator right now.")
            return "AED search failed: \(error.localizedDescription)"
        }
    }

    private func openWalkingRoute(toLat lat: Double, lon: Double) {
        guard let url = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lon)&dirflg=w") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - CPR metronome

    private func startMetronome() {
        stopMetronome()
        metronome.reset()
        // Prime the first beat immediately, then schedule at the beat interval.
        fireMetronomeTick()
        metronomeTimer = Timer.scheduledTimer(withTimeInterval: metronome.beatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireMetronomeTick() }
        }
    }

    private func fireMetronomeTick() {
        let now = Date().timeIntervalSinceReferenceDate
        for event in metronome.tick(at: now) {
            switch event {
            case .compression:
                tts?.playMetronomeTick()
            case .breathBreak:
                Task { await tts?.speak("Two breaths, then keep going.", source: .coaching, urgency: .high, mirrorToHUD: false) }
            }
        }
    }

    private func stopMetronome() {
        metronomeTimer?.invalidate()
        metronomeTimer = nil
    }

    // MARK: - Output

    private func announce(_ step: FirstAidStep) {
        announce(text: step.instruction)
    }

    private func announce(text: String) {
        currentInstruction = text
        glassesDisplay?.showNavigation(text, icon: .hazard)
        Task { await tts?.speak(text, source: .coaching, urgency: .high, mirrorToHUD: false) }
    }
}
