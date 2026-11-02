import Foundation

/// Validate before creating a connection, using the same rules for setup and broadcasting.
struct BroadcastDestination {
    let url: String
    let streamKey: String

    init(rtmpURL: String, streamKey: String) throws {
        let url = rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !key.isEmpty else { throw BroadcastError.notConfigured }
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              ["rtmp", "rtmps"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw BroadcastError.invalidURL
        }
        self.url = url
        self.streamKey = key
    }
}

enum BroadcastError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case connectionFailed
    /// Plan KH: the phone camera was asked for while Blur Bystander Faces is on.
    case phoneCameraNotBlurred
    /// Plan KH: a stream was asked for in Medical Compliance mode.
    case blockedByMedicalCompliance

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Live streaming isn't set up. Add your platform's RTMP URL and stream key in Settings → Devices & Privacy → Camera, Recording & Streaming → Live Streaming.")
        case .invalidURL:
            return String(localized: "The streaming server address isn't valid. In Settings → Devices & Privacy → Camera, Recording & Streaming → Live Streaming, enter the RTMP URL from your platform. It must start with rtmp:// or rtmps:// and include a server address.")
        case .connectionFailed:
            return String(localized: "Couldn't connect to the streaming server. Check your internet connection, then check the RTMP URL and stream key in Settings → Devices & Privacy → Camera, Recording & Streaming → Live Streaming and try again.")
        case .phoneCameraNotBlurred:
            return String(localized: "Blur Bystander Faces doesn't cover the phone camera, so a stream can't use it while the blur is on.")
        case .blockedByMedicalCompliance:
            return BroadcastGoLive.medicalComplianceMessage
        }
    }
}
