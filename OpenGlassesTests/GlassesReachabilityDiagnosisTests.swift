import XCTest
@testable import OpenGlasses

/// Plan HX P3 — why added glasses are not connected: the diagnosis table, the line it puts on the
/// session card, and what the Developer panel and the support report say. Headless: nothing here
/// touches `Wearables`.
final class GlassesReachabilityDiagnosisTests: XCTestCase {

    private let everyRegistration: [GlassesRegistration] = [.notRegistered, .registering, .registered]
    private let everyPermission: [GlassesCameraPermission] = [
        .notChecked, .granted, .notGranted, .declined, .phoneCameraDenied,
        .failed(SafeErrorSummary(category: .timedOut, detail: PrivacyToken("requestTimeout"))),
    ]

    private func diagnose(_ registration: GlassesRegistration, _ links: [GlassesLinkState] = [],
                          _ permission: GlassesCameraPermission = .notChecked) -> GlassesReachabilityDiagnosis {
        GlassesReachabilityDiagnosis.resolve(registration: registration, links: links, permission: permission)
    }

    // MARK: - The table

    func testNotRegisteredWithNothingListedIsNotAdded() {
        for permission in everyPermission {
            XCTAssertEqual(diagnose(.notRegistered, [], permission), .notAdded, "\(permission)")
        }
    }

    func testARegistrationInFlightIsAwaitingApproval() {
        for permission in everyPermission {
            XCTAssertEqual(diagnose(.registering, [], permission), .awaitingApproval, "\(permission)")
        }
    }

    func testRegisteredWithNothingListedAndNoGrantIsPermissionNeeded() {
        for permission in everyPermission where !permission.isGranted {
            XCTAssertEqual(diagnose(.registered, [], permission), .permissionNeeded, "\(permission)")
        }
    }

    func testRegisteredAndGrantedWithNothingListedIsNoDeviceSeen() {
        XCTAssertEqual(diagnose(.registered, [], .granted), .noDeviceSeen)
    }

    func testAListedDeviceThatIsNotConnectedIsLinkDown() {
        XCTAssertEqual(diagnose(.registered, [.disconnected], .granted), .linkDown)
    }

    func testAListedDeviceThatIsConnectingIsLinkComingUp() {
        XCTAssertEqual(diagnose(.registered, [.connecting], .granted), .linkComingUp)
    }

    func testAListedDeviceWhoseLinkIsUpIsConnected() {
        XCTAssertEqual(diagnose(.registered, [.connected], .granted), .connected)
    }

    /// The permission is the thing to fix first, so "we could not find out" must not read as
    /// "it is granted and the glasses are merely missing".
    func testAFailedPermissionCheckWithNothingListedIsPermissionNeededNotNoDeviceSeen() {
        let failed = GlassesCameraPermission.failed(SafeErrorSummary(category: .unknown,
                                                                     detail: PrivacyToken("noDevice")))
        XCTAssertEqual(diagnose(.registered, [], failed), .permissionNeeded)
        XCTAssertEqual(diagnose(.registered, [], .notChecked), .permissionNeeded,
                       "a check that has not run is not a grant either")
    }

    /// A device is listed only past registration and the permission, so its link decides.
    func testAListedDeviceWinsOverPermissionStatusAndRegistration() {
        let byLink: [(GlassesLinkState, GlassesReachabilityDiagnosis)] = [
            (.disconnected, .linkDown), (.connecting, .linkComingUp), (.connected, .connected),
        ]
        for registration in everyRegistration {
            for permission in everyPermission {
                for (link, expected) in byLink {
                    XCTAssertEqual(diagnose(registration, [link], permission), expected,
                                   "\(registration) / \(permission) / \(link)")
                }
            }
        }
    }

    func testSeveralDevicesFollowTheSnapshotsMultiDeviceRule() {
        XCTAssertEqual(diagnose(.registered, [.disconnected, .connected]), .connected,
                       "connected when any is")
        XCTAssertEqual(diagnose(.registered, [.connecting, .connected, .disconnected]), .connected)
        XCTAssertEqual(diagnose(.registered, [.disconnected, .connecting]), .linkComingUp,
                       "coming up when none is connected and any is connecting")
        XCTAssertEqual(diagnose(.registered, [.disconnected, .disconnected]), .linkDown)
    }

    /// The diagnosis is a finer reading of the phase, folded from the same snapshot. Every
    /// combination is walked so the two can never tell the wearer different things.
    func testTheDiagnosisNeverDisagreesWithThePhase() {
        let linkSets: [[GlassesLinkState]] = [
            [], [.disconnected], [.connecting], [.connected],
            [.disconnected, .connecting], [.disconnected, .connected], [.connecting, .connected],
        ]
        for registration in everyRegistration {
            for links in linkSets {
                var snapshot = GlassesConnectionSnapshot(registration: registration)
                let ids = links.indices.map { "device-\($0)" }
                snapshot.apply(.devices(ids))
                for (id, link) in zip(ids, links) {
                    snapshot.apply(.deviceState(id: id, GlassesDeviceState(link: link)))
                }
                for permission in everyPermission {
                    let reachability = GlassesReachability(snapshot: snapshot, permission: permission)
                    XCTAssertEqual(reachability.links, links)
                    XCTAssertEqual(reachability.diagnosis.phase, snapshot.phase,
                                   "\(registration) / \(links) / \(permission)")
                    XCTAssertEqual(reachability.diagnosis == .connected, snapshot.phase.isConnected)
                }
            }
        }
    }

    // MARK: - The status line

    func testEachDiagnosisHasItsOwnStatusLine() {
        let lines = GlassesReachabilityDiagnosis.allCases.map {
            $0.statusLine(deviceName: "Ray-Ban Meta", appName: "Avenkin")
        }
        XCTAssertEqual(Set(lines).count, GlassesReachabilityDiagnosis.allCases.count,
                       "added-but-not-connected used to be one line for three different things")
    }

    func testTheStatusLineKeepsTodaysWordingWhereTheTableSaysSo() {
        XCTAssertEqual(GlassesReachabilityDiagnosis.notAdded.statusLine(deviceName: nil), "Not connected")
        XCTAssertEqual(GlassesReachabilityDiagnosis.awaitingApproval.statusLine(deviceName: nil, appName: "Avenkin"),
                       RegistrationFlow.status(stateRaw: 2, appName: "Avenkin"))
        XCTAssertEqual(GlassesReachabilityDiagnosis.linkComingUp.statusLine(deviceName: "X"), "Connecting…")
        XCTAssertEqual(GlassesReachabilityDiagnosis.connected.statusLine(deviceName: "X"), "Connected to X")
        XCTAssertEqual(GlassesReachabilityDiagnosis.connected.statusLine(deviceName: nil), "Connected to glasses")
    }

    func testTheStatusLineSaysWhatIsInTheWay() {
        XCTAssertTrue(GlassesReachabilityDiagnosis.permissionNeeded.statusLine(deviceName: nil)
            .contains("camera access in Meta AI"))
        XCTAssertTrue(GlassesReachabilityDiagnosis.noDeviceSeen.statusLine(deviceName: nil).contains("Meta AI"))
        XCTAssertTrue(GlassesReachabilityDiagnosis.linkDown.statusLine(deviceName: nil).contains("out of reach"))
    }

    /// Sized for the session card's headline, and never a number: a device's name is the only
    /// thing that could bring a digit in, and only once connected.
    func testEveryStatusLineFitsTheCardAndCarriesNoStateNumber() {
        for diagnosis in GlassesReachabilityDiagnosis.allCases {
            let line = diagnosis.statusLine(deviceName: nil, appName: "Avenkin")
            XCTAssertLessThanOrEqual(line.count, 80, line)
            XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("state"), line)
        }
    }

    // MARK: - The Connect

    func testAConnectAsksOnlyOnceRegistrationHasLandedAndNothingIsListed() {
        XCTAssertTrue(GlassesReachability(registration: .registered).connectShouldAskForCameraAccess)
        XCTAssertFalse(GlassesReachability(registration: .notRegistered).connectShouldAskForCameraAccess)
        XCTAssertFalse(GlassesReachability(registration: .registering).connectShouldAskForCameraAccess,
                       "an approval still under way has nothing to ask Meta AI about yet")
        XCTAssertFalse(GlassesReachability(registration: .registered, links: [.disconnected])
            .connectShouldAskForCameraAccess, "a listed device is already past the permission")
    }

    func testAConnectStopsWaitingOnlyWhenThePermissionIsKnownToBeMissing() {
        for permission in [GlassesCameraPermission.notGranted, .declined, .phoneCameraDenied] {
            XCTAssertTrue(GlassesReachability(registration: .registered, permission: permission)
                .waitsOnCameraAccess, "\(permission): no device can be listed, so there is no link to wait for")
        }
        let unanswered: [GlassesCameraPermission] = [.notChecked, .failed(SafeErrorSummary(category: .timedOut))]
        for permission in unanswered {
            XCTAssertFalse(GlassesReachability(registration: .registered, permission: permission)
                .waitsOnCameraAccess, "\(permission): the device may yet be listed")
        }
        XCTAssertFalse(GlassesReachability(registration: .registered, permission: .granted).waitsOnCameraAccess)
        XCTAssertFalse(GlassesReachability(registration: .registered, links: [.disconnected],
                                           permission: .declined).waitsOnCameraAccess,
                       "a listed device's link is worth the wait whatever the permission last read")
        XCTAssertFalse(GlassesReachability(registration: .notRegistered, permission: .notGranted)
            .waitsOnCameraAccess, "an approval that is late may still land")
    }

    // MARK: - The support report's line

    func testTheReportLineCarriesTheDiagnosisAndTheFactsBehindIt() {
        XCTAssertEqual(
            GlassesReachability(registration: .registered, permission: .notGranted).reportLine,
            "Glasses link: permissionNeeded — registration registered, devices listed 0, "
                + "camera permission notGranted")
        XCTAssertEqual(
            GlassesReachability(registration: .registered, links: [.disconnected, .connecting],
                                permission: .granted).reportLine,
            "Glasses link: linkComingUp — registration registered, devices listed 2 "
                + "(disconnected, connecting), camera permission granted")
        XCTAssertEqual(
            GlassesReachability().reportLine,
            "Glasses link: notAdded — registration notRegistered, devices listed 0, "
                + "camera permission notChecked")
    }

    func testAFailedPermissionIsReportedAsItsReasonWithNoNumber() {
        let failed = GlassesCameraPermission.failed(
            SafeErrorSummary(category: .unknown, detail: PrivacyToken("noDevice"), code: 7))
        XCTAssertEqual(failed.reportToken, "failed(noDevice)")
        let line = GlassesReachability(registration: .registered, permission: failed).reportLine
        XCTAssertTrue(line.hasSuffix("camera permission failed(noDevice)"), line)
        XCTAssertFalse(line.contains("7"), "an enum ordinal says nothing to the reader")

        XCTAssertEqual(GlassesCameraPermission.failed(SafeErrorSummary(category: .timedOut)).reportToken,
                       "failed(timedOut)", "with no case or type name, the category is the reason")
    }

    /// The line is built from a snapshot that holds device identifiers and names, and must carry
    /// neither: an identifier names one pair of glasses, and a name is whatever its owner typed.
    func testTheReportLineNeverCarriesADeviceNameOrIdentifier() {
        let identifiers = ["4C:87:5D-serial-0193", "glasses-b7e2"]
        var snapshot = GlassesConnectionSnapshot(registration: .registered)
        snapshot.apply(.devices(identifiers))
        snapshot.apply(.deviceName(id: identifiers[0], "Maria's Ray-Ban Meta"))
        snapshot.apply(.deviceName(id: identifiers[1], "Workshop Oakleys"))
        snapshot.apply(.deviceState(id: identifiers[0], GlassesDeviceState(link: .disconnected, batteryLevel: 81)))
        snapshot.apply(.deviceState(id: identifiers[1], GlassesDeviceState(link: .disconnected)))

        let reachability = GlassesReachability(snapshot: snapshot, permission: .granted)
        let line = reachability.reportLine
        XCTAssertEqual(line, "Glasses link: linkDown — registration registered, devices listed 2 "
            + "(disconnected, disconnected), camera permission granted")
        for secret in identifiers + ["Maria", "Ray-Ban", "Workshop", "Oakley", "serial", "81"] {
            XCTAssertFalse(line.contains(secret), "\(secret) reached the report line")
            XCTAssertFalse(reachability.probeDetail.contains(secret), "\(secret) reached the Developer panel")
        }
    }

    // MARK: - The Developer panel's check

    func testEachDiagnosisHasItsOwnProbeDetailAndNoneSaysPair() {
        let samples: [GlassesReachability] = [
            GlassesReachability(),
            GlassesReachability(registration: .registering),
            GlassesReachability(registration: .registered, permission: .declined),
            GlassesReachability(registration: .registered, permission: .granted),
            GlassesReachability(registration: .registered, links: [.disconnected], permission: .granted),
            GlassesReachability(registration: .registered, links: [.connecting], permission: .granted),
            GlassesReachability(registration: .registered, links: [.connected], permission: .granted),
        ]
        XCTAssertEqual(Set(samples.map(\.diagnosis)).count, GlassesReachabilityDiagnosis.allCases.count)
        let details = samples.map(\.probeDetail)
        XCTAssertEqual(Set(details).count, samples.count)
        for detail in details {
            XCTAssertFalse(detail.contains("pair via"),
                           "\"pair via the Meta AI app\" was the answer to someone who had paired")
            XCTAssertFalse(detail.localizedCaseInsensitiveContains("state "), detail)
        }
        XCTAssertTrue(samples[2].probeDetail.contains("declined"), "the permission's status is named")
        XCTAssertTrue(samples[4].probeDetail.hasPrefix("1 listed"), "a count, not a device")
    }
}
