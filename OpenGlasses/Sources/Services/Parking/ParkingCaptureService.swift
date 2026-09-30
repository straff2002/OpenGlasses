import Combine
import CoreLocation
import Foundation
import UserNotifications

/// Plan GH — the live edge of automatic parking capture: feeds CarPlay connect/disconnect, location
/// fixes and motion samples into `DriveEndDetector`, and files what it detects in `ParkingStore`.
///
/// Location strategy (decision 1, option b): last-known fix only. The app asks for nothing beyond
/// When-In-Use and has no `location` background mode, so an automatic spot is only as good as the
/// last fix the app received during the drive — the recall says how old it was. Motion history is
/// replayed from CoreMotion when the app becomes active, so a drive that ended while the app was
/// suspended is still noticed.
@MainActor
final class ParkingCaptureService {

    let store: ParkingStore
    private var detector: DriveEndDetector
    private var cancellables = Set<AnyCancellable>()
    private var walkTick: Task<Void, Never>?

    /// Wired by AppState.
    var speak: ((String) -> Void)?
    var notify: (String, String) -> Void = { title, body in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "parking.autoSaved", content: content, trigger: nil))
    }
    var now: () -> Date = Date.init
    var settings: () -> DriveEndDetector.Settings = { ParkingCaptureService.currentSettings }
    /// Motion history for the retrospective replay.
    var motionHistory: ((Date, Date) async -> [MotionSample])?

    init(store: ParkingStore) {
        self.store = store
        self.detector = DriveEndDetector(settings: .off)
    }

    static var currentSettings: DriveEndDetector.Settings {
        guard Config.parkingAutoSaveEnabled else { return .off }
        return DriveEndDetector.Settings(carPlayCapture: Config.parkingAutoSaveCarPlay,
                                         motionCapture: Config.parkingIDrive)
    }

    // MARK: - Wiring

    func attach(carPlay: Published<Bool>.Publisher, locations: Published<CLLocation?>.Publisher) {
        carPlay
            .removeDuplicates()
            .dropFirst()   // the initial `false` is not a disconnect
            .sink { [weak self] connected in self?.carPlay(connected: connected) }
            .store(in: &cancellables)
        locations
            .compactMap { $0 }
            .sink { [weak self] location in self?.feed(.fix(LocationFix(location))) }
            .store(in: &cancellables)
    }

    func carPlay(connected: Bool) {
        let at = now()
        feed(connected ? .carPlayConnected(at: at) : .carPlayDisconnected(at: at))
    }

    func motion(_ sample: MotionSample) {
        feed(.motion(sample))
    }

    /// Replay motion since `since` (capped at an hour) — called when the app becomes active.
    func replayMotionHistory(since: Date? = nil) async {
        guard settings().motionCapture, let motionHistory else { return }
        let end = now()
        let start = max(since ?? detector.lastMotionAt ?? end.addingTimeInterval(-3600),
                        end.addingTimeInterval(-3600))
        let samples = await motionHistory(start, end)
        for sample in samples { feed(.motion(sample)) }
        feed(.tick(at: end))
    }

    // MARK: - Detection

    private func feed(_ input: DriveEndDetector.Input) {
        detector.settings = settings()
        if let detection = detector.handle(input) {
            file(detection)
        }
        scheduleWalkTick()
    }

    private func scheduleWalkTick() {
        walkTick?.cancel()
        guard let due = detector.pendingWalkConfirmationAt else { return }
        let delay = max(0, due.timeIntervalSince(now())) + 1
        walkTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.feed(.tick(at: self.now()))
        }
    }

    private func file(_ detection: DriveEndDetector.Detection) {
        let at = now()
        guard let saved = store.saveAutomatic(detection.spot(savedAt: at), now: at) else {
            PrivacyLog.location(.parkingAutoKept)
            return
        }
        PrivacyLog.location(.parkingAutoSaved)
        let plan = ParkingAutoSaveAnnouncement.plan(for: saved.capture)
        if plan.notify {
            notify(ParkingAutoSaveAnnouncement.notificationTitle, ParkingAutoSaveAnnouncement.notificationBody)
        }
        if plan.speak { speak?(ParkingAutoSaveAnnouncement.spokenConfirmation) }
    }
}

// MARK: - Settings

extension Config {
    /// Master switch for automatic capture. Off by default: saving where somebody went without
    /// being asked is a decision they make, not one an update makes for them.
    static var parkingAutoSaveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "parkingAutoSaveEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "parkingAutoSaveEnabled") }
    }

    /// Save when CarPlay disconnects after a drive. On once automatic capture is on.
    static var parkingAutoSaveCarPlay: Bool {
        get { UserDefaults.standard.object(forKey: "parkingAutoSaveCarPlay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "parkingAutoSaveCarPlay") }
    }

    /// "I drive": save when motion goes from driving to walking. Off by default, because a
    /// passenger's phone sees the same pattern.
    static var parkingIDrive: Bool {
        get { UserDefaults.standard.object(forKey: "parkingIDrive") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "parkingIDrive") }
    }

    /// Keep the last ten spots rather than only the current one. Off by default.
    static var parkingKeepHistory: Bool {
        get { UserDefaults.standard.object(forKey: "parkingKeepHistory") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "parkingKeepHistory") }
    }
}
