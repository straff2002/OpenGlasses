import Foundation

// The glasses' connection, as facts the SDK reports rather than as a flag the app latches.
//
// Pure and SDK-free on purpose: `WearablesGlassesLinkSource` maps the Meta SDK's enums onto the
// ones below at the edge, so every rule here is decided — and tested — without `Wearables`.
//
// The bug this replaces: the app said "connected" whenever registration was complete or the SDK's
// device list was non-empty. Both describe a pair that has been *added* (registered with Meta AI,
// camera permission granted), not one that is reachable — a pair left in its case for days stayed
// "connected" the whole time. Only a device's own link state says the link is up.

/// Registration with Meta AI, reduced to what the connection phase needs.
enum GlassesRegistration: Equatable, Sendable {
    /// Unavailable or available — not registered (raw 0 or 1).
    case notRegistered
    /// A registration is in flight (raw 2).
    case registering
    /// Registered (raw 3 and up).
    case registered

    /// From `RegistrationState.rawValue` — the same raw numbering the rest of the app logs and
    /// compares (`RegistrationFlow.isRegistered`).
    init(stateRaw: Int) {
        switch stateRaw {
        case 3...: self = .registered
        case 2: self = .registering
        default: self = .notRegistered
        }
    }
}

/// One device's link to the phone — the SDK's `LinkState`.
enum GlassesLinkState: Equatable, Sendable {
    case disconnected, connecting, connected
}

/// The SDK's `ChargingState`.
enum GlassesChargingState: Equatable, Sendable {
    case unknown, charging, notCharging
}

/// How hot the glasses say they are: the SDK's `ThermalLevel`, coolest first. Its `.unknown` is
/// not a case here; a device that does not say is nil wherever this is read.
enum GlassesThermal: Equatable, Sendable, CaseIterable {
    /// No thermal pressure. The SDK calls this `.none`, which on an optional reads as nil.
    case normal
    case light, moderate, severe, critical, emergency, shutdown
}

/// Whether the glasses and this build of the app can work together: the SDK's `Compatibility`.
enum GlassesCompatibility: Equatable, Sendable, CaseIterable {
    /// The glasses have not said. Also what a value this build does not know reads as.
    case undefined
    case compatible
    /// The glasses' own software is too old for this build.
    case deviceUpdateRequired
    /// This build is too old for the glasses.
    case sdkUpdateRequired
}

/// What the SDK last reported about one device (`DeviceState`), as far as the app reads it.
struct GlassesDeviceState: Equatable, Sendable {
    var link: GlassesLinkState = .disconnected
    /// Percent, when the device reports one.
    var batteryLevel: Int?
    var charging: GlassesChargingState = .unknown
    /// On the face (`DonState.donned`) — true; taken off (`.doffed`) — false; nil when the
    /// device does not say (`.unknown`).
    var worn: Bool?
    /// Nil when the device does not say (`ThermalLevel.unknown`).
    var thermal: GlassesThermal?
    var compatibility: GlassesCompatibility = .undefined
}

/// The app's one answer to "are the glasses connected?".
enum GlassesConnectionPhase: Equatable, Sendable {
    /// Not registered and no device listed: this person has not added glasses (or removed them).
    case noGlassesAdded
    /// Glasses are added — registered, or listed by the SDK — but no link is up: in the case,
    /// switched off, out of range.
    case addedDisconnected
    /// A link is coming up. Not connected: nothing that needs the glasses can run yet.
    case connecting
    /// A device's link is up.
    case connected

    /// The only phase in which the glasses can be used.
    var isConnected: Bool { self == .connected }

    var isConnecting: Bool { self == .connecting }

    /// Whether glasses are part of this person's setup at all, reachable or not.
    var glassesAdded: Bool { self != .noGlassesAdded }

    /// The short status line `GlassesConnectionService.connectionStatus` carries when the phase
    /// changes. "Not connected" is the wording the session card maps to its own headline.
    func statusText(deviceName: String?) -> String {
        switch self {
        case .noGlassesAdded, .addedDisconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected to \(deviceName ?? "glasses")"
        }
    }
}

/// Everything the SDK has told the app about the glasses, and the phase that follows from it.
///
/// A value type driven by events, so the whole mapping is a deterministic fold:
/// registration × device list × per-device state → phase, active device, live battery.
///
/// **Multi-device rule.** Connected when *any* listed device's link is connected; connecting when
/// none is connected and any is connecting. The device the app describes (name, battery) is the
/// first connected device in the SDK's list order, else the first connecting one, else the first
/// listed. The camera session picks its device with `AutoDeviceSelector`, which also chooses among
/// the SDK's devices, so "connected" here does not name a pair the camera could not reach.
///
/// **Registration.** Registration (or a listed device) makes glasses *added*; it never makes them
/// connected. With devices listed, the phase follows their links even if the registration flag
/// reads below registered: unregistering is what empties the SDK's device list, so a revoked
/// registration reaches the phase through that list, while registration has been seen bouncing
/// through lower states during a healthy session — gating the link on it would flap the
/// connection and tear down audio for nothing.
struct GlassesConnectionSnapshot: Equatable, Sendable {
    var registration: GlassesRegistration = .notRegistered
    /// The SDK's device list, in its order.
    private(set) var deviceIds: [String] = []
    /// Last reported state per listed device. A device listed but not yet reported is disconnected.
    private(set) var deviceStates: [String: GlassesDeviceState] = [:]
    private(set) var deviceNames: [String: String] = [:]
    /// What `liveWorn` read the last time the link was up, kept after it drops. Not a live
    /// reading and never shown: it is how the moment of a link loss can still ask whether the
    /// glasses had been taken off (`GlassesLinkCuePolicy`), when `liveWorn` is by then nil.
    private(set) var lastLiveWorn: Bool?

    enum Event: Equatable, Sendable {
        case registration(GlassesRegistration)
        case devices([String])
        case deviceState(id: String, GlassesDeviceState)
        case deviceName(id: String, String?)
    }

    init(registration: GlassesRegistration = .notRegistered) {
        self.registration = registration
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .registration(let registration):
            self.registration = registration
        case .devices(let ids):
            // De-duplicated, order kept. A device that left the list takes its state and name with
            // it, so a pair removed while connected cannot keep the link up from memory.
            var seen = Set<String>()
            deviceIds = ids.filter { seen.insert($0).inserted }
            deviceStates = deviceStates.filter { seen.contains($0.key) }
            deviceNames = deviceNames.filter { seen.contains($0.key) }
        case .deviceState(let id, let state):
            // A late report for a device no longer listed (its listener was cancelled but had
            // already fired) must not resurrect it.
            guard deviceIds.contains(id) else { return }
            deviceStates[id] = state
        case .deviceName(let id, let name):
            guard deviceIds.contains(id) else { return }
            deviceNames[id] = name
        }
        // Follows the live reading while the link is up (including back to "does not say"), and
        // stops following the moment it is not.
        if phase == .connected { lastLiveWorn = liveWorn }
    }

    func state(of id: String) -> GlassesDeviceState {
        deviceStates[id] ?? GlassesDeviceState()
    }

    var phase: GlassesConnectionPhase {
        if deviceIds.isEmpty {
            return registration == .registered ? .addedDisconnected : .noGlassesAdded
        }
        let links = deviceIds.map { state(of: $0).link }
        if links.contains(.connected) { return .connected }
        if links.contains(.connecting) { return .connecting }
        return .addedDisconnected
    }

    /// The device the app describes. See the multi-device rule above.
    var activeDeviceId: String? {
        deviceIds.first { state(of: $0).link == .connected }
            ?? deviceIds.first { state(of: $0).link == .connecting }
            ?? deviceIds.first
    }

    var activeDeviceName: String? {
        activeDeviceId.flatMap { deviceNames[$0] }
    }

    /// Battery shown as live only while the link is up. A pair in its case reports nothing new,
    /// and a percentage from days ago presented beside the device is the same lie as "connected" —
    /// so it is hidden, not shown as last known.
    var liveBatteryLevel: Int? {
        guard phase == .connected, let id = activeDeviceId else { return nil }
        return state(of: id).batteryLevel
    }

    /// Worn, under the same rule: only while connected — a pair that is away is not "worn" by
    /// anything the app can see — else nil (unknown).
    var liveWorn: Bool? {
        guard phase == .connected, let id = activeDeviceId else { return nil }
        return state(of: id).worn
    }

    /// Charging, under the same rule as the battery: only while connected, else unknown.
    var liveCharging: GlassesChargingState {
        guard phase == .connected, let id = activeDeviceId else { return .unknown }
        return state(of: id).charging
    }

    /// Thermal level, under the same rule: only while connected. Glasses that were hot when they
    /// went into their case are not hot by anything the app can still see, and a posture held down
    /// by that reading would never lift.
    var liveThermal: GlassesThermal? {
        guard phase == .connected, let id = activeDeviceId else { return nil }
        return state(of: id).thermal
    }

    /// Compatibility, under the same rule: only while connected, else nil. `.undefined` is the
    /// glasses not having said; nil is there being no glasses to ask.
    var liveCompatibility: GlassesCompatibility? {
        guard phase == .connected, let id = activeDeviceId else { return nil }
        return state(of: id).compatibility
    }
}

/// The SDK's link × a stand-down → whether the app may use the glasses now.
///
/// The link is the SDK's truth and stays it: the app cannot drop it (the SDK has no app-side
/// disconnect), so standing down from the glasses is kept separately and the two are folded here.
/// A stand-down has a reason — the wearer's Disconnect, or the app's own (`GlassesSleepPolicy`:
/// taken off, or silent too long) — and the reason decides what lifts it. Rules:
/// - In use only when the link is connected and the app is not stood down.
/// - Standing down takes effect only while the link is connected; otherwise it is a no-op.
/// - An explicit connect (`resume()`) lifts either kind.
/// - Putting the glasses on (`donned()`) lifts an automatic stand-down only. The wearer's own
///   Disconnect is theirs to undo.
/// - The link leaving `.connected` (case, off, out of range, or merely reconnecting) clears either
///   kind, so the next real connection is live again without a tap.
struct GlassesUse: Equatable, Sendable {
    enum StandDownReason: Equatable, Sendable {
        /// Disconnect: the hero pill, the dock tile, Siri, the watch, the deep link.
        case user
        /// The app's own: glasses taken off, or silent past auto-sleep.
        case automatic
    }

    private(set) var link: GlassesConnectionPhase = .noGlassesAdded
    private(set) var standDownReason: StandDownReason?

    var stoodDown: Bool { standDownReason != nil }

    /// Whether the app may use the glasses now — what `AppState.isConnected` reports.
    var inUse: Bool { link.isConnected && !stoodDown }

    /// Connected, but stood down.
    var isPaused: Bool { link.isConnected && stoodDown }

    /// Whether voice may open a microphone on its own (wake word, re-arm, unmute). Phone-first:
    /// the phone's mic is always there, so glasses being away never closes it — only a stand-down
    /// does, until it is lifted or the glasses go away.
    var voiceInputAvailable: Bool { !stoodDown }

    mutating func linkChanged(_ phase: GlassesConnectionPhase) {
        link = phase
        if !phase.isConnected { standDownReason = nil }
    }

    /// Stand down. A user stand-down replaces an automatic one (it is the stronger request); an
    /// automatic one never downgrades the wearer's.
    mutating func standDown(_ reason: StandDownReason = .user) {
        guard link.isConnected else { return }
        if standDownReason == .user { return }
        standDownReason = reason
    }

    mutating func resume() {
        standDownReason = nil
    }

    /// The glasses were put on: an automatic stand-down lifts; the wearer's own does not.
    mutating func donned() {
        if standDownReason == .automatic { standDownReason = nil }
    }
}

/// When the app stands down from idle glasses on its own, and when it comes back.
///
/// An automatic stand-down exists only to release the expensive thing: the always-on wake-word
/// listener **holding the glasses' hands-free mic** open. The link itself costs the app nothing.
/// Since Plan GU the idle listener waits on the phone's own mic by default (`WakeListenPolicy`),
/// so in the default setup there is nothing on the glasses to release, and none of the rules
/// below run (Greig, 2026-10-01: glasses off the face with the link up keep the wake word
/// listening on the phone, replies to the phone speaker). The wearer's own Disconnect still
/// closes voice input — that is `GlassesUse`, not this policy.
///
/// The rules, all gated on `holdsGlassesMic`:
/// 0. **The idle listener is not on the glasses' mic** — listening off, push-to-talk, or idle
///    listening on the iPhone (the default) → nothing sleeps: no silence countdown, no doff
///    stand-down. The app stays connected and talking is instant.
/// 1. **Taken off** (doffed) with the link up → stand down automatically after
///    `doffGraceSeconds`; put back on within the grace, nothing happens.
/// 2. **Put back on** after an automatic stand-down → resume at once, no tap (`GlassesUse.donned()`).
///    The wearer's own Disconnect is never undone this way.
/// 3. **Worn** → never sleeps for silence, unless the wearer turned on "Sleep when quiet, even
///    while worn"; then the silence rule applies while worn too. That stand-down is automatic, so
///    it lifts on the next don, a link change, or an explicit connect — not on speech.
/// 4. **Worn state unknown** (the device does not report it) → the silence rule, as before.
/// 5. **In the case, off, out of range** → the link drops; there is nothing to time.
enum GlassesSleepPolicy {
    /// How long glasses may be off the face, link still up, before the app stands down.
    static let doffGraceSeconds: TimeInterval = 30

    /// Whether the always-on wake-word listener runs by design: listening on, and not
    /// push-to-talk — the same two settings `WakeAutoRestartPolicy` reads before a mute.
    static func alwaysOnListening(listeningEnabled: Bool, silentMode: Bool) -> Bool {
        listeningEnabled && !silentMode
    }

    /// Whether the always-on listener holds the glasses' own mic open: it runs, and its idle plan
    /// is the glasses' hands-free mic (`IdleAudioPlan.holdsGlassesMic` — "Same as Microphone" with
    /// the glasses as the Microphone, or a consumer that wants the wearer's voice).
    static func holdsGlassesMic(alwaysOnListening: Bool, idleListensOnGlasses: Bool) -> Bool {
        alwaysOnListening && idleListensOnGlasses
    }

    /// Whether glasses taken off should start (or, at its end, complete) the grace towards a stand-down.
    static func doffGraceApplies(holdsGlassesMic: Bool, worn: Bool?, inUse: Bool) -> Bool {
        holdsGlassesMic && worn == false && inUse
    }

    /// Whether the silence rule covers these glasses: always unless they are worn, and while worn
    /// only with the wearer's option on.
    static func silenceRuleApplies(worn: Bool?, sleepWhenQuietWhileWorn: Bool) -> Bool {
        worn != true || sleepWhenQuietWhileWorn
    }

    /// Whether to start the silence countdown when the glasses go idle.
    static func shouldArmSilenceSleep(holdsGlassesMic: Bool, autoSleepMinutes: Int, worn: Bool?,
                                      sleepWhenQuietWhileWorn: Bool) -> Bool {
        holdsGlassesMic && autoSleepMinutes > 0
            && silenceRuleApplies(worn: worn, sleepWhenQuietWhileWorn: sleepWhenQuietWhileWorn)
    }

    /// Re-checked when the silence countdown ends: they may have put the glasses on, or switched
    /// listening off, during it.
    static func silenceSleepFires(holdsGlassesMic: Bool, idle: Bool, inUse: Bool, worn: Bool?,
                                  sleepWhenQuietWhileWorn: Bool) -> Bool {
        holdsGlassesMic && idle && inUse
            && silenceRuleApplies(worn: worn, sleepWhenQuietWhileWorn: sleepWhenQuietWhileWorn)
    }
}

/// Whether the glasses' arrival may take the audio session over now.
///
/// When the glasses become usable the app hands audio and the wake word to them: it
/// reconfigures the session onto their microphone and restarts the listener. That reconfigure is
/// a session-wide change, and device-traced it landed 2.5 s into the very turn that brought the
/// glasses back (a "Resume & Talk" tap) — the dictation already running on the glasses mic was
/// cut off and heard nothing. The hand-off is for an idle app; a turn in progress owns the audio
/// and has already chosen its input.
enum GlassesAudioHandoffPolicy {
    static func mayHandOff(inConversation: Bool, isListening: Bool,
                           isProcessing: Bool, isSpeaking: Bool) -> Bool {
        !inConversation && !isListening && !isProcessing && !isSpeaking
    }
}
