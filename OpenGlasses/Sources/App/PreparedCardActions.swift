import MessageUI
import SwiftUI
import UIKit

/// A card's draft waiting in a platform composer (Plan KT §7.1). Presented from the root, like
/// Field Assist's report composer, so a card on any surface reaches the same sheet.
struct DraftComposerRequest: Identifiable, Equatable {
    let id = UUID()
    let cardID: PreparedCardID
    let route: DraftComposerRoute
}

extension AppState {

    // MARK: - Plan KT P1: what a card's buttons do

    /// The one place a card's action runs, from the My Day page, the home card or the job day's
    /// card. A hand-off opens a composer the wearer sends from; nothing here sends anything.
    func performCardAction(_ action: PreparedAction, on card: PreparedCard) {
        let service = myDayService
        let now = Date()
        service.changeCards(now: now) { $0.noteOpened(card) }
        switch action {
        case .handOff:
            handOff(card)
        case .directions(let destination, let mode):
            service.recordAction(.startDirections)
            if let url = Self.directionsURL(destination: destination, mode: mode) { UIApplication.shared.open(url) }
        case .openEvent(let id):
            service.recordAction(.openEvent)
            let start = service.gathered?.events.first { $0.id == id }?.startDate ?? card.dueAt ?? now
            if let url = URL(string: "calshow:\(start.timeIntervalSinceReferenceDate)") { UIApplication.shared.open(url) }
        case .openJob(let id):
            let isUpcoming = upcomingJobs.jobs.contains { $0.id == id }
            openJobs(isUpcoming ? .upcoming(id: id) : .session(id: id))
        case .openReport(let sessionId), .getSignOff(let sessionId):
            // The finished job's page: Send report, and the customer's signature.
            openJobs(.session(id: sessionId))
        case .openPartsOrder(let sessionId):
            if let reason = emailPartsOrder(sessionId: sessionId) {
                NoticeCenter.shared.post(reason, severity: .warning, source: .app)
                openJobs(.session(id: sessionId))
            }
        case .addToCalendar:
            // No P1 kind proposes an event; the action exists for the catalogue.
            break
        case .call(let contact):
            let digits = DraftComposerRouter.digits(contact.phone)
            if let url = URL(string: "tel:\(digits)") { UIApplication.shared.open(url) }
        case .complete(let reminderId):
            Task { _ = try? await service.completeCardReminder(card, reminderId: reminderId) }
        case .later:
            let option = PreparedCardLaterOption.available(validUntil: card.validUntil, now: now,
                                                           calendar: .autoupdatingCurrent).first
            if let until = option?.until(now: now, calendar: .autoupdatingCurrent) {
                service.changeCards(now: now) { $0.later(card, until: until, now: now) }
            }
        case .dismiss:
            service.changeCards(now: now) { $0.dismiss(card, now: now) }
        }
    }

    /// Open the card's draft in the platform composer, or the app its channel names, or copy it —
    /// the first route the device can take (`DraftComposerRouter`).
    func handOff(_ card: PreparedCard) {
        guard let draft = card.draft else { return }
        let routes = DraftComposerRouter.routes(for: draft, availability: Self.draftComposerAvailability)
        openDraftRoute(routes[...], card: card)
    }

    private func openDraftRoute(_ routes: ArraySlice<DraftComposerRoute>, card: PreparedCard) {
        guard let route = routes.first else { return }
        switch route {
        case .messagesComposer, .mailComposer:
            draftComposerRequest = DraftComposerRequest(cardID: card.id, route: route)
        case .openURL(let url, _):
            UIApplication.shared.open(url) { [weak self] opened in
                Task { @MainActor in
                    guard let self else { return }
                    if opened {
                        self.myDayService.changeCards { $0.handedOff(card, result: .unknown, now: Date()) }
                    } else {
                        self.openDraftRoute(routes.dropFirst(), card: card)
                    }
                }
            }
        case .copy(let text):
            UIPasteboard.general.string = text
            NoticeCenter.shared.post(String(localized: "Copied the draft. Paste it into the app you send from.",
                                            comment: "My Day card: no composer could open, so the draft was copied."),
                                     severity: .advisory, source: .app)
        }
    }

    /// The composer closed. Sent closes the card; anything else leaves it, edit and all.
    func finishDraftHandOff(_ request: DraftComposerRequest, result: PreparedCardState.HandOffResult) {
        draftComposerRequest = nil
        guard let card = myDayService.card(request.cardID) else { return }
        myDayService.changeCards { $0.handedOff(card, result: result, now: Date()) }
    }

    /// A tap on a card's notification: My Day, on the page that shows the card.
    func openPreparedCard(_ id: PreparedCardID) {
        requestedTab = .voice
        myDayPageRequested = true
    }

    static var draftComposerAvailability: DraftComposerAvailability {
        #if DEBUG
        if UITestSupport.isSet(.standInComposer) {
            return DraftComposerAvailability(canSendText: true, canSendMail: true, whatsappInstalled: false)
        }
        #endif
        let whatsapp = URL(string: "whatsapp://send").map { UIApplication.shared.canOpenURL($0) } ?? false
        return DraftComposerAvailability(canSendText: MFMessageComposeViewController.canSendText(),
                                         canSendMail: MFMailComposeViewController.canSendMail(),
                                         whatsappInstalled: whatsapp)
    }

    static func directionsURL(destination: String, mode: CardTravelMode) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        let flag: String
        switch mode {
        case .walking: flag = "w"
        case .driving: flag = "d"
        case .transit: flag = "r"
        }
        components?.queryItems = [URLQueryItem(name: "daddr", value: destination),
                                  URLQueryItem(name: "dirflg", value: flag)]
        return components?.url
    }
}
