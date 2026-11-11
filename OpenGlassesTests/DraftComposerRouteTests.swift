import XCTest
@testable import OpenGlasses

/// Plan KT §7.1 / decision 2 — how a draft leaves the phone, per channel and per what the device
/// can do: Messages composer else `sms:` else copy; Mail composer else `mailto:` else copy;
/// WhatsApp when installed else Messages. Every route ends at a Send the wearer taps.
final class DraftComposerRouteTests: XCTestCase {

    private func draft(_ channel: DraftChannel, addresses: [String], text: String = "On my way & nearly there",
                       subject: String? = nil) -> PreparedDraft {
        PreparedDraft(channel: channel,
                      recipient: DraftRecipient(name: "Ana Example", addresses: addresses, source: .calendarAttendee),
                      subject: subject, text: text, language: "en-GB")
    }

    private func device(text: Bool = true, mail: Bool = true, whatsapp: Bool = true) -> DraftComposerAvailability {
        DraftComposerAvailability(canSendText: text, canSendMail: mail, whatsappInstalled: whatsapp)
    }

    // MARK: - Messages

    func testMessagesUseTheComposerWhenTheDeviceCanText() {
        let routes = DraftComposerRouter.routes(for: draft(.messages, addresses: ["555-0142"]), availability: device())
        XCTAssertEqual(routes, [.messagesComposer(recipients: ["555-0142"], body: "On my way & nearly there")])
        XCTAssertTrue(routes[0].reportsResult)
    }

    func testMessagesFallBackToSMSThenCopy() {
        let routes = DraftComposerRouter.routes(for: draft(.messages, addresses: ["555-0142"]),
                                                availability: device(text: false))
        XCTAssertEqual(routes.count, 2)
        guard case .openURL(let url, let app) = routes[0] else { return XCTFail("expected sms:") }
        XCTAssertEqual(app, .messages)
        XCTAssertEqual(url.scheme, "sms")
        XCTAssertTrue(url.absoluteString.hasPrefix("sms:5550142&body="))
        XCTAssertTrue(url.absoluteString.contains("%26"), "an ampersand in the draft cannot end the body early")
        XCTAssertEqual(routes[1], .copy("On my way & nearly there"))
        XCTAssertFalse(routes[0].reportsResult)
    }

    func testAMessageNeverGoesToAnEmailAddress() {
        let routes = DraftComposerRouter.routes(for: draft(.messages, addresses: ["ana@example.com", "555-0142"]),
                                                availability: device())
        XCTAssertEqual(routes, [.messagesComposer(recipients: ["555-0142"], body: "On my way & nearly there")])
    }

    // MARK: - Email

    func testEmailUsesTheMailComposerWhenMailIsSetUp() {
        let routes = DraftComposerRouter.routes(
            for: draft(.email, addresses: ["ana@example.com", "555-0142"], subject: "Today"), availability: device())
        XCTAssertEqual(routes, [.mailComposer(recipients: ["ana@example.com"], subject: "Today",
                                              body: "On my way & nearly there")])
    }

    func testEmailFallsBackToTheDefaultMailAppThenCopy() {
        let routes = DraftComposerRouter.routes(
            for: draft(.email, addresses: ["ana@example.com"], subject: "Today"), availability: device(mail: false))
        XCTAssertEqual(routes.count, 2)
        guard case .openURL(let url, let app) = routes[0] else { return XCTFail("expected mailto:") }
        XCTAssertEqual(app, .email)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "mailto")
        XCTAssertEqual(components?.path, "ana@example.com")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "subject" }?.value, "Today")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "body" }?.value, "On my way & nearly there")
        XCTAssertEqual(routes[1], .copy("On my way & nearly there"))
    }

    // MARK: - WhatsApp

    func testWhatsAppOpensWhenInstalled() {
        let routes = DraftComposerRouter.routes(for: draft(.whatsapp, addresses: ["+64 21 555 0142"]), availability: device())
        guard case .openURL(let url, let app)? = routes.first else { return XCTFail("expected whatsapp://") }
        XCTAssertEqual(app, .whatsapp)
        XCTAssertTrue(url.absoluteString.hasPrefix("whatsapp://send?phone=+64215550142&text="))
        XCTAssertEqual(routes.count, 1)
    }

    func testWhatsAppFallsBackToMessages() {
        let routes = DraftComposerRouter.routes(for: draft(.whatsapp, addresses: ["555-0142"]),
                                                availability: device(whatsapp: false))
        XCTAssertEqual(routes, [.messagesComposer(recipients: ["555-0142"], body: "On my way & nearly there")])
    }

    // MARK: - Results

    func testOnlyASendClosesTheCard() {
        XCTAssertEqual(DraftComposerRouter.messageResult(1), .sent)
        XCTAssertEqual(DraftComposerRouter.messageResult(0), .cancelled)
        XCTAssertEqual(DraftComposerRouter.messageResult(2), .cancelled, "a failed send leaves the card")
        XCTAssertEqual(DraftComposerRouter.mailResult(2, error: nil), .sent)
        XCTAssertEqual(DraftComposerRouter.mailResult(1, error: nil), .cancelled, "a saved draft is not sent")
        XCTAssertEqual(DraftComposerRouter.mailResult(0, error: nil), .cancelled)
        XCTAssertEqual(DraftComposerRouter.mailResult(2, error: NSError(domain: "x", code: 1)), .cancelled)
    }

    /// Field Assist's report composer moved onto the shared presenter: its outcomes read as before.
    func testFieldAssistsOutcomesAreUnchanged() {
        XCTAssertEqual(ReportComposerOutcome.mail(result: 2, error: nil), .sent)
        XCTAssertEqual(ReportComposerOutcome.mail(result: 1, error: nil), .saved)
        XCTAssertEqual(ReportComposerOutcome.mail(result: 0, error: nil), .cancelled)
        XCTAssertEqual(ReportComposerOutcome.message(result: 1), .sent)
        XCTAssertEqual(ReportComposerOutcome.message(result: 0), .cancelled)
    }
}
