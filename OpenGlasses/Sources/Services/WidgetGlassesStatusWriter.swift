import Foundation
import WidgetKit

/// Where the widget snapshot is kept. The App Group in the app; a fake in tests.
protocol WidgetGlassesSnapshotStoring: AnyObject {
    func write(_ snapshot: WidgetGlassesSnapshot)
}

/// Asks WidgetKit to redraw the Home Screen widget. WidgetKit budgets these, hence the seam.
protocol WidgetTimelineReloading: AnyObject {
    func reloadHomeWidget()
}

final class AppGroupWidgetGlassesStore: WidgetGlassesSnapshotStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = SharedAppState.defaults) { self.defaults = defaults }
    func write(_ snapshot: WidgetGlassesSnapshot) { snapshot.save(to: defaults) }
}

final class WidgetCenterReloader: WidgetTimelineReloading {
    /// **Stored identifier**, owned by `ListeningControlWidget.kind` in the widget extension (which
    /// the app does not compile). `ControlWidgetGuardTests` holds the two together.
    static let listeningControlKind = "com.openglasses.app.ListeningControl"

    func reloadHomeWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetGlassesSnapshot.homeWidgetKind)
    }

    /// Redraws everything that shows whether Avenkin is listening: the Home Screen widget's Listen
    /// button and the Control Center / Action button toggle. The app writes the shared flag when
    /// listening changes in the app, Settings, Siri or the session card; without this the widget
    /// kept its old button until its next scheduled refresh.
    func reloadListeningSurfaces() {
        reloadHomeWidget()
        ControlCenter.shared.reloadControls(ofKind: Self.listeningControlKind)
    }
}

extension WidgetGlassesSnapshot {
    /// The app's glasses state as the widget may show it. Each field is gated by the link here as
    /// well as in `GlassesConnectionService`, so the widget can never be handed a battery for
    /// glasses that are not connected.
    ///
    /// - Parameter glassesAdded: `AppState.glassesAdded` — glasses ever added. A link that reads
    ///   "never added" for someone who has added glasses (before the SDK reports, or after it
    ///   empties its list) is written as "not connected", as the app itself says.
    static func reading(link: GlassesConnectionPhase, stoodDown: Bool, glassesAdded: Bool,
                        deviceName: String?, battery: Int?, charging: Bool,
                        at date: Date) -> WidgetGlassesSnapshot {
        let phase: Phase
        switch link {
        case .noGlassesAdded: phase = glassesAdded ? .addedDisconnected : .noGlassesAdded
        case .addedDisconnected: phase = .addedDisconnected
        case .connecting: phase = .connecting
        case .connected: phase = .connected
        }
        let connected = link == .connected
        return WidgetGlassesSnapshot(phase: phase,
                                     stoodDown: connected && stoodDown,
                                     deviceName: phase.claimsLiveLink ? deviceName : nil,
                                     battery: connected ? battery : nil,
                                     charging: connected && charging,
                                     writtenAt: date)
    }
}

/// Keeps the widget's glasses snapshot current without spending WidgetKit's reload budget.
///
/// Anything that may have changed the glasses' state calls `setNeedsWrite()`. The first call opens
/// a short window; at its end the current reading is taken once and written — and the widget
/// reloaded — only when it says something new (`differsForWidget`). A burst of updates is
/// therefore one write and one reload, a call that changes nothing is neither, and the battery
/// counts only in steps of `batteryStep` points or across a threshold.
///
/// The budget this keeps to: WidgetKit allows an app in the background a few dozen reloads a
/// day. While glasses are connected that is at most two re-stamps an hour, and only in an hour
/// with nothing else to write, plus a battery step every few percent — about 20 over a full
/// charge — plus the connects, disconnects and stand-downs themselves.
///
/// The reading is taken at the end of the window, not when asked, because the service publishes
/// in `willSet`: a sink that read it back would read the value being replaced.
///
/// A live snapshot (connected or connecting) that has not changed is still re-stamped once it is
/// `restampAfter` old, so a quiet app that is still running is not shown as gone
/// (`WidgetGlassesPresentation.staleAfter`).
@MainActor
final class WidgetGlassesStatusWriter {
    /// Long enough to fold a connect's phase, name and battery into one write.
    nonisolated static let coalesceSeconds: TimeInterval = 1.5

    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    private let store: WidgetGlassesSnapshotStoring
    private let reloader: WidgetTimelineReloading
    private let now: () -> Date
    private let schedule: Scheduler
    private let currentReading: @MainActor (Date) -> WidgetGlassesSnapshot

    /// What was last written by this process. Nil at launch, so the first reading is always
    /// written: whatever the App Group holds was stamped by an earlier run.
    private(set) var lastWritten: WidgetGlassesSnapshot?
    private var flushScheduled = false

    init(store: WidgetGlassesSnapshotStoring,
         reloader: WidgetTimelineReloading,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping Scheduler = WidgetGlassesStatusWriter.mainQueueAfter,
         currentReading: @escaping @MainActor (Date) -> WidgetGlassesSnapshot) {
        self.store = store
        self.reloader = reloader
        self.now = now
        self.schedule = schedule
        self.currentReading = currentReading
    }

    nonisolated static func mainQueueAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }

    /// Something the widget shows may have changed.
    func setNeedsWrite() {
        guard !flushScheduled else { return }
        flushScheduled = true
        schedule(Self.coalesceSeconds) { [weak self] in self?.flush() }
    }

    /// Take the reading and write it if it says something new. Called at the end of the window.
    func flush() {
        flushScheduled = false
        let date = now()
        let reading = currentReading(date)
        guard Self.shouldWrite(reading, over: lastWritten, now: date) else { return }
        store.write(reading)
        lastWritten = reading
        reloader.reloadHomeWidget()
    }

    /// Write when nothing has been written by this process, when the reading differs from the
    /// last write in a way the widget should show, or when a live reading is due its re-stamp.
    nonisolated static func shouldWrite(_ reading: WidgetGlassesSnapshot,
                                        over last: WidgetGlassesSnapshot?, now: Date) -> Bool {
        guard let last else { return true }
        if reading.differsForWidget(from: last) { return true }
        return reading.phase.claimsLiveLink
            && now.timeIntervalSince(last.writtenAt) >= WidgetGlassesPresentation.restampAfter
    }
}
