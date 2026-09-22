import Foundation
import Network

/// Network reachability as a `@Published isOnline`, plus an edge callback (Plan T). Wraps
/// `NWPathMonitor`, but exposes a `setOnline` seam so the offline/reconnect flow can be driven
/// deterministically in tests without a real network path.
@MainActor
final class Reachability: ObservableObject {
    @Published private(set) var isOnline: Bool

    /// Whether the current path costs the wearer money — a cellular or personal-hotspot link.
    /// Read before a large, user-initiated download so the reader is told what they are about to
    /// spend (Plan FS §3), and driven directly in tests like `isOnline`.
    @Published private(set) var isExpensive = false

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
                let expensive = path.isExpensive
                Task { @MainActor in
                    self?.update(online)
                    self?.setExpensive(expensive)
                }
            }
            monitor.start(queue: DispatchQueue(label: "reachability", qos: .utility))
        }
    }

    deinit {
        monitor?.cancel()
    }

    /// Test / explicit seam: drive the online state directly.
    func setOnline(_ online: Bool) { update(online) }

    /// Test / explicit seam for the metered-connection flag.
    func setExpensive(_ expensive: Bool) {
        guard expensive != isExpensive else { return }
        isExpensive = expensive
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
