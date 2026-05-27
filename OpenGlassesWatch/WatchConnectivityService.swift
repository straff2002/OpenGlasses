import Foundation
import WatchConnectivity
import WidgetKit

private let appGroupId = "group.com.openglasses.app"

/// Watch-side WatchConnectivity service. Sends commands to the iPhone app
/// and receives status updates including persona list, conversations, and quick actions.
class WatchConnectivityService: NSObject, ObservableObject {
    @Published var isReachable = false
    @Published var isConnected = false
    @Published var isListening = false
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var lastResponse = ""
    @Published var status = "idle"
    @Published var deviceName = ""
    @Published var batteryLevel: Int?
    @Published var personas: [PersonaInfo] = []
    @Published var accentColorName: String = "green"
    @Published var recentThreads: [ThreadInfo] = []
    @Published var quickActions: [QuickActionInfo] = []

    // Debounce: false→true immediately, true→false after 2 s
    private var reachabilityDebounceTask: Task<Void, Never>?

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

// MARK: - WCSessionDelegate

extension WatchConnectivityService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.updateReachability(session.isReachable)
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
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            if let connected = applicationContext["isConnected"] as? Bool {
                self.isConnected = connected
            }
            if let listening = applicationContext["isListening"] as? Bool {
                self.isListening = listening
            }
            if let recording = applicationContext["isRecording"] as? Bool {
                self.isRecording = recording
            }
            if let status = applicationContext["status"] as? String {
                self.status = status
            }
            if let response = applicationContext["lastResponse"] as? String {
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
            // Persist to app group for complications
            self.persistSharedState()
        }
    }

    /// Handle transferUserInfo from complications (queued delivery, no reply handler).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = userInfo["command"] as? String else { return }
        // Re-route complication commands through the normal sendCommand path
        // but we can't get a reply from a transferUserInfo — fire and forget
        DispatchQueue.main.async {
            self.sendCommand(command) { _ in }
        }
    }
}
