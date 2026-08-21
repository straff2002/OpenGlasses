import AVFoundation

/// Where voice is captured (Plan CL P3). On Bluetooth this also moves TTS —
/// a hands-free (HFP) link is bidirectional, so the chosen device's speakers
/// carry the reply too.
///
/// The third option exists because on Display glasses the firmware puts its
/// call screen over the lens HUD whenever the GLASSES' hands-free link is the
/// active mic — mic and HUD fight. A headset's hands-free link does not touch
/// the lens: mic + voice in the ear, HUD free. The pocket setup.
enum MicRoute: String, CaseIterable, Identifiable {
    case phone
    case glasses
    case headset

    var id: String { rawValue }

    var label: String {
        switch self {
        case .phone: return "iPhone Mic"
        case .glasses: return "Glasses Mic"
        case .headset: return "Headset Mic (AirPods etc.)"
        }
    }

    /// Compact form for row values, where the caveat doesn't fit.
    var shortLabel: String {
        switch self {
        case .phone: return "iPhone"
        case .glasses: return "Glasses"
        case .headset: return "Headset"
        }
    }
}

/// Pure route → audio-session decisions, so the selection rules are unit-
/// testable without an `AVAudioSession`. `WakeWordService` applies them.
enum MicRoutePolicy {
    /// Port-name markers that identify a pair of glasses rather than earbuds.
    ///
    /// Plan CQ P0: this list is deliberately **data-only** so a newly supported device is a
    /// one-line addition, and deliberately **conservative** so it never claims a headset.
    /// A false positive here is not cosmetic — the `.headset` route skips anything that looks
    /// like glasses, so a mismatched pair of earbuds would silently stop being selectable, and
    /// the `.glasses` route would grab them instead. That is why the entries are distinctive
    /// brand or product tokens ("even g", "camera glasses") and never bare fragments like
    /// "even", "g2" or "cyan", which appear inside ordinary headset names.
    ///
    /// Non-Meta entries are **unverified against hardware** — they are the advertised names
    /// these devices are reported to use, and matching them only affects which route label the
    /// user sees and which port the route prefers.
    static let glassesNameMarkers = [
        // Meta's lineup.
        "meta", "ray-ban", "rayban", "oakley", "glasses",
        // Plan CQ Track B — the OEM capture-to-storage class, sold under many badges.
        // (Products literally named "Camera Glasses" are already caught by "glasses".)
        "anko", "heycyan",
        // Plan CQ Track A — developer camera glasses.
        "mentra",
        // Display-tier glasses (Plan AH and the wider display class).
        "even g", "vuzix",
    ]

    static func looksLikeGlasses(portName: String) -> Bool {
        let name = portName.lowercased()
        return glassesNameMarkers.contains { name.contains($0) }
    }

    /// Bluetooth-capable port types a mic can ride. On iOS 26 the glasses may
    /// surface as `.bluetoothLE` (LC3) rather than classic HFP, and some
    /// headsets report `.headsetMic`.
    static let bluetoothMicPorts: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothLE, .headsetMic]

    /// Category options per route. The phone route deliberately excludes
    /// every Bluetooth option — with them present, iOS re-routes input to
    /// the glasses on its own and the "phone mic" choice silently stops
    /// being true.
    static func categoryOptions(for route: MicRoute, mixWithOthers: Bool) -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if route != .phone {
            options.insert(.allowBluetoothHFP)
            options.insert(.allowBluetoothA2DP)
        }
        if mixWithOthers {
            options.insert(.mixWithOthers)
        }
        return options
    }

    /// Which of the session's available inputs to prefer, as an index into
    /// `ports` (nil = leave the system default alone).
    ///
    /// - glasses: the first Bluetooth port that looks like the glasses.
    /// - headset: the first Bluetooth port that does NOT look like the
    ///   glasses — and **never** the glasses as a fallback, since putting
    ///   their hands-free link live is exactly what resurfaces the call
    ///   screen this mode exists to avoid.
    /// - phone: nothing.
    static func preferredInputIndex(
        for route: MicRoute,
        ports: [(name: String, type: AVAudioSession.Port)]
    ) -> Int? {
        switch route {
        case .phone:
            return nil
        case .glasses:
            return ports.firstIndex { bluetoothMicPorts.contains($0.type) && looksLikeGlasses(portName: $0.name) }
        case .headset:
            return ports.firstIndex { bluetoothMicPorts.contains($0.type) && !looksLikeGlasses(portName: $0.name) }
        }
    }

    /// Which route the session's **live** input is on, given the ports it is currently routed to.
    ///
    /// The inverse of `preferredInputIndex`, and it exists because the two answers diverge
    /// routinely: `preferredInputIndex` returns nil when the preferred port isn't there, and
    /// `WakeWordService` then leaves capture on the phone while `Config.micRoute` still says
    /// `.glasses`. A preference is not an observation — glasses go flat, sleep, or wander out of
    /// range mid-session — and anything measuring the audio (Plan CU's cohorts, P2's acoustic
    /// thresholds) must be told which mic actually carried the words, or an 8 kHz HFP population
    /// and a 48 kHz phone-mic one end up in one bucket whose average describes neither.
    ///
    /// Classification mirrors `preferredInputIndex` exactly: a Bluetooth mic port whose name looks
    /// like glasses is `.glasses`, any other Bluetooth mic port is `.headset`, anything else is the
    /// phone. `nil` only for an empty list — a session with no input port has not been observed at
    /// all, and the caller should fall back rather than assert a route nobody saw.
    static func resolvedRoute(from ports: [(name: String, type: AVAudioSession.Port)]) -> MicRoute? {
        guard !ports.isEmpty else { return nil }
        if preferredInputIndex(for: .glasses, ports: ports) != nil { return .glasses }
        if preferredInputIndex(for: .headset, ports: ports) != nil { return .headset }
        return .phone
    }
}
