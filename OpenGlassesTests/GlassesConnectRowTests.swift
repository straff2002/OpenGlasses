import XCTest
@testable import OpenGlasses

/// Plan HX P3 — the row at the top of Devices & Privacy › Glasses: what there is to press for each
/// reachability diagnosis, and the line under it. P3a chose the row from registration and the
/// phase and kept the press's outcome in the view; both now come from the published reachability.
/// Headless: nothing here touches the SDK.
final class GlassesConnectRowTests: XCTestCase {

    private let failed = GlassesCameraPermission.failed(SafeErrorSummary(CameraError.sdkNotRegistered))

    private func row(_ registration: GlassesRegistration, _ links: [GlassesLinkState] = [],
                     _ permission: GlassesCameraPermission = .notChecked) -> GlassesConnectRow? {
        GlassesConnectRow(GlassesReachability(registration: registration, links: links, permission: permission))
    }

    // MARK: - Which row

    func testAnUnregisteredAppKeepsItsConnectRow() {
        XCTAssertEqual(row(.notRegistered)?.action, .connect)
        XCTAssertEqual(row(.registering)?.action, .connect,
                       "a registration in flight keeps the row and its spinner")
        XCTAssertNil(row(.notRegistered)?.title, "a button carries its own label")
        XCTAssertEqual(row(.notRegistered)?.footer,
                       "Avenkin isn't connected to your glasses in the Meta AI app. "
                           + RegistrationFlow.beforeHandoffMessage(),
                       "the gate is still named before the hand-off")
    }

    func testRegisteredWithNothingListedAndNoGrantGetsTheCameraAccessButton() {
        for permission in [GlassesCameraPermission.notChecked, .notGranted, .declined, .phoneCameraDenied, failed] {
            XCTAssertEqual(row(.registered, [], permission)?.action, .allowCameraAccess, "\(permission)")
        }
    }

    /// P3a showed the button to every registered pair without a link, and for one asleep in its
    /// case the press could only answer "already allowed". The diagnosis tells them apart.
    func testAPairThatIsListedAndOutOfReachIsToldSoAndHasNothingToPress() throws {
        let row = try XCTUnwrap(row(.registered, [.disconnected], .granted))
        XCTAssertNil(row.action, "the app cannot bring a link up; asking for a permission it has is noise")
        XCTAssertEqual(row.title, "Glasses out of reach")
        XCTAssertTrue(row.footer.contains("switched on"))
        XCTAssertTrue(row.footer.contains("out of their case"))
        XCTAssertTrue(row.footer.contains("nearby"))
    }

    func testAGrantedPairMetaAIListsNoDeviceForIsToldWhatElseToCheck() throws {
        let row = try XCTUnwrap(row(.registered, [], .granted))
        XCTAssertNil(row.action)
        XCTAssertEqual(row.title, "Meta AI isn't showing your glasses yet")
        XCTAssertTrue(row.footer.contains("Camera access is allowed"))
        XCTAssertTrue(row.footer.contains("connected in the Meta AI app"))
        XCTAssertTrue(row.footer.contains("Developer Mode"),
                      "one glasses app at a time: the likeliest cause for someone who has just paired")
    }

    func testALinkThatIsUpOrComingUpShowsNoRow() {
        for registration in [GlassesRegistration.notRegistered, .registering, .registered] {
            XCTAssertNil(row(registration, [.connected], .granted), "\(registration)")
            XCTAssertNil(row(registration, [.connecting], .granted), "\(registration)")
        }
    }

    /// The row follows the same snapshot the rest of the app reads: registered with nothing
    /// listed, the permission granted, then a device appears and its link comes up.
    func testTheRowFollowsTheConnectionSnapshot() {
        var snapshot = GlassesConnectionSnapshot(registration: .registered)
        func current(_ permission: GlassesCameraPermission) -> GlassesConnectRow? {
            GlassesConnectRow(GlassesReachability(snapshot: snapshot, permission: permission))
        }
        XCTAssertEqual(current(.notGranted)?.action, .allowCameraAccess)
        XCTAssertNil(current(.granted)?.action, "allowed, and waiting for Meta AI to list the glasses")
        XCTAssertNotNil(current(.granted))

        snapshot.apply(.devices(["a"]))
        XCTAssertEqual(current(.granted)?.title, "Glasses out of reach", "listed but out of reach")

        snapshot.apply(.deviceState(id: "a", GlassesDeviceState(link: .connecting)))
        XCTAssertNil(current(.granted))

        snapshot.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected)))
        XCTAssertNil(current(.granted))
    }

    // MARK: - The camera access footer

    func testBeforeItHasBeenAskedForTheFooterSaysWhatTheRowIsFor() {
        let footer = GlassesConnectRow.allowCameraAccessFooter(.notChecked)
        XCTAssertTrue(footer.contains("camera access"))
        XCTAssertTrue(footer.contains("opens Meta AI"), "the hand-off is named before it happens")
        XCTAssertEqual(GlassesConnectRow.allowCameraAccessFooter(.notGranted), footer,
                       "a launch check that found it missing reads the same as not having looked: "
                           + "either way the row is the thing to press")
    }

    func testEachWayAskingEndedHasItsOwnFooter() {
        let statuses: [GlassesCameraPermission] = [.notGranted, .declined, .phoneCameraDenied, failed]
        let footers = statuses.map { GlassesConnectRow.allowCameraAccessFooter($0) }
        XCTAssertEqual(Set(footers).count, statuses.count, "no two read the same")
        XCTAssertEqual(statuses.map { row(.registered, [], $0)?.footer }, footers,
                       "the row's line is the published status's footer")
    }

    func testDeclinedAndPhoneDeniedNameWhereTheSwitchIs() {
        XCTAssertTrue(GlassesConnectRow.allowCameraAccessFooter(.declined).contains("Meta AI"))
        let phone = GlassesConnectRow.allowCameraAccessFooter(.phoneCameraDenied)
        XCTAssertTrue(phone.contains("iPhone's Settings"))
        XCTAssertFalse(phone.contains("wasn't allowed in Meta AI"),
                       "the footer must not blame Meta AI for a switch that is in the iPhone's Settings")
    }

    func testAFailureNamesItsReasonAsOneWordWithNoNumber() {
        let summary = SafeErrorSummary(CameraError.sdkNotRegistered)
        XCTAssertEqual(GlassesCameraPermission.reason(summary), "sdkNotRegistered")
        let footer = GlassesConnectRow.allowCameraAccessFooter(.failed(summary))
        XCTAssertTrue(footer.contains("(sdkNotRegistered)"), footer)
        XCTAssertNil(footer.rangeOfCharacter(from: .decimalDigits),
                     "an enum ordinal or a state number means nothing to the wearer")

        XCTAssertEqual(GlassesCameraPermission.reason(SafeErrorSummary(category: .timedOut, code: 3)),
                       "timedOut", "with no case or type name, the category is the reason")
    }

    func testAFailuresOwnTextIsNeverShown() {
        struct Leaky: LocalizedError {
            var errorDescription: String? { "Maria's glasses at 12 High Street" }
        }
        let footer = GlassesConnectRow.allowCameraAccessFooter(.failed(SafeErrorSummary(Leaky())))
        XCTAssertFalse(footer.contains("Maria"))
        XCTAssertFalse(footer.contains("High Street"))
    }

    // MARK: - What VoiceOver is told after a press

    func testAfterAPressVoiceOverHearsWhereThingsStand() {
        let declined = GlassesReachability(registration: .registered, permission: .declined)
        XCTAssertEqual(GlassesConnectRow.announcement(after: declined),
                       GlassesConnectRow.allowCameraAccessFooter(.declined))

        let granted = GlassesReachability(registration: .registered, permission: .granted)
        let said = GlassesConnectRow.announcement(after: granted)
        XCTAssertTrue(said.hasPrefix("Meta AI isn't showing your glasses yet. "),
                      "the button has gone, so the row that replaced it is named first")
        XCTAssertTrue(said.contains("Camera access is allowed"))

        let connected = GlassesReachability(registration: .registered, links: [.connected], permission: .granted)
        XCTAssertEqual(GlassesConnectRow.announcement(after: connected), "Connected to glasses",
                       "the row has gone because the glasses connected, and that is the news")
    }

    // MARK: - Nothing internal on screen

    /// No internal plan letter and no raw state number in anything the row, the pill's hint or
    /// VoiceOver can say.
    func testNothingShownCarriesAPlanLetterOrAStateNumber() {
        let everyReachability: [GlassesReachability] = [
            GlassesReachability(),
            GlassesReachability(registration: .registering),
            GlassesReachability(registration: .registered),
            GlassesReachability(registration: .registered, permission: .notGranted),
            GlassesReachability(registration: .registered, permission: .declined),
            GlassesReachability(registration: .registered, permission: .phoneCameraDenied),
            GlassesReachability(registration: .registered, permission: .failed(SafeErrorSummary(category: .unknown))),
            GlassesReachability(registration: .registered, permission: .granted),
            GlassesReachability(registration: .registered, links: [.disconnected], permission: .granted),
            GlassesReachability(registration: .registered, links: [.connecting], permission: .granted),
            GlassesReachability(registration: .registered, links: [.connected], permission: .granted),
        ]
        var shown: [String] = GlassesReachabilityDiagnosis.allCases.map { SessionCardGlassesPill.awayHint(for: $0) }
        for reachability in everyReachability {
            shown.append(GlassesConnectRow.announcement(after: reachability))
            if let row = GlassesConnectRow(reachability) {
                shown.append(row.footer)
                if let title = row.title { shown.append(title) }
            }
        }
        for text in shown {
            XCTAssertFalse(text.contains("HX"), text)
            XCTAssertFalse(text.contains("P3"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("state "), text)
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), text)
        }
    }
}
