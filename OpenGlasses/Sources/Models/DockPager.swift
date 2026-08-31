import Foundation

/// The pages of the dock panel, in the order they are swiped through.
///
/// The grid is the middle page and the home one: the conversation is a swipe left of it and the
/// editor a swipe right, so neither is more than one gesture from where the user rests. Raw values
/// are the page order and are what the pager's selection binding carries.
enum DockPage: Int, CaseIterable, Identifiable, Hashable {
    case conversation = 0
    case actions = 1
    case edit = 2

    var id: Int { rawValue }

    /// Where the panel sits when nothing has asked it to be anywhere else.
    static let home: DockPage = .actions

    /// What VoiceOver calls the action that brings this page up. The pager's own page control is an
    /// adjustable element, but an adjustable is a poor way to reach a *named* destination, so every
    /// page is also one named action away from wherever focus happens to be.
    var showActionName: String {
        switch self {
        case .conversation: return "Show conversation"
        case .actions: return "Show actions"
        case .edit: return "Edit actions"
        }
    }

    /// Announced when the page becomes the visible one, so a swipe is not a silent change.
    var spokenName: String {
        switch self {
        case .conversation: return "Conversation"
        case .actions: return "Actions"
        case .edit: return "Edit actions"
        }
    }
}

/// Everything the pager remembers between state changes.
struct DockPagerState: Equatable {
    var page: DockPage = .home
    /// Set the moment the user moves the pager themselves, cleared when a new turn begins. It is
    /// the whole of the "never fight the user" rule: within one turn, their swipe is final.
    var userMovedThisTurn = false
}

/// When the dock panel flips itself, and — more importantly — when it does not.
///
/// Pure, because "the panel moved on its own while I was reading" is the kind of bug that is
/// miserable to reproduce by hand and trivial to state as a table.
enum DockPagerPolicy {
    /// A turn is live from the moment the assistant starts working on it until it stops speaking.
    static func isTurnActive(_ state: VoiceVisualState) -> Bool {
        state == .thinking || state == .speaking
    }

    /// Whether this transition *starts* a turn. An edge, not a level: flipping on the level would
    /// move the page again on every unrelated republish that redrew the dock.
    static func startsTurn(from previous: VoiceVisualState, to next: VoiceVisualState) -> Bool {
        !isTurnActive(previous) && isTurnActive(next)
    }

    /// The two moments the conversation is the thing worth looking at: the turn starting, and the
    /// reply beginning to arrive.
    static func wantsConversation(from previous: VoiceVisualState,
                                  to next: VoiceVisualState) -> Bool {
        startsTurn(from: previous, to: next) || (previous == .thinking && next == .speaking)
    }

    /// Fold a voice-state change into the pager.
    ///
    /// Three rules, and the third is the one with teeth:
    ///   1. A turn starting grants a fresh right to flip — a new turn is new news.
    ///   2. The turn starting and the reply arriving are the moments it flips.
    ///   3. If the user has moved the pager during this turn, it does not flip again for that turn.
    ///      Swiping back to the grid mid-response has to mean something, or the panel is arguing.
    ///
    /// A turn *ending* moves nothing: the reply stays on screen until the user swipes away or the
    /// next turn arrives. There is deliberately no idle timer — a panel that slides out from under
    /// someone still reading is the same failure as one that fights their swipe, only on a delay.
    static func advance(_ state: DockPagerState,
                        from previous: VoiceVisualState,
                        to next: VoiceVisualState) -> DockPagerState {
        var result = state
        if startsTurn(from: previous, to: next) {
            result.userMovedThisTurn = false
        }
        guard wantsConversation(from: previous, to: next), !result.userMovedThisTurn else {
            return result
        }
        result.page = .conversation
        return result
    }

    /// The user swiped, or took one of the pager's named accessibility actions. Their choice stands
    /// for the rest of the turn.
    static func userMoved(_ state: DockPagerState, to page: DockPage) -> DockPagerState {
        DockPagerState(page: page, userMovedThisTurn: true)
    }
}

// MARK: - Arrangement editing

/// The arrangement mutations both editing surfaces perform, as pure functions over the stored
/// record — the in-panel edit page and the full-screen editor differ only in how they are driven,
/// and nothing about *what* an edit means should depend on which one the user reached for.
///
/// Every mutation writes the **resolved** order back rather than the stored one. An arrangement is
/// allowed to leave slots unmentioned — that is how a new control or a newly added speed-dial
/// action arrives — and a move or a removal only means something once those implicit slots have a
/// place of their own.
enum DockArrangementEditor {
    static func materialised(_ arrangement: HomeGridArrangement,
                             resolved: [DockSlot]) -> HomeGridArrangement {
        var next = arrangement
        next.order = resolved.map(\.id)
        return next
    }

    static func moving(_ arrangement: HomeGridArrangement, resolved: [DockSlot],
                       fromOffsets: IndexSet, toOffset: Int) -> HomeGridArrangement {
        var next = materialised(arrangement, resolved: resolved)
        next.order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        return next
    }

    /// Nudge one slot by `delta` places, clamped to the ends. This is what the in-panel page offers
    /// instead of a drag: a drag inside a horizontally-paging panel is a gesture argument waiting
    /// to happen, and a pair of buttons is also the only form of reordering VoiceOver can drive.
    static func moving(_ arrangement: HomeGridArrangement, resolved: [DockSlot],
                       id: String, by delta: Int) -> HomeGridArrangement {
        var next = materialised(arrangement, resolved: resolved)
        guard let from = next.order.firstIndex(of: id) else { return next }
        let to = min(max(0, from + delta), next.order.count - 1)
        guard to != from else { return next }
        next.order.remove(at: from)
        next.order.insert(id, at: to)
        return next
    }

    /// Take slots off the grid. Controls are never removable, and that rule lives here rather than
    /// in one list's gesture configuration, so neither surface can forget it.
    static func removing(_ arrangement: HomeGridArrangement, resolved: [DockSlot],
                         ids: [String]) -> HomeGridArrangement {
        let removable = Set(resolved.filter(\.isHideable).map(\.id)).intersection(ids)
        guard !removable.isEmpty else { return materialised(arrangement, resolved: resolved) }
        var next = materialised(arrangement, resolved: resolved)
        next.order.removeAll { removable.contains($0) }
        next.hidden.append(contentsOf: removable.subtracting(next.hidden).sorted())
        return next
    }

    static func adding(_ arrangement: HomeGridArrangement, resolved: [DockSlot],
                       id: String) -> HomeGridArrangement {
        var next = materialised(arrangement, resolved: resolved)
        next.hidden.removeAll { $0 == id }
        if !next.order.contains(id) { next.order.append(id) }
        return next
    }
}
