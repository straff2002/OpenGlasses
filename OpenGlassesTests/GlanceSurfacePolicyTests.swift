import XCTest
@testable import OpenGlasses

/// Plan GM P0 — when a surface goes to the wrist: the three setting values, asked vs automatic,
/// Medical Compliance, Local Only (no map), and a phone whose watch has no app.
final class GlanceSurfacePolicyTests: XCTestCase {

    private let point = GlancePoint(latitude: -36.85, longitude: 174.76)
    private lazy var place: GlanceSurface.Kind = .place(PlaceCard(
        name: "Sky Tower", subtitle: nil, coordinate: point, wearer: nil, straightLineMeters: 0,
        bearingDegrees: 0, routeMeters: nil, etas: []))
    private lazy var route: GlanceSurface.Kind = .route(RouteSnapshot(
        polyline: GlancePolyline(points: [point]), destinationName: "Home", destination: point, mode: .walking,
        activeStepIndex: 0, next: nil, then: nil, remainingMeters: 100, arrivalAt: nil, wearer: nil))
    private func list(_ count: Int) -> GlanceSurface.Kind {
        .list(ListCard(title: nil, items: (0..<count).map { .init(id: "\($0)", text: "item", checked: false) },
                       origin: "answer"))
    }
    private let image: GlanceSurface.Kind = .image(ImageCard(caption: "c", source: "s", fileName: "f.jpg"))

    private func inputs(_ setting: WatchMapCardsSetting = .automatic, asked: Bool = false,
                        installed: Bool = true, medical: MedicalEgressGuard.Mode = .off,
                        longLists: Bool = false) -> GlanceSurfacePolicy.Inputs {
        .init(setting: setting, asked: asked, watchAppInstalled: installed, medical: medical,
              sendsLongLists: longLists)
    }

    // MARK: - The setting

    func testAutomaticSendsSilentlyAndAnAskTaps() {
        XCTAssertEqual(GlanceSurfacePolicy.decide(place, inputs()), .send(mapAllowed: true, playsTap: false))
        XCTAssertEqual(GlanceSurfacePolicy.decide(place, inputs(asked: true)), .send(mapAllowed: true, playsTap: true))
    }

    func testOnlyWhenAskedWaitsForTheAsk() {
        XCTAssertEqual(GlanceSurfacePolicy.decide(place, inputs(.onlyWhenAsked)), .skip(.notAsked))
        XCTAssertEqual(GlanceSurfacePolicy.decide(place, inputs(.onlyWhenAsked, asked: true)),
                       .send(mapAllowed: true, playsTap: true))
    }

    func testNeverSendsNothingEvenWhenAsked() {
        for kind in [place, route] {
            XCTAssertEqual(GlanceSurfacePolicy.decide(kind, inputs(.never)), .skip(.settingNever))
            XCTAssertEqual(GlanceSurfacePolicy.decide(kind, inputs(.never, asked: true)), .skip(.settingNever))
        }
    }

    func testEverySpatialCardFollowsTheSetting() {
        let wearer = WearerFix(coordinate: point, fixAt: Date(), horizontalAccuracy: 5)
        let kinds: [GlanceSurface.Kind] = [
            place,
            .whereAmI(WhereCard(wearer: wearer, street: nil, locality: nil)),
            .places(PlacesCard(query: "q", rows: [], wearer: nil)),
        ]
        for kind in kinds {
            XCTAssertTrue(GlanceSurfacePolicy.decide(kind, inputs()).isSend, kind.tag)
            XCTAssertFalse(GlanceSurfacePolicy.decide(kind, inputs(.onlyWhenAsked)).isSend, kind.tag)
        }
    }

    func testTheRouteFollowsGuidanceWithoutBeingAskedAgain() {
        XCTAssertEqual(GlanceSurfacePolicy.decide(route, inputs(.onlyWhenAsked)), .send(mapAllowed: true, playsTap: false))
    }

    func testNoWatchAppNoSurface() {
        for kind in [place, route, list(10), image] {
            XCTAssertEqual(GlanceSurfacePolicy.decide(kind, inputs(asked: true, installed: false)),
                           .skip(.watchAppNotInstalled))
        }
    }

    // MARK: - Medical

    func testMedicalComplianceAllowsMapsButNotListsOrImages() {
        let compliance = MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false)
        XCTAssertEqual(GlanceSurfacePolicy.decide(place, inputs(medical: compliance)), .send(mapAllowed: true, playsTap: false))
        XCTAssertEqual(GlanceSurfacePolicy.decide(route, inputs(medical: compliance)), .send(mapAllowed: true, playsTap: false))
        XCTAssertEqual(GlanceSurfacePolicy.decide(list(3), inputs(asked: true, medical: compliance)), .skip(.medicalCompliance))
        XCTAssertEqual(GlanceSurfacePolicy.decide(image, inputs(asked: true, medical: compliance)), .skip(.medicalCompliance))
    }

    func testLocalOnlySendsTheCardWithoutAMap() {
        XCTAssertEqual(GlanceSurfacePolicy.decide(place, inputs(medical: .localOnly)), .send(mapAllowed: false, playsTap: false))
        XCTAssertEqual(GlanceSurfacePolicy.decide(route, inputs(medical: .localOnly)), .send(mapAllowed: false, playsTap: false))
        XCTAssertFalse(GlanceSurfacePolicy.mapAllowed(.localOnly))
        XCTAssertTrue(GlanceSurfacePolicy.mapAllowed(.off))
        // Local Only only binds with Medical Compliance itself on.
        XCTAssertTrue(GlanceSurfacePolicy.mapAllowed(.init(hipaaMode: false, localOnly: true)))
    }

    // MARK: - Lists and images

    func testListsGoWhenAskedOrLongWithTheSwitchOn() {
        XCTAssertEqual(GlanceSurfacePolicy.decide(list(2), inputs(asked: true)), .send(mapAllowed: true, playsTap: true))
        XCTAssertEqual(GlanceSurfacePolicy.decide(list(5), inputs()), .skip(.notAsked))
        XCTAssertEqual(GlanceSurfacePolicy.decide(list(5), inputs(longLists: true)), .send(mapAllowed: true, playsTap: false))
        XCTAssertEqual(GlanceSurfacePolicy.decide(list(4), inputs(longLists: true)), .skip(.notAsked))
    }

    func testImagesOnlyWhenAsked() {
        XCTAssertEqual(GlanceSurfacePolicy.decide(image, inputs()), .skip(.notAsked))
        XCTAssertEqual(GlanceSurfacePolicy.decide(image, inputs(asked: true)), .send(mapAllowed: true, playsTap: true))
    }

    // MARK: - Expiry

    func testLifetimes() {
        let wearer = WearerFix(coordinate: point, fixAt: Date(), horizontalAccuracy: 5)
        XCTAssertEqual(GlanceSurfacePolicy.lifetime(of: place), 15 * 60)
        XCTAssertEqual(GlanceSurfacePolicy.lifetime(of: .places(PlacesCard(query: "q", rows: [], wearer: nil))), 15 * 60)
        XCTAssertEqual(GlanceSurfacePolicy.lifetime(of: .whereAmI(WhereCard(wearer: wearer, street: nil, locality: nil))), 5 * 60)
        XCTAssertNil(GlanceSurfacePolicy.lifetime(of: route), "until guidance ends")
    }
}
