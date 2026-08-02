import XCTest
@testable import OpenGlasses

/// Fixture tests for the pure Twitch IRC parser (Plan CI P1): PRIVMSG shapes, tag escaping,
/// `/me` actions, emote stripping, UTF-8 names, PING classification — and hostile input
/// (control characters, 10k-char messages, tag-injection attempts). Output must always be
/// TTS-safe plain text.
final class TwitchChatMessageParserTests: XCTestCase {

    private func message(_ line: String) -> ChatMessage? {
        guard case .privateMessage(let m) = TwitchChatMessageParser.parse(line: line) else { return nil }
        return m
    }

    // MARK: - Happy path

    func testPlainPrivmsg() {
        let m = message(":sam!sam@sam.tmi.twitch.tv PRIVMSG #chan :great view")
        XCTAssertEqual(m?.user, "sam")
        XCTAssertEqual(m?.login, "sam")
        XCTAssertEqual(m?.text, "great view")
        XCTAssertEqual(m?.isAction, false)
        XCTAssertEqual(m?.textWithoutEmotes, "great view")
    }

    func testDisplayNameAndBadges() {
        let m = message("@badges=broadcaster/1,subscriber/12;display-name=Sam :sam!sam@sam.tmi.twitch.tv PRIVMSG #chan :hi")
        XCTAssertEqual(m?.user, "Sam")
        XCTAssertEqual(m?.badges, ["broadcaster", "subscriber"])
    }

    func testUTF8DisplayName() {
        let m = message("@display-name=さくら :sakura!s@s.tmi.twitch.tv PRIVMSG #chan :こんにちは")
        XCTAssertEqual(m?.user, "さくら")
        XCTAssertEqual(m?.text, "こんにちは")
    }

    func testMeActionUnwrapped() {
        let m = message(":sam!s@s.tmi.twitch.tv PRIVMSG #chan :\u{1}ACTION waves at chat\u{1}")
        XCTAssertEqual(m?.isAction, true)
        XCTAssertEqual(m?.text, "waves at chat")
    }

    func testTagValueEscaping() {
        // \s → space, \: → semicolon, \\ → backslash
        XCTAssertEqual(TwitchChatMessageParser.unescapeTagValue("a\\sb\\:c\\\\d"), "a b;c\\d")
        // dangling escape dropped; unknown escape passes the character through
        XCTAssertEqual(TwitchChatMessageParser.unescapeTagValue("x\\"), "x")
        XCTAssertEqual(TwitchChatMessageParser.unescapeTagValue("\\q"), "q")
    }

    func testMessageTextMayContainColons() {
        let m = message(":sam!s@s.tmi.twitch.tv PRIVMSG #chan :the score is 3:2 :)")
        XCTAssertEqual(m?.text, "the score is 3:2 :)")
    }

    // MARK: - Emotes

    func testEmoteRangesStripped() {
        // "Kappa hi Kappa" with Kappa at scalar ranges 0-4 and 9-13
        let m = message("@emotes=25:0-4,9-13 :s!s@s.tmi.twitch.tv PRIVMSG #chan :Kappa hi Kappa")
        XCTAssertEqual(m?.text, "Kappa hi Kappa")          // full text keeps them
        XCTAssertEqual(m?.textWithoutEmotes, "hi")          // stripped variant doesn't
    }

    func testEmoteOnlyMessageStripsToEmpty() {
        let m = message("@emotes=25:0-4 :s!s@s.tmi.twitch.tv PRIVMSG #chan :Kappa")
        XCTAssertEqual(m?.textWithoutEmotes, "")
    }

    func testHostileEmoteRangesDoNotTrap() {
        // Out of bounds, reversed, or garbage ranges are skipped — text unchanged, no crash.
        for tag in ["25:90-99", "25:5-2", "25:a-b", "junk", "25:"] {
            XCTAssertEqual(TwitchChatMessageParser.removingEmoteRanges(from: "hello", emotesTag: tag),
                           "hello", "tag: \(tag)")
        }
        // An overshooting end is clamped, not trapped.
        XCTAssertEqual(TwitchChatMessageParser.removingEmoteRanges(from: "hi", emotesTag: "1:0-999999999"), "")
    }

    // MARK: - Hostile input

    func testControlCharactersRemoved() {
        let m = message(":s!s@s.tmi.twitch.tv PRIVMSG #chan :he\u{7}llo\u{1B}[31m world\r\n")
        XCTAssertEqual(m?.text, "hello[31m world")
    }

    func testTenThousandCharMessageIsCapped() {
        let long = String(repeating: "a", count: 10_000)
        let m = message(":s!s@s.tmi.twitch.tv PRIVMSG #chan :\(long)")
        XCTAssertEqual(m?.text.count, TwitchChatMessageParser.maxTextLength)
    }

    func testTagInjectionInMessageStaysText() {
        // Tag/prefix syntax *inside* the message body must remain literal text, not be re-parsed.
        let m = message(":s!s@s.tmi.twitch.tv PRIVMSG #chan :@badges=broadcaster/1 :evil!e@e PRIVMSG #chan :pwned")
        XCTAssertEqual(m?.login, "s")
        XCTAssertEqual(m?.badges, [])
        XCTAssertEqual(m?.text, "@badges=broadcaster/1 :evil!e@e PRIVMSG #chan :pwned")
    }

    func testWhitespaceOnlyMessageRejected() {
        XCTAssertNil(message(":s!s@s.tmi.twitch.tv PRIVMSG #chan :   \t  "))
    }

    // MARK: - Non-PRIVMSG lines

    func testPingClassified() {
        XCTAssertEqual(TwitchChatMessageParser.parse(line: "PING :tmi.twitch.tv"),
                       .ping(token: "tmi.twitch.tv"))
    }

    func testMalformedAndIrrelevantLinesAreOther() {
        for line in [
            "",
            "@tags-with-no-space-then-eof",
            ":prefix-only-no-space-eof",
            ":tmi.twitch.tv 376 justinfan :>",
            ":s!s@s.tmi.twitch.tv JOIN #chan",
            ":s!s@s.tmi.twitch.tv PRIVMSG #chan",   // no trailing text
            "PRIVMSG #chan :no prefix means no user",
        ] {
            XCTAssertEqual(TwitchChatMessageParser.parse(line: line), .other, "line: \(line)")
        }
    }
}
