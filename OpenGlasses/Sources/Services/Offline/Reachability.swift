import Foundation
import Network

/// Network reachability as a `@Published isOnline`, plus an edge callback (Plan T). Wraps
/// `NWPathMonitor`, but exposes a `setOnline` seam so the offline/reconnect flow can be driven
/// deterministically in tests without a real network path.
@MainActor
final class Reachability: ObservableObject {
    @Published private(set) var isOnline: Bool

    /// Fired on every *change* with the new value. AppState/`SyncEngine` use the rising edge
    /// (false → true) to trigger a flush.
    var onChange: ((Bool) -> Void)?

    private let monitor: NWPathMonitor?

    /// - Parameters:
    ///   - startMonitoring: when false (tests), no real `NWPathMonitor` runs; drive with `setOnline`.
    ///   - initiallyOnline: the starting assumption before the first path update.
    init(startMonitoring: Bool = true, initiallyOnline: Bool = true) {
        self.isOnline = initiallyOnline
        self.monitor = startMonitoring ? NWPathMonitor() : nil
        if let monitor {
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor in self?.update(online) }
            }
            monitor.start(queue: DispatchQueue(label: "reachability", qos: .utility))
        }
    }

    deinit {
        monitor?.cancel()
    }

    /// Test / explicit seam: drive the online state directly.
    func setOnline(_ online: Bool) { update(online) }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
