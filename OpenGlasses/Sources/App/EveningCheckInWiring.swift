import Foundation

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

    private static func holdKey(of entryID: UUID) -> String? {
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
    /// never what is in it.
    static func myDayDeliveryNotificationBody(_ slot: MyDayDeliverySlot) -> String {
        switch slot {
        case .checkIn:
            return String(localized: "Your evening check-in is ready.",
                          comment: "Notification: the evening check-in was delivered; names nothing in it.")
        case .morning, .evening:
            return "Your \(slot.rawValue) briefing is ready."
        }
    }
}
