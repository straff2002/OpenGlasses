import Foundation

// MARK: - My Day's "Waiting on you" section (Plan LE §8, P1)
//
// The section's rules and rows are here, testable; the SwiftUI view only draws them. Each row
// routes to its item's own place or confirmation — the check-in approves, sends and closes
// nothing by itself (§6, §10).

/// What a row's button does.
enum WaitingOnYouAction: Equatable, Hashable {
    /// Put the held call back in front of the wearer through its own confirmation.
    case review(entryID: UUID)
    /// Answer the held call no — nothing runs.
    case decline(entryID: UUID)
    /// Complete the reminder in Reminders.
    case complete(reminderID: String)
    /// Mark the goal step done.
    case stepDone(goalID: UUID, stepID: UUID)
    /// Open the item's own place.
    case open(OpenLoopPlace)
    /// An update or a result read here, on the phone: retired in its own store, as My Day's own
    /// digest rows are.
    case heard(OpenLoopPlace)

    /// Whether taking it leaves the My Day page — for a place on another screen, or for the
    /// confirmation card, which is drawn over the app's root.
    var leavesPage: Bool {
        switch self {
        case .open, .review: return true
        case .decline, .complete, .stepDone, .heard: return false
        }
    }

    var label: String {
        switch self {
        case .review: return String(localized: "Review", comment: "My Day, Waiting on you: put a held action back in front of the wearer to approve or decline.")
        case .decline: return String(localized: "Decline", comment: "My Day, Waiting on you: say no to a held action.")
        case .complete: return String(localized: "Complete", comment: "My Day, Waiting on you: complete a reminder.")
        case .stepDone: return String(localized: "Done", comment: "My Day, Waiting on you: mark a goal step done.")
        case .open: return String(localized: "Open", comment: "My Day, Waiting on you: open the item's own screen.")
        case .heard: return String(localized: "Mark as heard", comment: "My Day, Waiting on you: an update or result read on the phone.")
        }
    }

    var symbol: String {
        switch self {
        case .review: return "hand.raised"
        case .decline: return "xmark.circle"
        case .complete, .stepDone: return "checkmark.circle"
        case .open: return "arrow.up.forward.square"
        case .heard: return "checkmark.circle"
        }
    }
}

/// One row, in the wearer's words where the source has them.
struct WaitingOnYouRow: Identifiable, Equatable {
    let loop: OpenLoop
    let title: String
    let detail: String?
    let symbol: String
    /// The row's button.
    let primary: WaitingOnYouAction?
    /// A second button: Decline, on an approval.
    let secondary: WaitingOnYouAction?

    var id: String { loop.id }

    init(_ loop: OpenLoop, canReview: Bool) {
        self.loop = loop
        self.title = WaitingOnYouText.title(loop)
        self.detail = WaitingOnYouText.detail(loop)
        self.symbol = WaitingOnYouText.symbol(loop.source)
        switch loop.action {
        case .approve(let entryID):
            // A held call can only be put back while its arguments are still kept (in memory, for
            // its lifetime); after a relaunch, Decline is what is left.
            primary = canReview ? .review(entryID: entryID) : nil
            secondary = .decline(entryID: entryID)
        case .complete(let id):
            primary = .complete(reminderID: id)
            secondary = nil
        case .stepDone(let goalID, let stepID):
            primary = .stepDone(goalID: goalID, stepID: stepID)
            secondary = nil
        case .open(let place):
            switch place {
            case .digestItem, .agentResult: primary = .heard(place)
            case .job, .card, .goal: primary = .open(place)
            }
            secondary = nil
        case .dismiss:
            primary = nil
            secondary = nil
        }
    }
}

enum WaitingOnYouSection {

    /// The section shows while the check-in is on, all evening (from 18:00, My Day's own evening),
    /// and whenever the list has something in it after the check-in's time.
    static func isVisible(checkInEnabled: Bool, isEmpty: Bool, now: Date, calendar: Calendar,
                          checkInMinutes: Int) -> Bool {
        guard checkInEnabled else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let hour = parts.hour ?? 0
        let minute = hour * 60 + (parts.minute ?? 0)
        if hour >= 18 { return true }
        return !isEmpty && minute >= checkInMinutes
    }

    @MainActor
    static func rows(_ collection: OpenLoopCollection, canReview: @MainActor (UUID) -> Bool) -> [WaitingOnYouRow] {
        collection.loops.map { loop in
            if case .approve(let entryID) = loop.action {
                return WaitingOnYouRow(loop, canReview: canReview(entryID))
            }
            return WaitingOnYouRow(loop, canReview: false)
        }
    }
}

/// What each row's button reaches — AppState's services in the app, fakes in a test.
struct WaitingOnYouHandlers {
    /// Put the held call behind `entryID` back through its own confirmation. False when it can no
    /// longer be put back.
    var review: @MainActor (UUID) async -> Bool = { _ in false }
    var canReview: @MainActor (UUID) -> Bool = { _ in false }
    var decline: @MainActor (UUID) -> Void = { _ in }
    var completeReminder: @MainActor (String) async -> Void = { _ in }
    var completeStep: @MainActor (UUID, UUID) -> Void = { _, _ in }
    var open: @MainActor (OpenLoopPlace) -> Void = { _ in }
    var markHeard: @MainActor (OpenLoopPlace) -> Void = { _ in }
}

/// The section's state and its actions.
@MainActor
final class WaitingOnYouScreenModel: ObservableObject {
    @Published private(set) var rows: [WaitingOnYouRow] = []
    @Published private(set) var isVisible = false
    @Published private(set) var unavailable: [OpenLoopSource] = []
    /// A sentence for the wearer when an action could not be taken.
    @Published var notice: String?

    let checkIn: EveningCheckInService
    var handlers: WaitingOnYouHandlers
    var settings: @MainActor () -> MyDayDeliverySettings = { .current }
    var calendar: @MainActor () -> Calendar = { .autoupdatingCurrent }

    init(checkIn: EveningCheckInService, handlers: WaitingOnYouHandlers = WaitingOnYouHandlers()) {
        self.checkIn = checkIn
        self.handlers = handlers
    }

    func refresh(now: Date = Date()) async {
        let collection = await checkIn.collect(now: now)
        apply(collection, now: now)
    }

    private func apply(_ collection: OpenLoopCollection, now: Date) {
        let settings = settings()
        rows = WaitingOnYouSection.rows(collection, canReview: handlers.canReview)
        unavailable = collection.unavailable
        isVisible = WaitingOnYouSection.isVisible(checkInEnabled: settings.checkInEnabled,
                                                  isEmpty: collection.isEmpty, now: now,
                                                  calendar: calendar(),
                                                  checkInMinutes: settings.resolvedCheckInMinutes)
    }

    func perform(_ action: WaitingOnYouAction, now: Date = Date()) async {
        switch action {
        case .review(let entryID):
            if !(await handlers.review(entryID)) {
                notice = String(localized: "That can no longer be put back from here. Ask again if you still want it.",
                                comment: "My Day, Waiting on you: a held action whose details are gone (the app restarted, or it lapsed).")
            }
        case .decline(let entryID):
            handlers.decline(entryID)
        case .complete(let reminderID):
            await handlers.completeReminder(reminderID)
        case .stepDone(let goalID, let stepID):
            handlers.completeStep(goalID, stepID)
        case .open(let place):
            handlers.open(place)
            return
        case .heard(let place):
            handlers.markHeard(place)
        }
        await refresh(now: now)
    }

    /// Swipe to clear for tonight: the dismissal store, nothing else.
    func dismiss(_ row: WaitingOnYouRow, now: Date = Date()) {
        checkIn.dismiss(row.loop, now: now)
        apply(checkIn.latest, now: now)
    }
}

/// Row words. Templates, like the spoken ones; the wearer's own text where the source has it.
enum WaitingOnYouText {

    static func title(_ loop: OpenLoop) -> String {
        switch loop.source {
        case .jobReport:
            return loop.failed
                ? String(localized: "Report didn't send", comment: "My Day, Waiting on you: a job report whose send failed.")
                : String(localized: "Report not sent", comment: "My Day, Waiting on you: a job report not yet sent.")
        case .jobCloseHeld:
            return String(localized: "Job not closed", comment: "My Day, Waiting on you: a job whose close is held.")
        case .partsRequest:
            return String(localized: "\(loop.title) not ordered", comment: "My Day, Waiting on you: a part asked for and not yet sent; the part's name.")
        case .deferredTask:
            return String(localized: "Put off: \(loop.title)", comment: "My Day, Waiting on you: a job task the technician deferred.")
        case .expertOrEscalation:
            if let expert = loop.subject {
                return String(localized: "No answer yet from \(expert)", comment: "My Day, Waiting on you: an expert hand-off still unanswered.")
            }
            return String(localized: "Escalation not answered", comment: "My Day, Waiting on you: an escalation still unanswered.")
        default:
            return loop.title
        }
    }

    static func detail(_ loop: OpenLoop) -> String? {
        switch loop.source {
        case .approval:
            return String(localized: "Held while you were away", comment: "My Day, Waiting on you: under a held action.")
        case .reminder:
            return String(localized: "Reminder", comment: "My Day, Waiting on you: under a reminder.")
        case .goalStep:
            return loop.subject
        case .digest:
            return String(localized: "Update you haven't heard", comment: "My Day, Waiting on you: under a digest update.")
        case .agentResult:
            return String(localized: "Result waiting", comment: "My Day, Waiting on you: under a result the assistant has not delivered.")
        case .jobCloseHeld:
            let needs = String(localized: "Needs \(loop.title)", comment: "My Day, Waiting on you: what a held job close waits on, e.g. Needs the customer's sign-off.")
            return [jobLabel(loop.job), needs].compactMap { $0 }.joined(separator: " · ")
        case .expertOrEscalation where loop.subject == nil:
            return [jobLabel(loop.job), loop.title.isEmpty ? nil : loop.title].compactMap { $0 }.joined(separator: " · ")
        case .jobReport, .partsRequest, .deferredTask, .expertOrEscalation:
            return jobLabel(loop.job)
        case .draft, .waitingOnOthers, .watcherFinding, .askAgain:
            return loop.subject
        }
    }

    /// "Smith" or "Job 1005" — as the job's record names it.
    static func jobLabel(_ job: OpenLoopJobName?) -> String? {
        switch job {
        case .customer(let name): return name
        case .reference(let reference): return String(localized: "Job \(reference)", comment: "My Day, Waiting on you: a job named by its number.")
        case nil: return nil
        }
    }

    static func symbol(_ source: OpenLoopSource) -> String {
        switch source {
        case .approval: return "hand.raised"
        case .reminder: return "checklist"
        case .goalStep: return "flag"
        case .digest: return "tray"
        case .agentResult: return "sparkles"
        case .draft: return "square.and.pencil"
        case .waitingOnOthers: return "person.badge.clock"
        case .watcherFinding: return "eye"
        case .askAgain: return "arrow.clockwise"
        case .jobReport: return "doc.text"
        case .jobCloseHeld: return "lock"
        case .partsRequest: return "shippingbox"
        case .deferredTask: return "clock.arrow.circlepath"
        case .expertOrEscalation: return "person.wave.2"
        }
    }

    /// The line under the section when some source could not be read.
    static var unreadableNote: String {
        String(localized: "Some of what this list reads could not be checked just now.",
               comment: "My Day, Waiting on you: one or more sources could not be read.")
    }

    static var emptyNote: String {
        String(localized: "Nothing is waiting on you.", comment: "My Day, Waiting on you: the list is empty.")
    }
}
