import CallKit
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

    // MARK: - Plan KT P3: the cards on the Display

    /// The day's cards on the lens: the stack (`HUDRouter`), the glances pushed unasked
    /// (`PreparedCardGlances`) and "Send on phone" (`PreparedCardStager`).
    func configurePreparedCardLens() {
        let service = myDayService
        hudRouter.cardHooks = PreparedCardLensHooks(
            cards: { [weak service] in service?.todayFeed.cards ?? [] },
            run: { [weak self] action, card in self?.performCardActionFromLens(action, on: card) },
            stage: { [weak self] card in await self?.preparedCardStager.stage(card) ?? .nothingToStage },
            // Plan KT P4: the draft with who it is to, through the phraser (withheld under Medical
            // Compliance when it names the meeting).
            readAloud: { [weak self] card in
                Task { await self?.preparedCardSpeech.readDraft(card) }
            },
            later: { [weak self] card in self?.performCardAction(.later, on: card) },
            dismiss: { [weak self] card in self?.performCardAction(.dismiss, on: card) },
            notUseful: { [weak service] card in service?.changeCards { $0.notUseful(card, now: Date()) } },
            notePress: { [weak service] action in service?.cardBuilder?.noteLensPress(action) },
            withholding: { PreparedCardMedicalWithholding.isOn })

        preparedCardGlances.cards = { [weak service] in service?.todayFeed.cards ?? [] }
        preparedCardGlances.worn = { [weak self] in self?.glassesService.isWorn }
        preparedCardGlances.quiet = {
            MyDayDeliveryPolicy.isQuiet(at: Date(), calendar: .autoupdatingCurrent, settings: .current)
        }
        preparedCardGlances.open = { [weak self] id in self?.hudRouter.openCards(at: id) }
        preparedCardGlances.notePushed = { [weak service] card in service?.cardBuilder?.notePushed(card) }
        preparedCardGlances.withholding = { PreparedCardMedicalWithholding.isOn }
        // Plan KT P4: a pushed card the lens can't show is said instead — through the glasses, never
        // on a call, never over captions or the wearer's own turn.
        preparedCardGlances.speech = { [weak self] in
            guard let self else { return .unavailable }
            return PreparedCardPushPolicy.Speech(
                glassesConnected: self.isConnected,
                onCall: CXCallObserver().calls.contains { !$0.hasEnded },
                captionsRunning: self.ambientCaptions.isActive,
                busy: self.isProcessing || self.isListening || self.inConversation || self.speechService.isSpeaking)
        }
        preparedCardGlances.sayInstead = { [weak self] card in
            Task { await self?.preparedCardSpeech.speakPushed(card) }
        }
        preparedCardGlances.noteSpoken = { [weak service] card in service?.cardBuilder?.noteSpoken(card) }

        // Plan KT P4: "what's ready?" read aloud, and the answers while it reads. A spoken yes only
        // stages, through the same stager as the lens's Send on phone.
        preparedCardSpeech.cards = { [weak service] in service?.todayFeed.cards ?? [] }
        preparedCardSpeech.stage = { [weak self] card in await self?.preparedCardStager.stage(card) ?? .nothingToStage }
        preparedCardSpeech.later = { [weak self] card in self?.performCardAction(.later, on: card) }
        preparedCardSpeech.dismiss = { [weak self] card in self?.performCardAction(.dismiss, on: card) }
        preparedCardSpeech.notUseful = { [weak service] card in service?.changeCards { $0.notUseful(card, now: Date()) } }
        preparedCardSpeech.voice = { [weak self] text, source in
            await self?.speechService.speak(text, source: source, mirrorToHUD: false)
        }

        // Plan KT §6.7: a press on a wrist card. `stage` is the lens's Send on phone.
        watchPreparedCardHandler.cards = { [weak service] in service?.todayFeed.cards ?? [] }
        watchPreparedCardHandler.stage = { [weak self] card in
            await self?.preparedCardStager.stage(card) ?? .nothingToStage
        }
        watchPreparedCardHandler.run = { [weak self] action, card in
            self?.performCardActionAway(action, on: card) ?? false
        }
        watchPreparedCardHandler.later = { [weak self] card in self?.performCardAction(.later, on: card) }
        watchPreparedCardHandler.dismiss = { [weak self] card in self?.performCardAction(.dismiss, on: card) }

        preparedCardStager.record = { [weak service] card in service?.changeCards { $0.stage(card, now: Date()) } }
        preparedCardStager.openComposer = { [weak self] card in
            guard let self else { return }
            self.handOff(self.myDayService.card(card.id) ?? card)
        }
        preparedCardStager.appInFront = { UIApplication.shared.applicationState == .active }
        preparedCardStager.unlocked = { UIApplication.shared.isProtectedDataAvailable }
    }

    /// A card's own action pressed on the lens. Done runs where it is; an action that needs the
    /// phone (directions, an open, a call) runs when the app is in front, and otherwise opens the
    /// card on the phone the next time it is unlocked (§6.4).
    func performCardActionFromLens(_ action: PreparedAction, on card: PreparedCard) {
        guard !performCardActionAway(action, on: card) else { return }
        glassesDisplay.flash(PreparedCardHUDBuilder.openOnPhoneLine, duration: 3)
    }

    /// A card's own action pressed away from the phone (the lens, the watch). True when it ran now;
    /// false when the card opens on the phone the next time it is unlocked instead.
    @discardableResult
    func performCardActionAway(_ action: PreparedAction, on card: PreparedCard) -> Bool {
        if case .complete = action {
            performCardAction(action, on: card)
            return true
        }
        if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable {
            performCardAction(action, on: card)
            return true
        }
        openPreparedCard(card.id)
        return false
    }

    /// A tap on a staged card's notification: its composer, with the draft it was staged with.
    func openStagedCard(_ id: PreparedCardID) {
        preparedCardStager.composerOpened(id)
        if let card = myDayService.card(id), card.draft != nil {
            pendingStagedCard = nil
            handOff(card)
        } else {
            // A cold launch: the feed has not been built yet. The page opens now and the composer
            // as soon as the card is there.
            pendingStagedCard = id
            openPreparedCard(id)
        }
    }

    func openPendingStagedCard() {
        guard let id = pendingStagedCard, let card = myDayService.card(id), card.draft != nil else { return }
        pendingStagedCard = nil
        handOff(card)
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
