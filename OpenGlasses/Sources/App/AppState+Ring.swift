#if !AVENKIN_PHONE_ONLY
import Foundation
import UIKit
import UserNotifications

/// The app side of the smart ring (Plan MZ P2–P4): its trigger goes to the temple-tap performer,
/// its low battery is said once, and Live Coach reads its fresh heart rate. It starts at launch only
/// with a paired ring; pairing one in Devices & Privacy › Smart Ring starts it.
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
        LiveCoachService.shared.heartRateNow = { [weak ring] in ring?.liveReadings.freshBeatsPerMinute }
        // Without a paired ring nothing starts: pairing starts it (`RingService.pair`).
        if ring.isPaired { ring.start() }
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
}
#endif
