import XCTest
@testable import OpenGlasses

/// Plan GS — the spoken music copy: richer "what's playing", honest about other apps, no plan letters.
final class MusicPhraserTests: XCTestCase {

    func testWhatsPlayingCarriesAlbumYearAndPosition() {
        let summary = NowPlayingSummary(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
                                        releaseYear: 2020, state: .playing, elapsed: 75, duration: 200,
                                        provider: .appleMusic)
        XCTAssertEqual(MusicPhraser.nowPlaying(summary),
                       "Playing Blinding Lights by The Weeknd, from After Hours (2020) — 1 minute 15 in, of 3 minutes 20.")
    }

    func testPausedTrackSaysPaused() {
        let summary = NowPlayingSummary(title: "Dreams", artist: nil, state: .paused, provider: .appleMusic)
        XCTAssertEqual(MusicPhraser.nowPlaying(summary), "Paused on Dreams.")
    }

    func testNothingPlayingIsHonestAboutOtherApps() {
        XCTAssertEqual(MusicPhraser.nowPlaying(nil), MusicPhraser.nothingPlaying)
        let stopped = NowPlayingSummary(title: "Dreams", state: .stopped, provider: .appleMusic)
        XCTAssertEqual(MusicPhraser.nowPlaying(stopped), MusicPhraser.nothingPlaying)
        XCTAssertTrue(MusicPhraser.nothingPlaying.contains("can't see"))
    }

    func testClockReadsForTheEar() {
        XCTAssertEqual(MusicPhraser.clock(45), "45 seconds")
        XCTAssertEqual(MusicPhraser.clock(60), "1 minute")
        XCTAssertEqual(MusicPhraser.clock(125), "2 minutes 5")
    }

    func testRefusalsNeverNamePlanLettersOrOtherAssistants() {
        let lines = [MusicPhraser.cannotControl("Spotify"), MusicPhraser.speakersNeedHomeAssistant,
                     MusicPhraser.noSpeakers, MusicPhraser.accessDenied, MusicPhraser.accessNeedsPhone,
                     MusicPhraser.needsSubscription(MusicRequestParser.request(from: "rumours"))]
        for line in lines {
            XCTAssertFalse(line.contains("Plan "), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("Meta AI"), line)
        }
        XCTAssertEqual(MusicPhraser.askWhichSpeaker([MusicFixtures.kitchen, MusicFixtures.lounge]),
                       "Which speaker: Kitchen or Lounge Sonos?")
    }
}
