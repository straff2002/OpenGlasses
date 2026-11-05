import XCTest
@testable import OpenGlasses

/// The Walking Navigation footers name only the surfaces a turn really reaches: glasses-free use
/// never reads as a lens promise, and a walk with nothing spoken or shown says so.
final class WalkingTurnSurfacesTests: XCTestCase {

    func testGlassesFreeWithVoiceNamesNoLens() {
        let surfaces = WalkingTurnSurfaces(voiceCues: true, inLens: false)
        XCTAssertFalse(surfaces.isSilent)
        XCTAssertTrue(surfaces.footer.contains("each turn is spoken as you approach it"))
        XCTAssertFalse(surfaces.footer.localizedCaseInsensitiveContains("lens"))
        XCTAssertFalse(surfaces.footer.localizedCaseInsensitiveContains("glasses"))
        XCTAssertFalse(surfaces.footer.localizedCaseInsensitiveContains("HUD"))
        XCTAssertNil(surfaces.recentsFooter)
    }

    func testDisplayWithVoiceNamesBoth() {
        let surfaces = WalkingTurnSurfaces(voiceCues: true, inLens: true)
        XCTAssertFalse(surfaces.isSilent)
        XCTAssertTrue(surfaces.footer.contains("shows in-lens and is spoken"))
        XCTAssertEqual(surfaces.recentsFooter, "Recents also appear in the glasses menu under Navigate.")
    }

    func testDisplayWithoutVoiceSaysTurnsAreNotSpoken() {
        let surfaces = WalkingTurnSurfaces(voiceCues: false, inLens: true)
        XCTAssertFalse(surfaces.isSilent)
        XCTAssertTrue(surfaces.footer.contains("shows in-lens"))
        XCTAssertTrue(surfaces.footer.contains("turns are not spoken"))
        XCTAssertNotNil(surfaces.recentsFooter)
    }

    func testNeitherSurfaceSaysDirectionsWouldBeSilent() {
        let surfaces = WalkingTurnSurfaces(voiceCues: false, inLens: false)
        XCTAssertTrue(surfaces.isSilent)
        XCTAssertTrue(surfaces.footer.contains("directions would be silent"))
        XCTAssertTrue(surfaces.footer.contains("turn Voice Cues on"))
        XCTAssertFalse(surfaces.footer.localizedCaseInsensitiveContains("lens"))
        XCTAssertNil(surfaces.recentsFooter)
    }

    func testEveryFooterKeepsTheScopeAndNetworkNote() {
        for voice in [true, false] {
            for lens in [true, false] {
                let footer = WalkingTurnSurfaces(voiceCues: voice, inLens: lens).footer
                XCTAssertTrue(footer.hasPrefix("Say \u{201C}navigate to \u{2026}\u{201D}"), footer)
                XCTAssertTrue(footer.contains("driving stays with CarPlay"), footer)
                XCTAssertTrue(footer.hasSuffix("Routing needs a network connection."), footer)
            }
        }
    }

    /// The model reads this description for every wearer, most with no display: it must not
    /// promise a lens as the place a turn appears.
    @MainActor
    func testNavigateToolDescriptionDoesNotPromiseALens() {
        let description = NavigateTool().description
        XCTAssertTrue(description.contains("is spoken at the right moment"))
        XCTAssertFalse(description.contains("appears on the glasses display"))
    }
}
