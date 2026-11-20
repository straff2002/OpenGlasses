import Foundation

/// The phone's list of a session's last hints, newest first, with their passages (Plan MO §6). In
/// memory only: nothing here is written anywhere, and `clear()` at stop is the whole of its
/// lifecycle. The session screen (P2) shows it.
@MainActor
final class LiveHintsPhoneList: ObservableObject, HintPhoneListSink {
    @Published private(set) var hints: [LiveHint] = []

    init() {}

    func record(_ hint: LiveHint) {
        hints.removeAll { $0.id == hint.id }
        hints.insert(hint, at: 0)
        if hints.count > HintLimits.phoneListMax { hints.removeLast(hints.count - HintLimits.phoneListMax) }
    }

    func update(_ hint: LiveHint) {
        guard let index = hints.firstIndex(where: { $0.id == hint.id }) else { return }
        hints[index] = hint
    }

    func clear() {
        hints.removeAll()
    }
}
