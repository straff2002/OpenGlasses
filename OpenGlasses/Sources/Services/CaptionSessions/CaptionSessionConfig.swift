import Foundation

/// **Keep caption sessions** (Plan KP §7, decision 7): off by default, and off — and unable to be
/// turned on — in Medical Compliance mode.
extension Config {

    static let keepCaptionSessionsKey = "keepCaptionSessions"

    /// Whether a captions or translation session is written to this phone when it stops. Reads
    /// false in Medical Compliance mode whatever was chosen before it.
    static var keepCaptionSessions: Bool {
        !hipaaMode && UserDefaults.standard.bool(forKey: keepCaptionSessionsKey)
    }

    /// The wearer's switch. Refused in Medical Compliance mode: there it stays off.
    @discardableResult
    static func setKeepCaptionSessions(_ enabled: Bool) -> Bool {
        let value = enabled && !hipaaMode
        UserDefaults.standard.set(value, forKey: keepCaptionSessionsKey)
        return value
    }

    /// Medical Compliance mode turning on: the switch goes off and stays off when the mode ends,
    /// until the wearer turns it on again.
    static func turnOffKeepCaptionSessionsForComplianceMode() {
        UserDefaults.standard.set(false, forKey: keepCaptionSessionsKey)
    }
}
