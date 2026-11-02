import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan KH. The preview shows what Go Live would put on air, and the camera has one session, so
/// these are the two things that have to hold without a camera to hand.
final class LivePreviewPictureTests: XCTestCase {

    private func facts(_ change: (inout LivePreviewPicture.Facts) -> Void = { _ in }) -> LivePreviewPicture.Facts {
        var facts = LivePreviewPicture.Facts(isBroadcasting: false, activeSource: .glasses,
                                             preferredSource: .glasses, glassesConnected: false)
        change(&facts)
        return facts
    }

    // MARK: - Which camera

    func testWithNoGlassesThePreviewIsThePhonesBackCamera() {
        XCTAssertEqual(LivePreviewPicture.decide(facts()), .phone(.back))
    }

    func testWithNoGlassesItIsTheCameraTheSettingNames() {
        XCTAssertEqual(LivePreviewPicture.decide(facts { $0.preferredSource = .phoneFront }), .phone(.front))
        XCTAssertEqual(LivePreviewPicture.decide(facts { $0.preferredSource = .phoneBack }), .phone(.back))
    }

    func testConnectedGlassesKeepThePreviewTheyAlwaysHad() {
        XCTAssertEqual(LivePreviewPicture.decide(facts { $0.glassesConnected = true }), .glasses)
        XCTAssertEqual(LivePreviewPicture.decide(facts {
            $0.glassesConnected = true
            $0.preferredSource = .phoneFront
        }), .glasses)
    }

    func testGlassesConnectingDuringAPhoneStreamLeaveThePictureOnThePhone() {
        XCTAssertEqual(LivePreviewPicture.decide(facts {
            $0.isBroadcasting = true
            $0.activeSource = .phoneBack
            $0.glassesConnected = true
        }), .phone(.back))
    }

    func testThePictureFollowsAMidStreamSwitch() {
        var live = facts {
            $0.isBroadcasting = true
            $0.activeSource = .phoneBack
            $0.glassesConnected = true
        }
        XCTAssertEqual(LivePreviewPicture.decide(live), .phone(.back))
        live.activeSource = .phoneFront
        XCTAssertEqual(LivePreviewPicture.decide(live), .phone(.front))
        live.activeSource = .glasses
        XCTAssertEqual(LivePreviewPicture.decide(live), .glasses)
    }

    /// The setting says one thing and the stream another: the picture is what is on air.
    func testWhileLiveTheSettingDoesNotDecide() {
        XCTAssertEqual(LivePreviewPicture.decide(facts {
            $0.isBroadcasting = true
            $0.activeSource = .phoneFront
            $0.preferredSource = .phoneBack
        }), .phone(.front))
    }

    /// Not a phone picture nobody is watching.
    func testAGlassesStreamThatLosesItsGlassesDoesNotShowThePhone() {
        XCTAssertEqual(LivePreviewPicture.decide(facts {
            $0.isBroadcasting = true
            $0.activeSource = .glasses
        }), .glasses)
    }

    // MARK: - The viewfinder's own state

    func testPermissionComesBeforeTheCamera() {
        for capture in [PhoneCaptureStatus.stopped, .running, .interrupted, .unavailable] {
            XCTAssertEqual(PhoneViewfinderPhase.decide(access: .notDetermined, capture: capture), .askingForAccess)
            XCTAssertEqual(PhoneViewfinderPhase.decide(access: .denied, capture: capture), .denied)
            XCTAssertEqual(PhoneViewfinderPhase.decide(access: .restricted, capture: capture), .denied)
        }
    }

    func testWithAccessThePhaseIsTheCameras() {
        XCTAssertEqual(PhoneViewfinderPhase.decide(access: .authorized, capture: .stopped), .starting)
        XCTAssertEqual(PhoneViewfinderPhase.decide(access: .authorized, capture: .running), .live)
        XCTAssertEqual(PhoneViewfinderPhase.decide(access: .authorized, capture: .interrupted), .paused)
        XCTAssertEqual(PhoneViewfinderPhase.decide(access: .authorized, capture: .unavailable), .unavailable)
    }

    // MARK: - One session

    func testTheFirstClaimStartsTheCamera() {
        var claims = PhoneCaptureClaims()
        XCTAssertEqual(claims.step(from: nil), .none)
        claims.preview = .back
        XCTAssertEqual(claims.step(from: nil), .start(.back))
    }

    /// The point of the type: going live from the viewfinder must not stop or restart the camera.
    func testGoingLiveOnTheCameraInViewChangesNothing() {
        var claims = PhoneCaptureClaims(preview: .back)
        claims.stream = .back
        XCTAssertEqual(claims.step(from: .back), .none)
    }

    func testClosingThePreviewDuringAStreamLeavesTheCameraRunning() {
        var claims = PhoneCaptureClaims(preview: .back, stream: .back)
        claims.preview = nil
        XCTAssertEqual(claims.step(from: .back), .none)
    }

    func testEndingAStreamWithThePreviewOpenLeavesTheCameraRunning() {
        var claims = PhoneCaptureClaims(preview: .back, stream: .back)
        claims.stream = nil
        XCTAssertEqual(claims.step(from: .back), .none)
    }

    func testTheCameraStopsWithItsLastClaim() {
        var claims = PhoneCaptureClaims(preview: .back)
        claims.preview = nil
        XCTAssertEqual(claims.step(from: .back), .stop)

        var streaming = PhoneCaptureClaims(stream: .front)
        streaming.stream = nil
        XCTAssertEqual(streaming.step(from: .front), .stop)
    }

    func testTheStreamsCameraWins() {
        XCTAssertEqual(PhoneCaptureClaims(preview: .back, stream: .front).wanted, .front)
    }

    func testAMidStreamSwitchMovesTheRunningSession() {
        var claims = PhoneCaptureClaims(preview: .back, stream: .back)
        claims.stream = .front
        XCTAssertEqual(claims.step(from: .back), .switchCamera(.front))
    }

    // MARK: - Take Photo

    private func photo(glassesConnected: Bool = false, capturing: Bool = false,
                       picture: LivePreviewPicture = .phone(.back),
                       viewfinder: PhoneViewfinderPhase = .live, isBroadcasting: Bool = false) -> Bool {
        LivePreviewPicture.photoEnabled(glassesConnected: glassesConnected, capturing: capturing,
                                        picture: picture, viewfinder: viewfinder,
                                        isBroadcasting: isBroadcasting)
    }

    func testThePhoneTakesAPhotoFromALiveBackCamera() {
        XCTAssertTrue(photo())
    }

    /// `capturePhoto()`'s phone path is the back camera, so a front picture would be the wrong one.
    func testNoPhotoFromTheFrontCamera() {
        XCTAssertFalse(photo(picture: .phone(.front)))
    }

    /// That path is a session of its own, and it would take the camera off the stream.
    func testNoPhonePhotoDuringAStream() {
        XCTAssertFalse(photo(isBroadcasting: true))
    }

    func testNoPhotoBeforeThereIsAPicture() {
        for phase in [PhoneViewfinderPhase.askingForAccess, .denied, .starting, .paused, .unavailable] {
            XCTAssertFalse(photo(viewfinder: phase), "\(phase)")
        }
    }

    func testOnePhotoAtATime() {
        XCTAssertFalse(photo(capturing: true))
        XCTAssertFalse(photo(glassesConnected: true, capturing: true))
    }

    func testGlassesTakeThePhotoAsTheyAlwaysDid() {
        XCTAssertTrue(photo(glassesConnected: true, picture: .glasses, viewfinder: .denied))
        XCTAssertTrue(photo(glassesConnected: true, picture: .glasses, isBroadcasting: true))
    }

    // MARK: - The caption

    func testTheCaptionNeverPromisesAFallbackTheBlurRefuses() {
        let caption = LivePreviewPicture.phoneCaption(isBroadcasting: false, blurOn: true, preferredSource: .glasses)
        XCTAssertTrue(caption.contains("needs glasses"))
        XCTAssertFalse(caption.contains("streams this picture"))
    }

    func testTheCaptionSaysAPhoneStreamIsNotBlurred() {
        XCTAssertTrue(LivePreviewPicture.phoneCaption(isBroadcasting: true, blurOn: true, preferredSource: .phoneBack)
            .contains("aren't blurred"))
        XCTAssertTrue(LivePreviewPicture.phoneCaption(isBroadcasting: false, blurOn: true, preferredSource: .phoneBack)
            .contains("aren't blurred"))
        XCTAssertFalse(LivePreviewPicture.phoneCaption(isBroadcasting: true, blurOn: false, preferredSource: .phoneBack)
            .contains("blurred"))
    }

    func testNoCaptionSaysThePictureIsMissing() {
        for live in [true, false] {
            for blur in [true, false] {
                for source in BroadcastVideoSource.allCases {
                    let caption = LivePreviewPicture.phoneCaption(isBroadcasting: live, blurOn: blur, preferredSource: source)
                    XCTAssertFalse(caption.contains("doesn't show"), caption)
                }
            }
        }
    }
}
