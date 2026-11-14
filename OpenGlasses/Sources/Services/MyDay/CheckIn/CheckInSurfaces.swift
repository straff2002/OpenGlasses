import Foundation

// Plan LE §8 (P2) — the check-in on the lens and on the wrist. Both pure: what they show is decided
// here, and the device edges only hand the result on.

// MARK: - The Display card

/// The check-in as one card on the in-lens Display: the count and the first item on the first page,
/// the rest behind KP's page turn.
///
/// The card goes through the answer card (`HUDAnswerCard`) as a whole answer outside a turn, so it
/// gets that card's pager, page turn, Close and lifetime, and no new Display API. One item a line,
/// in My Day's own row titles (`WaitingOnYouText.title`), which are short; the pager starts every
/// line on a line of its own and carries three lines a page with the footer on the Meta Display, so
/// the count and the first item fill the first page.
enum CheckInLensCard {

    /// Items listed on the card; the rest are counted.
    static let maximumItems = 6

    /// The card's text, or nil when there is nothing to show.
    static func text(_ collection: OpenLoopCollection, fieldAssist: Bool) -> String? {
        let loops = collection.loops
        guard !loops.isEmpty else { return nil }
        var lines = [heading(count: loops.count, fieldAssist: fieldAssist)]
        lines += loops.prefix(maximumItems).map { WaitingOnYouText.title($0) }
        let rest = loops.count - min(loops.count, maximumItems)
        if rest > 0 {
            lines.append(String(localized: "\(rest) more on your phone",
                                comment: "Glasses: the check-in card, items past the ones listed; the number of them."))
        }
        return lines.joined(separator: "\n")
    }

    /// "3 waiting on you" / "2 before you finish".
    static func heading(count: Int, fieldAssist: Bool) -> String {
        fieldAssist
            ? String(localized: "\(count) before you finish",
                     comment: "Glasses and watch: the end-of-shift check-in's heading; the number of items still open.")
            : String(localized: "\(count) waiting on you",
                     comment: "Glasses and watch: the evening check-in's heading; the number of items still waiting on the wearer.")
    }

    /// Whether the scheduled check-in also goes on the lens: only when it was spoken (the glasses are
    /// worn and the wearer is not driving — decision 10 keeps it off the lens too) and no turn is
    /// collecting an answer, which the card would otherwise join.
    static func shows(spoke: Bool, turnOpen: Bool) -> Bool {
        spoke && !turnOpen
    }
}

// MARK: - The watch's Today line

/// The check-in's line in the watch's Today value (Plan KS): the count and the first item, when the
/// check-in is on and has items in the evening.
///
/// It follows My Day's Waiting on you section (`WaitingOnYouSection.isVisible`): nothing with the
/// check-in off, nothing before the evening unless the check-in's time has passed, and nothing when
/// the list is empty. It mirrors the last read of the list (`EveningCheckInService.latest`), and only
/// a read made today. Under any Medical Compliance mode the wrist gets the count alone, as it gets
/// an appointment's time without its title.
enum WatchTodayWaitingBuilder {

    static func line(_ collection: OpenLoopCollection, readAt: Date?, now: Date, calendar: Calendar,
                     settings: MyDayDeliverySettings, redacted: Bool) -> WatchTodayWaiting? {
        guard settings.myDayEnabled, let readAt, calendar.isDate(readAt, inSameDayAs: now),
              !collection.loops.isEmpty,
              WaitingOnYouSection.isVisible(checkInEnabled: settings.checkInEnabled, isEmpty: false, now: now,
                                            calendar: calendar, checkInMinutes: settings.resolvedCheckInMinutes)
        else { return nil }
        let first = redacted ? nil : collection.loops.first.flatMap {
            WatchTodayBuilder.shortened(WaitingOnYouText.title($0), limit: WatchTodayBuilder.titleLimit)
        }
        let count = collection.loops.count
        return WatchTodayWaiting(count: count,
                                 heading: CheckInLensCard.heading(count: count, fieldAssist: settings.fieldAssistOn),
                                 first: first)
    }
}
