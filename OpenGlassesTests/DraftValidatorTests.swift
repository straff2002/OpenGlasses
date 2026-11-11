import XCTest
@testable import OpenGlasses

/// Plan KT §4.4 — every row of the validator's table, failing and passing.
final class DraftValidatorTests: XCTestCase {

    private func context(_ channel: DraftChannel = .messages, language: String = "en",
                         trusted: [String] = ["Ana Example", "18:45"], actionItems: [String] = [],
                         source: String? = nil) -> DraftValidationContext {
        DraftValidationContext(channel: channel, language: language, trustedText: trusted,
                               actionItems: actionItems, untrustedSource: source)
    }

    private func check(_ text: String, _ context: DraftValidationContext? = nil) -> DraftValidationFailure? {
        DraftValidator.validate(text, context: context ?? self.context())
    }

    func testAPlainDraftPasses() {
        XCTAssertNil(check("On my way — there about 18:45."))
    }

    // Row: length within the channel's budget.

    func testLengthBudgetsPerChannel() {
        XCTAssertEqual(DraftValidator.budget(for: .messages), 320)
        XCTAssertEqual(DraftValidator.budget(for: .whatsapp), 500)
        XCTAssertEqual(DraftValidator.budget(for: .email), 1200)
        let table: [(DraftChannel, Int, Bool)] = [
            (.messages, 320, true), (.messages, 321, false),
            (.whatsapp, 500, true), (.whatsapp, 501, false),
            (.email, 1200, true), (.email, 1201, false),
        ]
        for (channel, length, passes) in table {
            let text = String(repeating: "a", count: length)
            XCTAssertEqual(check(text, context(channel)) == nil, passes, "\(channel) \(length)")
            if !passes { XCTAssertEqual(check(text, context(channel)), .tooLong) }
        }
    }

    // Row: no URL, email address or phone number unless in the trusted facts.

    func testLinksAddressesAndNumbersOnlyFromTheFacts() {
        XCTAssertEqual(check("See https://example.com/x before you go."), .url)
        XCTAssertEqual(check("Details at www.example.org."), .url)
        XCTAssertEqual(check("Details at example.net tonight."), .url)
        XCTAssertNil(check("Details at example.net.", context(trusted: ["example.net"])))

        XCTAssertEqual(check("Write to someone@example.com."), .emailAddress)
        XCTAssertNil(check("Write to ana@example.com.", context(trusted: ["ana@example.com"])))

        XCTAssertEqual(check("Call me on 555-0123 4567."), .phoneNumber)
        XCTAssertEqual(check("Call me on +1 555 012 3456."), .phoneNumber)
        XCTAssertNil(check("Call me on 555 0199 77.", context(trusted: ["555-0199-77"])))
    }

    // Row: no money amount unless in the trusted facts.

    func testMoneyOnlyFromTheFacts() {
        XCTAssertEqual(check("It will cost $120."), .moneyAmount)
        XCTAssertEqual(check("It will cost 120 €."), .moneyAmount)
        XCTAssertEqual(check("It will cost 85 dollars."), .moneyAmount)
        XCTAssertNil(check("It will cost $120.", context(trusted: ["$120"])))
    }

    // Row: no time or date not in the facts.

    func testTimesAndDatesOnlyFromTheFacts() {
        XCTAssertEqual(check("On my way — there about 19:30."), .timeOrDateNotInFacts)
        XCTAssertEqual(check("See you at 7pm."), .timeOrDateNotInFacts)
        XCTAssertEqual(check("Could we do 12/11 instead?"), .timeOrDateNotInFacts)
        XCTAssertEqual(check("Could we do Tuesday instead?"), .timeOrDateNotInFacts)
        XCTAssertEqual(check("Could we do 14 November instead?"), .timeOrDateNotInFacts)
        XCTAssertNil(check("On my way — there about 18.45.", context(trusted: ["18:45"])))
        XCTAssertNil(check("Could we do Tuesday instead?", context(trusted: ["Tuesday"])))
        // A count of minutes is not a time.
        XCTAssertNil(check("Running about 15 minutes late, sorry — there about 18:45."))
    }

    // Row: same language as the template's target.

    func testADraftInAnotherLanguageFails() {
        let french = "Je suis en route et j'arrive dans quelques minutes, merci de patienter un peu."
        XCTAssertEqual(check(french, context(language: "en")), .wrongLanguage)
        XCTAssertNil(check(french, context(language: "fr")))
        XCTAssertNil(check(french, context(language: "fr-CA")))
        // Too short to judge: never refused on a guess.
        XCTAssertNil(check("Merci beaucoup!", context(language: "en")))
    }

    // Row: not empty, no Markdown, no placeholder left.

    func testEmptyMarkdownAndPlaceholders() {
        XCTAssertEqual(check("   \n "), .empty)
        XCTAssertEqual(check("On my way — there about {arrival}."), .placeholderLeft)
        XCTAssertEqual(check("**On my way**"), .markdown)
        XCTAssertEqual(check("# Recap\nThanks"), .markdown)
        XCTAssertEqual(check("Thanks:\n- the room"), .markdown)
        XCTAssertEqual(check("See [this](here)."), .markdown)
        XCTAssertEqual(check("Use `code` here."), .markdown)
        // The templates' bullet is not Markdown.
        XCTAssertNil(check("Thanks:\n• the room\n• the plan"))
    }

    // Row: a meeting follow-up copies nothing beyond the action items in more than 12 words.

    func testAMeetingRecapMayQuoteTheItemsButNothingElseAtLength() {
        let item = "Ana will send the revised plan to everybody on the list before the end of the week"
        let other = "and then we talked for a while about the parking problem behind the old building on the corner"
        let transcript = "\(item). \(other)."
        let ctx = context(.email, trusted: [item], actionItems: [item], source: transcript)

        XCTAssertNil(check("Hi all,\n\nThanks for today. Here's what we agreed:\n• \(item)\n\nSam", ctx))
        XCTAssertEqual(check("Hi all,\n\nThanks for today. Also, \(other).\n\nSam", ctx), .copiedCaptionText)
        // Twelve words in a row is still allowed.
        let twelve = other.split(separator: " ").prefix(12).joined(separator: " ")
        XCTAssertNil(check("Hi all,\n\nThanks for today. We noted: \(twelve).\n\nSam", ctx))
        let thirteen = other.split(separator: " ").prefix(13).joined(separator: " ")
        XCTAssertEqual(check("Hi all,\n\nThanks for today. We noted: \(thirteen).\n\nSam", ctx), .copiedCaptionText)
    }

    // A model draft that fails falls back to the template.

    func testChooseFallsBackToTheTemplateAndSaysWhy() {
        let template = "On my way — there about 18:45."
        let fine = DraftValidator.choose(model: "Leaving now, see you about 18:45.", template: template, context: context())
        XCTAssertEqual(fine.text, "Leaving now, see you about 18:45.")
        XCTAssertTrue(fine.usedModel)
        XCTAssertNil(fine.failure)

        let invented = DraftValidator.choose(model: "See you at 20:00!", template: template, context: context())
        XCTAssertEqual(invented.text, template)
        XCTAssertFalse(invented.usedModel)
        XCTAssertEqual(invented.failure, .timeOrDateNotInFacts)

        let none = DraftValidator.choose(model: nil, template: template, context: context())
        XCTAssertEqual(none.text, template)
        XCTAssertNil(none.failure)
    }

    func testEveryFailureHasATestAbove() {
        // A new row added to the enum must be tested here too.
        XCTAssertEqual(DraftValidationFailure.allCases.count, 11)
    }
}
