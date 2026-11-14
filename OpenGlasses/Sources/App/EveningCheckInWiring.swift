import Combine
import Foundation
import UIKit

/// The Evening Check-in's wiring (Plan LE P1): the readers over AppState's own services, the
/// scheduled delivery's content and motion reading, and what a Waiting on you row's button reaches.
extension AppState {

    /// The check-in the registry made, with the personal readers already in it.
    var eveningCheckIn: EveningCheckInService { nativeToolRegistry.eveningCheckIn }

    func wireEveningCheckIn() {
        let checkIn = eveningCheckIn
        checkIn.install(DigestLoopReader(items: { [weak self] in self?.notificationDigest.items ?? [] }))
        checkIn.install(AgentResultLoopReader(pending: { [weak self] in
            self?.agentNotificationQueue.pendingNotifications ?? []
        }))
        checkIn.install(JobLoopReader(facts: { [weak self] in
            guard let self else { return nil }
            let now = Date()
            return JobLoopReader.facts(sessions: FieldSessionService.shared,
                                       queue: self.jobSends.queue.queue.entries,
                                       now: now, calendar: .autoupdatingCurrent)
        }))

        myDayDelivery.checkIn = checkIn
        myDayDelivery.motion = { [weak self] in
            MyDayDeliveryMotion.kind(of: self?.motionProvider.latestSample, now: Date())
        }
        wireCheckInSurfaces()
    }

    // MARK: - P2: the notification, the offer, the lens and the wrist

    private func wireCheckInSurfaces() {
        let checkIn = eveningCheckIn

        // §6: "Want to deal with the first one now?" — offered only for a call the router still
        // keeps, taken by `activity` `deal_with_first`, and put back through its own confirmation.
        checkIn.holdKey = { entryID in Self.holdKey(of: entryID) }
        checkIn.canReplay = { [weak self] key in self?.nativeToolRouter.canReplayHeld(key: key) ?? false }
        checkIn.replay = { [weak self] key in
            guard let self else { return nil }
            return await self.nativeToolRouter.replayHeld(key: key)?.text
        }
        // The scheduled check-in is spoken outside any turn; only a Direct-mode turn carries the
        // note that lets the model take the yes. A live session never hears the scheduled one.
        checkIn.offersAfterScheduled = { Config.appMode == .direct }
        llmService.turnNote = { [weak checkIn] in checkIn?.offerTurnNote() }

        // §5: tonight's notification, settled whenever the check-in runs with the app alive.
        let notifications = checkInNotifications
        myDayDelivery.onCheckInRan = { dayKey, delivered, spoke in
            Task { @MainActor in await notifications.checkInRan(dayKey: dayKey, delivered: delivered, spoke: spoke) }
        }
        notifications.start()
        BackgroundRefreshCoordinator.shared.add(notifications.backgroundParticipant())

        // §5: "the first foreground within the delivery window runs the check-in" — the delivery
        // timer looks once a minute; on foreground it looks at once. The policy decides, as ever.
        checkInSubscriptions.removeAll()
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.myDayDelivery.evaluate() }
            }
            .store(in: &checkInSubscriptions)
    }

    /// §5: the wearer tapped the check-in's notification. My Day opens on the Waiting on you section,
    /// and the delivery policy runs: inside the window, and outside quiet hours, the check-in is said
    /// if tonight's has not been; otherwise the list is on the page.
    func openCheckInFromNotification(dayKey: String) {
        requestedTab = .voice
        myDayPageRequested = true
        Task { @MainActor [weak self] in await self?.myDayDelivery.evaluate() }
    }

    /// §8: the scheduled check-in, spoken, also goes on the lens as one card through the answer
    /// card's pager — never over a turn collecting its own answer.
    func showCheckInOnLens(spoke: Bool) {
        guard CheckInLensCard.shows(spoke: spoke, turnOpen: hudAnswerCard.isTurnOpen),
              let delivered = eveningCheckIn.lastDelivered,
              let text = CheckInLensCard.text(delivered, fieldAssist: Config.fieldAssistActive) else { return }
        hudAnswerCard.absorb(text, streamed: false)
    }

    /// §8: the check-in's line for the watch's Today value, from the last read of the list.
    func checkInWatchLine(now: Date, redacted: Bool) -> WatchTodayWaiting? {
        WatchTodayWaitingBuilder.line(eveningCheckIn.latest, readAt: eveningCheckIn.latestAt, now: now,
                                      calendar: .autoupdatingCurrent, settings: .current, redacted: redacted)
    }

    /// The Waiting on you section's buttons, each to the item's own place or confirmation.
    func makeWaitingOnYouModel() -> WaitingOnYouScreenModel {
        var handlers = WaitingOnYouHandlers()
        handlers.canReview = { [weak self] entryID in
            guard let self, let key = Self.holdKey(of: entryID) else { return false }
            return self.nativeToolRouter.canReplayHeld(key: key)
        }
        handlers.review = { [weak self] entryID in
            guard let self, let key = Self.holdKey(of: entryID),
                  self.nativeToolRouter.canReplayHeld(key: key) else { return false }
            // The call's own confirmation card asks; its answer resolves the trail entry.
            _ = await self.nativeToolRouter.replayHeld(key: key)
            return true
        }
        handlers.decline = { entryID in
            ActivityStore.shared.resolve(entryID: entryID, as: .declined, at: Date())
        }
        handlers.completeReminder = { [weak self] reminderID in
            _ = try? await self?.myDayService.completeReminder(id: reminderID)
        }
        handlers.completeStep = { goalID, stepID in
            _ = GoalStoreDaySource().completeGoalStep(goalID: goalID, stepID: stepID, now: Date())
        }
        handlers.open = { [weak self] place in
            guard let self else { return }
            switch place {
            case .job(let destination): self.openJobDayDestination(destination)
            case .digestItem, .agentResult, .card, .goal: break
            }
        }
        handlers.markHeard = { [weak self] place in
            guard let self else { return }
            switch place {
            case .digestItem(let id): self.notificationDigest.dismissItem(id: id)
            case .agentResult(let id): self.agentNotificationQueue.markDelivered(ids: [id])
            case .job, .card, .goal: break
            }
        }
        return WaitingOnYouScreenModel(checkIn: eveningCheckIn, handlers: handlers)
    }

    static func holdKey(of entryID: UUID) -> String? {
        ActivityStore.shared.entries.first { $0.id == entryID }?.holdKey
    }

    /// A job-day place, opened from wherever the wearer is: the Jobs tab for a job's page, the
    /// composer for a queued report or a parts order.
    func openJobDayDestination(_ destination: JobDayDestination) {
        if let request = JobListRequest(destination) {
            openJobs(request)
        } else if case .send(let id) = destination, let entry = jobSends.queue.queue.entry(id: id) {
            jobSends.present(entry)
        } else if case .partsOrder(let sessionId) = destination {
            // When the order cannot open — no channel allowed, nobody to send it to — the job's
            // page is where the reason and the requests are.
            if let reason = emailPartsOrder(sessionId: sessionId) {
                NoticeCenter.shared.post(reason, severity: .warning, source: .app)
                openJobs(.session(id: sessionId))
            }
        }
    }

    /// The notification a scheduled delivery leaves on the phone. Content-free: it names the slot,
    /// never what is in it. The check-in's own is posted by `CheckInNotificationScheduler` (P2), with
    /// the same words.
    static func myDayDeliveryNotificationBody(_ slot: MyDayDeliverySlot) -> String {
        switch slot {
        case .checkIn:
            return CheckInNotificationPolicy.body
        case .morning, .evening:
            return "Your \(slot.rawValue) briefing is ready."
        }
    }
}
