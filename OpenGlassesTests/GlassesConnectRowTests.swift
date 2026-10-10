import XCTest
@testable import OpenGlasses

/// Plan HX P3a — the connect row on Devices & Privacy › Glasses: which one shows, and what its
/// footer says once the wearer has pressed "Allow camera access in Meta AI". Headless: nothing
/// here touches the SDK, and the permission request is a closure.
@MainActor
final class GlassesConnectRowTests: XCTestCase {

    private let everyRegistration: [GlassesRegistration] = [.notRegistered, .registering, .registered]
    private let awayPhases: [GlassesConnectionPhase] = [.noGlassesAdded, .addedDisconnected]

    // MARK: - Which row

    func testAnUnregisteredAppKeepsItsConnectRow() {
        for phase in awayPhases {
            XCTAssertEqual(GlassesConnectRow.resolve(registration: .notRegistered, phase: phase),
                           .connect, "\(phase)")
            XCTAssertEqual(GlassesConnectRow.resolve(registration: .registering, phase: phase),
                           .connect, "\(phase): a registration in flight keeps the row and its spinner")
        }
    }

    func testRegisteredGlassesThatAreNotConnectedGetTheCameraAccessRow() {
        XCTAssertEqual(GlassesConnectRow.resolve(registration: .registered, phase: .addedDisconnected),
                       .allowCameraAccess,
                       "registered with no link used to have nothing to press anywhere")
        XCTAssertEqual(GlassesConnectRow.resolve(registration: .registered, phase: .noGlassesAdded),
                       .allowCameraAccess,
                       "registration is what decides the row, whatever the phase has caught up to")
    }

    func testALinkThatIsUpOrComingUpShowsNoRow() {
        for registration in everyRegistration {
            XCTAssertNil(GlassesConnectRow.resolve(registration: registration, phase: .connected),
                         "\(registration)")
            XCTAssertNil(GlassesConnectRow.resolve(registration: registration, phase: .connecting),
                         "\(registration): a listed device is already past registration and the permission")
        }
    }

    /// The row follows the same snapshot the rest of the app reads: registered with nothing
    /// listed, then a device appears and its link comes up.
    func testTheRowFollowsTheConnectionSnapshot() {
        var snapshot = GlassesConnectionSnapshot(registration: .registered)
        XCTAssertEqual(GlassesConnectRow.resolve(registration: snapshot.registration, phase: snapshot.phase),
                       .allowCameraAccess)

        snapshot.apply(.devices(["a"]))
        XCTAssertEqual(GlassesConnectRow.resolve(registration: snapshot.registration, phase: snapshot.phase),
                       .allowCameraAccess, "listed but out of reach: still not connected")

        snapshot.apply(.deviceState(id: "a", GlassesDeviceState(link: .connecting)))
        XCTAssertNil(GlassesConnectRow.resolve(registration: snapshot.registration, phase: snapshot.phase))

        snapshot.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected)))
        XCTAssertNil(GlassesConnectRow.resolve(registration: snapshot.registration, phase: snapshot.phase))
    }

    // MARK: - The outcome

    func testAGrantedPermissionIsGranted() async {
        var asked = 0
        let outcome = await GlassesCameraAccessOutcome.request(
            ensurePermission: { asked += 1 },
            phoneCameraDenied: { XCTFail("iOS is not consulted when the request succeeds"); return false })
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(asked, 1, "asked once per press")
    }

    func testARefusalInMetaAIIsRefused() async {
        let outcome = await GlassesCameraAccessOutcome.request(
            ensurePermission: { throw CameraError.permissionDenied },
            phoneCameraDenied: { false })
        XCTAssertEqual(outcome, .refused)
    }

    /// `ensurePermission()` throws the same error for iOS's camera permission as for Meta's; the
    /// footer must not blame Meta AI for a switch that is in the iPhone's Settings.
    func testARefusalByIOSIsToldApartFromOneInMetaAI() async {
        let outcome = await GlassesCameraAccessOutcome.request(
            ensurePermission: { throw CameraError.permissionDenied },
            phoneCameraDenied: { true })
        XCTAssertEqual(outcome, .phoneCameraDenied)
    }

    func testAnyOtherFailureKeepsASummaryNotTheErrorsText() async {
        let outcome = await GlassesCameraAccessOutcome.request(
            ensurePermission: { throw CameraError.sdkNotRegistered },
            phoneCameraDenied: { true })
        XCTAssertEqual(outcome, .failed(SafeErrorSummary(CameraError.sdkNotRegistered)),
                       "a denied iPhone camera only explains a permission refusal")

        struct Leaky: LocalizedError {
            var errorDescription: String? { "Maria's glasses at 12 High Street" }
        }
        let leaky = GlassesCameraAccessOutcome(error: Leaky(), phoneCameraDenied: false)
        XCTAssertEqual(leaky, .failed(SafeErrorSummary(Leaky())))
        XCTAssertFalse(leaky.footer.contains("Maria"), "the error's own text is never shown")
        XCTAssertFalse(leaky.footer.contains("High Street"))
    }

    // MARK: - The footer

    func testBeforeAPressTheFooterSaysWhatTheRowIsFor() {
        let footer = GlassesConnectRow.allowCameraAccessFooter(outcome: nil)
        XCTAssertTrue(footer.contains("camera access"))
        XCTAssertTrue(footer.contains("opens Meta AI"), "the hand-off is named before it happens")
    }

    func testEachOutcomeHasItsOwnFooter() {
        let outcomes: [GlassesCameraAccessOutcome] = [
            .granted, .refused, .phoneCameraDenied, .failed(SafeErrorSummary(CameraError.sdkNotRegistered)),
        ]
        let footers = outcomes.map { GlassesConnectRow.allowCameraAccessFooter(outcome: $0) }
        XCTAssertEqual(footers, outcomes.map(\.footer))
        XCTAssertEqual(Set(footers).count, outcomes.count, "no two outcomes read the same")
        XCTAssertFalse(footers.contains(GlassesConnectRow.allowCameraAccessFooter(outcome: nil)),
                       "a press always changes what the footer says")
    }

    func testGrantedSaysWhatElseToCheckBecauseTheRowIsStillShowing() {
        let footer = GlassesCameraAccessOutcome.granted.footer
        XCTAssertTrue(footer.contains("Camera access is allowed"))
        XCTAssertTrue(footer.contains("out of their case"))
        XCTAssertTrue(footer.contains("Developer Mode"))
    }

    func testRefusedAndPhoneDeniedNameWhereTheSwitchIs() {
        XCTAssertTrue(GlassesCameraAccessOutcome.refused.footer.contains("Meta AI"))
        let phone = GlassesCameraAccessOutcome.phoneCameraDenied.footer
        XCTAssertTrue(phone.contains("iPhone's Settings"))
        XCTAssertFalse(phone.contains("wasn't allowed in Meta AI"))
    }

    func testAFailureNamesItsReasonAsOneWordWithNoNumber() {
        let summary = SafeErrorSummary(CameraError.sdkNotRegistered)
        XCTAssertEqual(GlassesCameraAccessOutcome.reason(summary), "sdkNotRegistered")
        let footer = GlassesCameraAccessOutcome.failed(summary).footer
        XCTAssertTrue(footer.contains("(sdkNotRegistered)"), footer)
        XCTAssertNil(footer.rangeOfCharacter(from: .decimalDigits),
                     "an enum ordinal or a state number means nothing to the wearer")

        XCTAssertEqual(GlassesCameraAccessOutcome.reason(SafeErrorSummary(category: .timedOut, code: 3)),
                       "timedOut", "with no case or type name, the category is the reason")
    }

    /// No internal plan letter and no raw state number in anything the row can show.
    func testNothingShownCarriesAPlanLetterOrAStateNumber() {
        let shown = [GlassesConnectRow.allowCameraAccessFooter(outcome: nil),
                     GlassesCameraAccessOutcome.granted.footer,
                     GlassesCameraAccessOutcome.refused.footer,
                     GlassesCameraAccessOutcome.phoneCameraDenied.footer,
                     GlassesCameraAccessOutcome.failed(SafeErrorSummary(category: .unknown)).footer,
                     SessionCardGlassesPill.awayHint]
        for text in shown {
            XCTAssertFalse(text.contains("HX"), text)
            XCTAssertFalse(text.contains("P3"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("state "), text)
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), text)
        }
    }
}
