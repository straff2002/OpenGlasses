#if !AVENKIN_PHONE_ONLY
import Foundation

/// The app side of the smart ring (Plan MZ P2–P4): its trigger goes to the temple-tap performer,
/// its low battery is said once, Live Coach reads its fresh heart rate, and it runs only while the
/// ring support is on.
extension AppState {

    func setUpRing() {
        let ring = ringService
        ring.triggerActivity = { [weak self] in self?.templeContext().activity ?? .standby }
        ring.onTriggerAction = { [weak self] action in
            Task { @MainActor in
                guard let self else { return }
                self.noteUserInteraction()
                _ = await RingTriggerRunner.run(action, performer: self)
            }
        }
        ring.announce = { [weak self] line in
            Task { @MainActor in await self?.speechService.speak(line, source: .acknowledgement) }
        }
        LiveCoachService.shared.heartRateNow = { [weak ring] in
            guard Config.ringSupportEnabled else { return nil }
            return ring?.liveReadings.freshBeatsPerMinute
        }
        if Config.ringSupportEnabled { ring.start() }
    }

    /// The Developer panel's switch: on starts the ring (and with a paired one, its link), off lets
    /// it go and shows nothing ring-related anywhere.
    func ringSupportChanged(_ enabled: Bool) {
        if enabled { ringService.start() } else { ringService.stop() }
    }
}
#endif
