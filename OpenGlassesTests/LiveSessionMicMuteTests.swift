import XCTest
@testable import OpenGlasses

/// Plan GJ P3: the wearer's mid-session mute as part of the captured-buffer gate both live session
/// managers share. Muted means nothing is forwarded, whatever the duplex tier says.
final class LiveSessionMicMuteTests: XCTestCase {

    private let tiers: [DuplexAudioCapability] = [.echoCancelled, .halfDuplex]

    func testMutedForwardsNothingInAnyTier() {
        for capability in tiers {
            for iPhoneMode in [true, false] {
                for modelSpeaking in [true, false] {
                    XCTAssertFalse(EchoSuppressionPolicy.shouldForwardCapturedBuffer(
                        wearerMuted: true, capability: capability, iPhoneMode: iPhoneMode,
                        modelSpeaking: modelSpeaking))
                }
            }
        }
    }

    func testUnmutedMatchesTheEchoSuppressionTable() {
        for capability in tiers {
            for iPhoneMode in [true, false] {
                for modelSpeaking in [true, false] {
                    XCTAssertEqual(
                        EchoSuppressionPolicy.shouldForwardCapturedBuffer(
                            wearerMuted: false, capability: capability, iPhoneMode: iPhoneMode,
                            modelSpeaking: modelSpeaking),
                        !EchoSuppressionPolicy.shouldDropCapturedBuffer(
                            capability: capability, iPhoneMode: iPhoneMode, modelSpeaking: modelSpeaking))
                }
            }
        }
    }
}
