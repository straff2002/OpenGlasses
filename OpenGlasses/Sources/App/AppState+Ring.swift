#if !AVENKIN_PHONE_ONLY
import Foundation
import UIKit
import UserNotifications

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
                _ = await RingTriggerRunner.run(action, performer: self, microphone: self.ringMicrophoneFacts(),
                                                postNotice: { Self.postRingBackgroundListenNotice() })
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

    /// Whether a clench's turn can open the microphone now: in the foreground, or in the background
    /// with the audio session already live (always-on listening's engine, or the assistant
    /// speaking). iOS refuses to start a microphone from the background otherwise.
    func ringMicrophoneFacts() -> RingMicrophoneFacts {
        RingMicrophoneFacts(appActive: UIApplication.shared.applicationState == .active,
                            audioLive: wakeWordService.audioEngineRunning || speechService.isSpeaking)
    }

    /// A clench needed the microphone and the app couldn't open it. A notification is the one
    /// thing that reaches a phone in a pocket: no earcon or speech can play without a live session.
    static func postRingBackgroundListenNotice() {
        let content = UNMutableNotificationContent()
        content.title = RingBackgroundListenNotice.title
        content.body = RingBackgroundListenNotice.body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ring-background-listen", content: content, trigger: nil))
    }

    /// The Developer panel's switch: on starts the ring (and with a paired one, its link), off lets
    /// it go and shows nothing ring-related anywhere.
    func ringSupportChanged(_ enabled: Bool) {
        if enabled { ringService.start() } else { ringService.stop() }
    }
}
#endif
