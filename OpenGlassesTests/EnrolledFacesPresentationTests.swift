import XCTest
@testable import OpenGlasses

/// Plan HP P2 item 8 — what the Enrolled Faces screen says, headless.
@MainActor
final class EnrolledFacesPresentationTests: XCTestCase {

    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func face(_ name: String, seenSecondsAgo: TimeInterval) -> FaceRecognitionService.KnownFace {
        var face = FaceRecognitionService.KnownFace(name: name, faceprint: [0.1, 0.2])
        face.lastSeen = now.addingTimeInterval(-seenSecondsAgo)
        return face
    }

    func testRowsAreAlphabeticalAndSayWhenEachPersonWasLastSeen() {
        let rows = EnrolledFacesPresentation.rows(
            for: [face("zoë", seenSecondsAgo: 2 * 86_400), face("Ángel", seenSecondsAgo: 3_600),
                  face("maria", seenSecondsAgo: 60)],
            now: now, locale: locale)
        XCTAssertEqual(rows.map(\.name), ["Ángel", "maria", "zoë"],
                       "sorted the way a reader expects, ignoring case and accents")
        XCTAssertEqual(rows[0].lastSeen, "Last seen 1 hour ago")
        XCTAssertEqual(rows[1].lastSeen, "Last seen 1 minute ago")
        XCTAssertEqual(rows[2].lastSeen, "Last seen 2 days ago")
        XCTAssertEqual(rows[1].accessibilityLabel, "maria, Last seen 1 minute ago")
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    func testUnderAMinuteAndAFutureTimestampReadAsJustNow() {
        for offset: TimeInterval in [120, 0, -30, -59] {
            XCTAssertEqual(EnrolledFacesPresentation.lastSeenText(now.addingTimeInterval(offset), now: now, locale: locale),
                           "Last seen just now", "\(offset)")
        }
    }

    func testNoFacesIsAnEmptyList() {
        XCTAssertTrue(EnrolledFacesPresentation.rows(for: [], now: now, locale: locale).isEmpty)
        XCTAssertTrue(EnrolledFacesPresentation.emptyList.contains("approve"),
                      "the empty state says enrolment is asked about first")
    }

    /// The opt-in copy is the brief's three sentences, word for word.
    func testTheOptInCopySaysThePersonIsNotTold() {
        XCTAssertEqual(EnrolledFacesPresentation.optInFooter,
                       "Names people you've enrolled when they're in front of your glasses. The person isn't told. You're responsible for using this lawfully where you are.")
    }

    func testForgetEveryoneSaysHowMany() {
        XCTAssertEqual(EnrolledFacesPresentation.forgetEveryoneQuestion(count: 1),
                       "Forget the one person enrolled? Their face print is deleted from this phone.")
        XCTAssertEqual(EnrolledFacesPresentation.forgetEveryoneQuestion(count: 3),
                       "Forget all 3 people enrolled? Their face prints are deleted from this phone.")
    }

    func testTheGlassesRowStatus() {
        XCTAssertEqual(EnrolledFacesPresentation.linkStatus(enabled: false, enrolled: 4), "Off")
        XCTAssertEqual(EnrolledFacesPresentation.linkStatus(enabled: true, enrolled: 1), "On, 1 person")
        XCTAssertEqual(EnrolledFacesPresentation.linkStatus(enabled: true, enrolled: 0), "On, 0 people")
    }

    /// The near-tie message used to send the wearer to "Settings", where nothing listed faces.
    /// It now names the screen, and the screen's path names screens that exist.
    func testTheNearTieMessageNamesTheScreen() {
        let path = EnrolledFacesPresentation.screenPath
        XCTAssertTrue(path.hasSuffix("Enrolled Faces"), path)
        XCTAssertTrue(path.contains(SettingsCatalog.category(.devices).title), path)
        XCTAssertTrue(path.contains("Glasses"), path)
        for copy in [path, EnrolledFacesPresentation.optInFooter, EnrolledFacesPresentation.emptyList] {
            XCTAssertFalse(copy.contains("Plan"), copy)
        }
    }

    /// Forgetting through the store the screen calls: one person, then everyone.
    func testForgettingFromTheScreenRemovesTheFacePrints() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrolled-faces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let service = FaceRecognitionService(directory: workspace)
        service.knownFaces = [face("Maria", seenSecondsAgo: 10), face("Sam", seenSecondsAgo: 20),
                              face("Jo", seenSecondsAgo: 30)]

        _ = service.forgetFace(name: "maria")
        XCTAssertEqual(EnrolledFacesPresentation.rows(for: service.knownFaces, now: now, locale: locale)
            .map(\.name), ["Jo", "Sam"])
        XCTAssertEqual(service.forgetAllFaces(), 2)
        XCTAssertTrue(service.knownFaces.isEmpty)
        XCTAssertTrue(FaceRecognitionService(directory: workspace).knownFaces.isEmpty,
                      "forgotten on disk, not only in memory")
    }
}
