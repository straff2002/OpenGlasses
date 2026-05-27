import Foundation

/// Listens for Darwin notifications posted by the widget when listening state changes.
/// Darwin notifications cross process boundaries, so this fires even when the app is in
/// the background (provided the app process is alive — which OpenGlasses is while glasses
/// are connected or while a Live Activity is active).
final class ListeningChangedObserver {
    static let shared = ListeningChangedObserver()
    private var started = false
    private var onChange: ((Bool) -> Void)?

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        guard !started else { return }
        started = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = SharedAppState.listeningChangedNotification as CFString
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<ListeningChangedObserver>.fromOpaque(observer).takeUnretainedValue()
                me.onChange?(SharedAppState.isListening)
            },
            name,
            nil,
            .deliverImmediately
        )
    }
}
