import Foundation
import Combine

/// The one place a failure becomes visible.
///
/// Every subsystem posts here and the UI reads here, so a new failure path is visible by default
/// rather than only when someone remembers to wire a view to it. See `AppNotice` for the four bugs
/// that made the case for it.
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    /// What to show right now, or nil.
    @Published private(set) var current: AppNotice?

    private var notices: [AppNotice] = []
    private let now: () -> TimeInterval
    private var expiryTask: Task<Void, Never>?

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    func post(_ text: String, severity: AppNotice.Severity, source: AppNotice.Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // blank is not information
        let notice = AppNotice(text: trimmed, severity: severity, source: source, postedAt: now())
        notices = NoticePolicy.merge(notices, with: notice)
        recompute()
    }

    /// The source's condition has cleared — streaming resumed, the session connected.
    func clear(source: AppNotice.Source) {
        notices = NoticePolicy.clearing(notices, source: source)
        recompute()
    }

    /// The wearer dismissed what is on screen.
    func dismissCurrent() {
        guard let current else { return }
        notices.removeAll { $0.id == current.id }
        recompute()
    }

    private func recompute() {
        current = NoticePolicy.current(from: notices, now: now())
        scheduleExpiry()
    }

    /// Advisories expire on a timer, so one that nobody dismissed still goes away — otherwise the
    /// surface accumulates stale text and stops being worth reading.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let current, current.severity == .advisory else { return }
        let remaining = NoticePolicy.advisoryLifetime - (now() - current.postedAt)
        guard remaining > 0 else { return recompute() }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.recompute() }
        }
    }
}
