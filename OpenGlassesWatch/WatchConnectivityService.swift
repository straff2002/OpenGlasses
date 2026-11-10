import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit

/// **Storage key, not a product name.** The App Group suite name the watch app and its widget
/// read state through. A literal because this watch target compiles none of the phone's shared
/// files. **Never change this value** (including in a rename): whatever is stored under the suite
/// is stranded under the old name. Pinned by `StorageIdentifierGuardTests`.
private let appGroupId = "group.com.openglasses.app"

/// Watch-side WatchConnectivity service. Sends commands to the iPhone app
/// and receives status updates including persona list, conversations, and quick actions.
class WatchConnectivityService: NSObject, ObservableObject {
    @Published var isReachable = false
    @Published var isConnected = false
    @Published var isListening = false
    @Published var isRecording = false
    @Published var isVideoRecording = false
    @Published var isProcessing = false
    @Published var lastResponse = ""
    @Published var status = "idle"
    @Published var deviceName = ""
    @Published var batteryLevel: Int?
    @Published var personas: [PersonaInfo] = []
    @Published var accentColorName: String = "green"
    @Published var recentThreads: [ThreadInfo] = []
    @Published var quickActions: [QuickActionInfo] = []
    /// The open job, when there is one (Plan FO P3a). Read-only: the watch shows it and offers
    /// nothing to press, because starting, closing and answering are all decisions that belong
    /// where the question can actually be put.
    @Published var job: JobInfo?
    /// The map card the phone is showing on the wrist, and the live route (Plan GM). Nil when the
    /// phone sent none — an absent key clears it, as for `job`.
    @Published var surfaces: GlanceSurfaceSet?
    /// Bumped when a card the wearer asked to see arrives, for one tap on the wrist.
    @Published var surfaceTaps: Int = 0
    /// The card the last tap was for, so a repeat of the same context does not tap again.
    private var tappedSurfaceId: String?
    /// Today's calendar and weather as the phone resolved them (Plan KS). Nil when the phone sent
    /// none; the Today pages then say to open the app on the iPhone. Whether it is still today is
    /// the views' call, against the watch's own clock (`WatchTodayFreshness`).
    @Published var today: WatchTodayPayload?

    // Debounce: false→true immediately, true→false after 2 s
    private var reachabilityDebounceTask: Task<Void, Never>?

    /// A complication's command waiting for the phone, and who to tell how it went.
    private var pendingComplication: (request: PendingComplicationCommand, completion: (String?) -> Void)?
    private var pendingComplicationExpiry: Task<Void, Never>?

    struct PersonaInfo: Identifiable {
        let id: String
        let name: String
    }

    struct ThreadInfo: Identifiable {
        let id: String
        let title: String
        let summary: String
        let updatedAt: String
    }

    struct QuickActionInfo: Identifiable {
        let id: String
        let label: String
        let icon: String
        let type: String
    }

    /// The four strings the phone sends about the job in hand.
    struct JobInfo: Equatable {
        let jobNumber: String
        let state: String
        let unit: String
        let nextAction: String
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    // MARK: - Shared State (App Group)

    private func persistSharedState() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(isListening, forKey: "isListening")
        defaults.set(isRecording, forKey: "isRecording")
        defaults.set(isConnected, forKey: "isConnected")
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Reachability Debounce

    private func updateReachability(_ newValue: Bool) {
        if newValue {
            // Immediately go reachable
            reachabilityDebounceTask?.cancel()
            reachabilityDebounceTask = nil
            isReachable = true
        } else {
            // Debounce the false transition by 2 s
            reachabilityDebounceTask?.cancel()
            reachabilityDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.isReachable = false
            }
        }
    }

    // MARK: - Complication Commands

    /// Send the command a complication was tapped for.
    ///
    /// The tap usually launches the app, so the link gets here before the session with the phone
    /// is up. The command waits for it — for `PendingComplicationCommand.lifetime`, no longer —
    /// and is sent the moment the phone is reachable. `completion` gets nil when the phone took it.
    func runComplicationCommand(_ command: WatchComplicationLink.Command,
                                completion: @escaping (String?) -> Void) {
        pendingComplicationExpiry?.cancel()
        pendingComplication = nil

        if WCSession.default.activationState == .activated, WCSession.default.isReachable {
            sendCommand(command.rawValue, completion: completion)
            return
        }

        let pending = PendingComplicationCommand(command: command, requestedAt: Date())
        pendingComplication = (pending, completion)
        isProcessing = true
        pendingComplicationExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PendingComplicationCommand.lifetime * 1_000_000_000))
            guard let self, !Task.isCancelled, self.pendingComplication?.request == pending else { return }
            self.pendingComplication = nil
            self.isProcessing = false
            completion("iPhone not reachable")
        }
    }

    /// Send the waiting command, if there is one and the phone can now take it.
    private func flushPendingComplication() {
        guard let pending = pendingComplication, WCSession.default.isReachable else { return }
        pendingComplicationExpiry?.cancel()
        pendingComplication = nil
        guard pending.request.isLive(at: Date()) else {
            isProcessing = false
            pending.completion("iPhone not reachable")
            return
        }
        sendCommand(pending.request.command.rawValue, completion: pending.completion)
    }

    // MARK: - Send Commands

    func sendCommand(_ command: String, extra: [String: Any] = [:], completion: @escaping (String?) -> Void) {
        guard WCSession.default.isReachable else {
            completion("iPhone not reachable")
            return
        }

        isProcessing = true
        var message: [String: Any] = ["command": command]
        for (k, v) in extra { message[k] = v }

        WCSession.default.sendMessage(message, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                self?.isProcessing = false
                if let listening = reply["isListening"] as? Bool {
                    self?.isListening = listening
                    self?.persistSharedState()
                }
                if let recording = reply["isRecording"] as? Bool {
                    self?.isRecording = recording
                    self?.persistSharedState()
                }
                if let videoRecording = reply["isVideoRecording"] as? Bool {
                    self?.isVideoRecording = videoRecording
                }
                if let response = reply["response"] as? String {
                    self?.lastResponse = response
                    completion(nil)
                } else if let error = reply["error"] as? String {
                    completion(error)
                } else if let status = reply["status"] as? String {
                    self?.status = status
                    completion(nil)
                }
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.isProcessing = false
                completion(error.localizedDescription)
            }
        })
    }
}

// MARK: - Map cards (Plan GM)

extension WatchConnectivityService {
    /// Take the phone's `surfaces` value: decoded, with anything already expired dropped. Main
    /// queue only.
    fileprivate func applySurfaces(_ data: Data?) {
        guard let data, let decoded = GlanceSurfaceCodec.decode(data) else {
            surfaces = nil
            return
        }
        let live = decoded.live(at: Date())
        surfaces = live.isEmpty ? nil : live
        if live.playsTap, let id = live.current?.id, id != tappedSurfaceId {
            tappedSurfaceId = id
            surfaceTaps += 1
        }
    }

    /// **Go** on a card: the phone starts walking directions to the place (or the row's place).
    func startGuidance(surfaceId: String, placeId: String?, completion: @escaping (String?) -> Void) {
        var extra: [String: Any] = [GlanceWire.surfaceIdKey: surfaceId]
        if let placeId { extra[GlanceWire.placeIdKey] = placeId }
        sendCommand(GlanceWire.startGuidanceCommand, extra: extra, completion: completion)
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // The delegate is only told about a context that arrives while the app runs. The one the
        // phone sent while it was not is waiting here, and without it a fresh launch shows
        // nothing connected until the phone next has something to say.
        let lastContext = session.receivedApplicationContext
        DispatchQueue.main.async {
            if !lastContext.isEmpty { self.apply(lastContext) }
            self.updateReachability(session.isReachable)
            self.flushPendingComplication()
        }
    }

    // Required on iOS/simulator but unavailable on watchOS device SDK.
    #if !os(watchOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.updateReachability(session.isReachable)
            self.flushPendingComplication()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }

    /// A turn on the phone ended with the done tone instead of a spoken reply: one tap on the wrist.
    /// The phone's `QuietDoneWatchMessage` — this target compiles none of the phone's files.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["event"] as? String == "quietDone" else { return }
        DispatchQueue.main.async { WKInterfaceDevice.current().play(.success) }
    }

    /// Take the phone's status into the published state and the complications. Main queue only.
    private func apply(_ applicationContext: [String: Any]) {
        if let connected = applicationContext["isConnected"] as? Bool {
            self.isConnected = connected
        }
        if let listening = applicationContext["isListening"] as? Bool {
            self.isListening = listening
        }
        if let recording = applicationContext["isRecording"] as? Bool {
            self.isRecording = recording
        }
        if let videoRecording = applicationContext["isVideoRecording"] as? Bool {
            self.isVideoRecording = videoRecording
        }
        if let status = applicationContext["status"] as? String {
            self.status = status
        }
        // The status carries only the opening of the last answer. One already held in full, from a
        // command's own reply, is not replaced by its first lines.
        if let response = applicationContext["lastResponse"] as? String,
           !(lastResponse.count > response.count && lastResponse.hasPrefix(response)) {
            self.lastResponse = response
        }
        if let name = applicationContext["deviceName"] as? String {
            self.deviceName = name
        }
        if let battery = applicationContext["batteryLevel"] as? Int {
            self.batteryLevel = battery
        }
        if let accent = applicationContext["accentColor"] as? String {
            self.accentColorName = accent
        }
        // Parse persona list
        if let personaData = applicationContext["personas"] as? [[String: String]] {
            self.personas = personaData.compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return PersonaInfo(id: id, name: name)
            }
        }
        // Parse recent threads
        if let threadData = applicationContext["recentThreads"] as? [[String: String]] {
            self.recentThreads = threadData.compactMap { dict in
                guard let id = dict["id"], let title = dict["title"] else { return nil }
                return ThreadInfo(
                    id: id,
                    title: title,
                    summary: dict["summary"] ?? "",
                    updatedAt: dict["updatedAt"] ?? ""
                )
            }
        }
        // Parse quick actions
        if let actionData = applicationContext["quickActions"] as? [[String: String]] {
            self.quickActions = actionData.compactMap { dict in
                guard let id = dict["id"], let label = dict["label"] else { return nil }
                return QuickActionInfo(
                    id: id,
                    label: label,
                    icon: dict["icon"] ?? "star.fill",
                    type: dict["type"] ?? "prompt"
                )
            }
        }
        // The open job, or nothing. An absent key clears it: a finished job must not linger
        // on the wrist looking open.
        if let jobData = applicationContext["job"] as? [String: String],
           let number = jobData["jobNumber"] {
            self.job = JobInfo(jobNumber: number,
                               state: jobData["state"] ?? "",
                               unit: jobData["unit"] ?? "",
                               nextAction: jobData["nextAction"] ?? "")
        } else {
            self.job = nil
        }
        applySurfaces(applicationContext[GlanceWire.contextKey] as? Data)
        // An absent key clears it, as for `job` and `surfaces`.
        let todayValue = (applicationContext[WatchTodayWire.contextKey] as? Data).flatMap(WatchTodayCodec.decode)
        if todayValue != today { today = todayValue }
        // Persist to app group for complications
        self.persistSharedState()
    }
}
