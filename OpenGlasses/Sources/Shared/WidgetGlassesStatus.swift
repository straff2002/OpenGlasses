import Foundation

// The glasses' state as the Home Screen widget shows it — shared by the app, which writes it, the
// widget extension, which reads and draws it, and the app's tests, which hold the wording and the
// stale rule. Foundation only: the extension compiles this file and none of the app's types, so
// the app's `GlassesConnectionPhase` is mirrored here as a plain string enum.

/// What the app last knew about the glasses, written to the App Group for the Home Screen widget.
///
/// Battery and charging are only ever a live reading (the app's rule: battery only while
/// connected, never a remembered figure), and `writtenAt` lets the widget stop claiming a live
/// state that the app has not confirmed for a while — the app may since have been killed.
struct WidgetGlassesSnapshot: Codable, Equatable, Sendable {
    /// **Storage key.** The App Group defaults entry the snapshot lives under. Shared between the
    /// app and the widget extension; renaming it strands the widget on its last snapshot. Pinned
    /// by `StorageIdentifierGuardTests`.
    static let storageKey = "widgetGlassesSnapshot"
    /// **Stored identifier.** The Home Screen widget's kind: placed widgets are kept by it, and the
    /// app reloads that widget's timeline by it. Pinned by `StorageIdentifierGuardTests`.
    static let homeWidgetKind = "OpenGlassesHomeWidget"

    /// `GlassesConnectionPhase`, by case name.
    enum Phase: String, Codable, Sendable, CaseIterable {
        case noGlassesAdded
        case addedDisconnected
        case connecting
        case connected

        /// A phase that claims the glasses are there right now, and so goes stale.
        var claimsLiveLink: Bool { self == .connected || self == .connecting }

        /// A phase this build does not know (written by a newer one) reads as "not connected": it
        /// claims nothing live, and a snapshot that fails to decode would show nothing at all.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Phase(rawValue: raw) ?? .addedDisconnected
        }
    }

    var phase: Phase
    /// The link is up but the app has stopped using the glasses (the wearer's Disconnect, or the
    /// automatic stand-down). Only meaningful with `.connected`.
    var stoodDown: Bool
    /// Only while connected or connecting.
    var deviceName: String?
    /// Percent. Only while connected; never a remembered value.
    var battery: Int?
    /// Only while connected.
    var charging: Bool
    var writtenAt: Date

    init(phase: Phase, stoodDown: Bool = false, deviceName: String? = nil, battery: Int? = nil,
         charging: Bool = false, writtenAt: Date) {
        self.phase = phase
        self.stoodDown = stoodDown
        self.deviceName = deviceName
        self.battery = battery
        self.charging = charging
        self.writtenAt = writtenAt
    }

    private enum CodingKeys: String, CodingKey {
        case phase, stoodDown, deviceName, battery, charging, writtenAt
    }

    /// Tolerant of missing fields, so a snapshot written by another build still decodes. Only the
    /// phase and the time are required — without them there is nothing honest to show.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(Phase.self, forKey: .phase)
        stoodDown = try container.decodeIfPresent(Bool.self, forKey: .stoodDown) ?? false
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        battery = try container.decodeIfPresent(Int.self, forKey: .battery)
        charging = try container.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        writtenAt = try container.decode(Date.self, forKey: .writtenAt)
    }

    /// Whether a new reading says anything the widget should be reloaded for. Phase, paused,
    /// name and charging count at once; the battery counts only in steps
    /// (`WidgetGlassesPresentation.batteryStepMatters`), because every reload spends WidgetKit's
    /// daily budget and a worn pair loses a point every few minutes. `writtenAt` never counts.
    func differsForWidget(from written: WidgetGlassesSnapshot) -> Bool {
        phase != written.phase || stoodDown != written.stoodDown || deviceName != written.deviceName
            || charging != written.charging
            || WidgetGlassesPresentation.batteryStepMatters(from: written.battery, to: battery)
    }

    // MARK: - App Group storage

    static func load(from defaults: UserDefaults) -> WidgetGlassesSnapshot? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetGlassesSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Whether the app that owns the widget offers glasses at all (Plan JE: the App Store copy does
/// not). The app writes it when its services start; the widget reads it and draws no glasses line
/// without it. Absent reads as not offered, so a store copy's widget never shows a line the app
/// cannot explain, and a TestFlight copy's shows one from the app's first launch after the update.
enum WidgetGlassesSupport {
    /// **Storage key.** Shared between the app and the widget extension. Pinned by
    /// `StorageIdentifierGuardTests`.
    static let storageKey = "widgetGlassesSupported"

    static func read(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? false
    }

    /// Writes the value and reports whether it changed, so the caller reloads the widget only then.
    @discardableResult
    static func write(_ supported: Bool, to defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: storageKey) as? Bool != supported else { return false }
        defaults.set(supported, forKey: storageKey)
        return true
    }
}

/// One glasses line on the widget: the words, a symbol, how loudly to show it, and the battery
/// when there is a live one.
struct WidgetGlassesLine: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// Connected and in use: the accent.
        case connected
        /// Everything else.
        case neutral
    }

    let text: String
    /// An SF Symbol name.
    let symbol: String
    let tone: Tone
    /// "72%", only for a live connected reading.
    let batteryText: String?
    /// Only for a live connected reading.
    let charging: Bool
    /// Only while the snapshot is live and the link connected or connecting.
    let deviceName: String?
    /// The whole row as one VoiceOver element.
    let accessibilityLabel: String

    /// Whether glasses-only actions (Photo) can run now. Paused glasses cannot.
    var glassesUsable: Bool { tone == .connected }
}

/// Decides what the widget says about the glasses. Pure, so the wording and the stale rule are
/// tested headless; the widget only draws the result.
enum WidgetGlassesPresentation {
    /// How long a connected or connecting snapshot is believed. A widget renders out of process and
    /// cannot tell a quiet app from a killed one, so after this it says when the glasses were last
    /// seen instead. The app re-stamps a live snapshot inside it (`restampAfter`).
    ///
    /// Sized against WidgetKit's reload budget (a few dozen a day for an app in the background,
    /// which this one mostly is): a re-stamp is a reload, so it cannot come every few minutes.
    static let staleAfter: TimeInterval = 45 * 60
    /// How old an unchanged live snapshot gets before a running app re-confirms it, so a quiet but
    /// alive app is not shown as gone. At most two reloads an hour, and only when nothing else
    /// was written in the meantime.
    static let restampAfter: TimeInterval = 30 * 60
    /// How often a running app checks whether a re-stamp is due. A snapshot is therefore
    /// re-stamped by `restampAfter + restampCheckInterval` (40 min) at the latest, strictly inside
    /// `staleAfter`.
    static let restampCheckInterval: TimeInterval = 10 * 60

    /// A battery change smaller than this, crossing no threshold, is not worth a reload.
    static let batteryStep = 5
    /// Levels a wearer cares about crossing, in either direction, whatever the step.
    static let batteryThresholds = [20, 10]

    /// Whether a battery reading differs enough from the one last written to reload the widget:
    /// appearing or disappearing, moving by `batteryStep` or more, or crossing a threshold. The
    /// widget shows the value as written, so it may trail the glasses by a few points.
    static func batteryStepMatters(from written: Int?, to reading: Int?) -> Bool {
        switch (written, reading) {
        case (nil, nil):
            return false
        case let (old?, new?):
            if abs(new - old) >= batteryStep { return true }
            return batteryThresholds.contains { (old < $0) != (new < $0) }
        default:
            return true
        }
    }

    static func isStale(_ snapshot: WidgetGlassesSnapshot, now: Date) -> Bool {
        snapshot.phase.claimsLiveLink && now.timeIntervalSince(snapshot.writtenAt) >= staleAfter
    }

    /// - Parameter glassesEverAdded: only read when nothing has been written yet.
    static func render(snapshot: WidgetGlassesSnapshot?, now: Date,
                       glassesEverAdded: Bool) -> WidgetGlassesLine {
        guard let snapshot else {
            return glassesEverAdded ? notConnected : notAdded
        }
        if isStale(snapshot, now: now) {
            let time = snapshot.writtenAt.formatted(date: .omitted, time: .shortened)
            return WidgetGlassesLine(text: String(localized: "Last seen connected \(time)"), symbol: "clock",
                                     tone: .neutral, batteryText: nil, charging: false,
                                     deviceName: nil,
                                     accessibilityLabel: String(localized: "Glasses last seen connected at \(time)"))
        }
        switch snapshot.phase {
        case .noGlassesAdded:
            return notAdded
        case .addedDisconnected:
            return notConnected
        case .connecting:
            return WidgetGlassesLine(text: String(localized: "Connecting…"), symbol: "eyeglasses", tone: .neutral,
                                     batteryText: nil, charging: false,
                                     deviceName: snapshot.deviceName,
                                     accessibilityLabel: String(localized: "Glasses connecting"))
        case .connected where snapshot.stoodDown:
            return WidgetGlassesLine(text: String(localized: "Glasses paused"), symbol: "pause.circle", tone: .neutral,
                                     batteryText: nil, charging: false,
                                     deviceName: snapshot.deviceName,
                                     accessibilityLabel: String(localized: "Glasses paused"))
        case .connected:
            let batteryText = snapshot.battery.map { "\($0)%" }
            var label = String(localized: "Glasses connected")
            if let batteryText { label += String(localized: ", battery \(batteryText)") }
            if snapshot.charging { label += String(localized: ", charging") }
            return WidgetGlassesLine(text: String(localized: "Connected"), symbol: "eyeglasses", tone: .connected,
                                     batteryText: batteryText, charging: snapshot.charging,
                                     deviceName: snapshot.deviceName, accessibilityLabel: label)
        }
    }

    /// When the widget's timeline must change by itself: now, and — for a live snapshot not yet
    /// stale — the moment it goes stale. The app's next write replaces both.
    static func entryDates(for snapshot: WidgetGlassesSnapshot?, now: Date) -> [Date] {
        guard let snapshot, snapshot.phase.claimsLiveLink else { return [now] }
        let staleAt = snapshot.writtenAt.addingTimeInterval(staleAfter)
        return staleAt > now ? [now, staleAt] : [now]
    }

    private static let notAdded = WidgetGlassesLine(
        text: String(localized: "No glasses added"), symbol: "eyeglasses", tone: .neutral, batteryText: nil,
        charging: false, deviceName: nil, accessibilityLabel: String(localized: "No glasses added"))
    private static let notConnected = WidgetGlassesLine(
        text: String(localized: "Glasses not connected"), symbol: "eyeglasses", tone: .neutral, batteryText: nil,
        charging: false, deviceName: nil, accessibilityLabel: String(localized: "Glasses not connected"))
}
