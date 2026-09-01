import Foundation
import CallKit
import AVFoundation

/// Uses CallKit to keep the audio session alive in the background.
/// When a Gemini Live or OpenAI Realtime session is active, a "call" is reported
/// to iOS which prevents the audio session from being suspended when the app
/// moves to the background. This is how Matcha and other voice-first apps achieve
/// persistent voice sessions without the "App is using microphone" interruption.
///
/// Note: This uses a VoIP-style provider, so the `voip` UIBackgroundMode is required.
@MainActor
class BackgroundVoiceService: NSObject, ObservableObject {
    @Published var isBackgroundSessionActive = false

    private var provider: CXProvider?
    private var callController: CXCallController?
    private var activeCallUUID: UUID?

    override init() {
        super.init()
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        // Use a silent ringtone — we don't want the phone to ring
        config.ringtoneSound = nil
        // Icon displayed in the phone app
        config.iconTemplateImageData = nil

        provider = CXProvider(configuration: config)
        provider?.setDelegate(self, queue: nil)
        callController = CXCallController()
    }

    /// Start a background voice session. Call this when Gemini Live or OpenAI Realtime starts.
    /// The system will keep the audio session alive even when the app is backgrounded.
    func startBackgroundSession() {
        guard activeCallUUID == nil else {
            PrivacyLog.audio(.backgroundVoice, .callReported, detail: PrivacyToken("alreadyActive"))
            return
        }

        let uuid = UUID()
        activeCallUUID = uuid

        // Report an incoming "call" — this keeps the audio session alive
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "OpenGlasses AI")
        update.localizedCallerName = "OpenGlasses Assistant"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                PrivacyLog.audio(.backgroundVoice, .callFailed, error: SafeErrorSummary(error))
                Task { @MainActor in
                    self.activeCallUUID = nil
                    self.isBackgroundSessionActive = false
                }
            } else {
                PrivacyLog.audio(.backgroundVoice, .callReported)
                Task { @MainActor in
                    self.isBackgroundSessionActive = true
                }
            }
        }
    }

    /// End the background voice session. Call this when the voice session stops.
    func endBackgroundSession() {
        guard let uuid = activeCallUUID else { return }

        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)

        callController?.request(transaction) { error in
            if let error {
                PrivacyLog.audio(.backgroundVoice, .callFailed, detail: PrivacyToken("end"),
                                 error: SafeErrorSummary(error))
            } else {
                PrivacyLog.audio(.backgroundVoice, .callEnded)
            }
        }

        activeCallUUID = nil
        isBackgroundSessionActive = false
    }
}

// MARK: - CXProviderDelegate

extension BackgroundVoiceService: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        PrivacyLog.audio(.backgroundVoice, .providerReset)
        Task { @MainActor in
            self.activeCallUUID = nil
            self.isBackgroundSessionActive = false
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Auto-answer — this is a fake call to keep audio alive
        PrivacyLog.audio(.backgroundVoice, .callAnswered)
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        PrivacyLog.audio(.backgroundVoice, .callEnded, detail: PrivacyToken("provider"))
        action.fulfill()
        Task { @MainActor in
            self.activeCallUUID = nil
            self.isBackgroundSessionActive = false
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        PrivacyLog.audio(.backgroundVoice, .leaseAcquired, detail: PrivacyToken("callKit"))
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        PrivacyLog.audio(.backgroundVoice, .leaseReleased, detail: PrivacyToken("callKit"))
    }
}
