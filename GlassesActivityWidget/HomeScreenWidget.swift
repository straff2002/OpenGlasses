import WidgetKit
import SwiftUI

struct OpenGlassesHomeWidget: Widget {
    /// Stored identifier — placed widgets are kept by it. Shared with the app, which reloads this
    /// widget when the glasses change.
    let kind: String = WidgetGlassesSnapshot.homeWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeWidgetProvider()) { entry in
            HomeWidgetView(entry: entry)
                .containerBackground(AccentColors.widgetSurface, for: .widget)
        }
        .configurationDisplayName("Avenkin")
        // Static metadata, shown on every copy: a store copy offers no glasses (Plan JE).
        #if AVENKIN_PHONE_ONLY
        .description("A quick Listen toggle.")
        #else
        .description("A quick Listen toggle, and your glasses' connection and battery when you use them.")
        #endif
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct HomeWidgetEntry: TimelineEntry {
    let date: Date
    let isListening: Bool
    /// Nil on a copy that offers no glasses (Plan JE): the widget then draws no glasses line.
    let glasses: WidgetGlassesLine?
}

struct HomeWidgetProvider: TimelineProvider {
    /// Whether the app offers glasses at all, as it last wrote. Absent reads as not offered.
    private static var glassesSupported: Bool {
        WidgetGlassesSupport.read(from: SharedAppState.defaults)
    }

    /// The gallery and the placeholder show a connected pair, which is what the widget is for —
    /// on a copy that offers glasses. Without them it shows the Listen toggle alone.
    private static func sample(_ date: Date) -> HomeWidgetEntry {
        guard glassesSupported else { return HomeWidgetEntry(date: date, isListening: true, glasses: nil) }
        let snapshot = WidgetGlassesSnapshot(phase: .connected, battery: 72, writtenAt: date)
        return HomeWidgetEntry(date: date, isListening: true,
                               glasses: WidgetGlassesPresentation.render(snapshot: snapshot, now: date,
                                                                         glassesEverAdded: true))
    }

    /// The snapshot as the app last wrote it. Nothing written yet means the app has not run since
    /// the widget learned about glasses; the extension cannot read whether glasses were ever
    /// added, so that reads as "not added" until the app's first launch writes one.
    private static func entries(now: Date) -> [HomeWidgetEntry] {
        let listening = SharedAppState.isListening
        guard glassesSupported else { return [HomeWidgetEntry(date: now, isListening: listening, glasses: nil)] }
        let snapshot = WidgetGlassesSnapshot.load(from: SharedAppState.defaults)
        return WidgetGlassesPresentation.entryDates(for: snapshot, now: now).map { date in
            HomeWidgetEntry(date: date, isListening: listening,
                            glasses: WidgetGlassesPresentation.render(snapshot: snapshot, now: date,
                                                                      glassesEverAdded: false))
        }
    }

    func placeholder(in context: Context) -> HomeWidgetEntry {
        Self.sample(Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeWidgetEntry) -> Void) {
        let now = Date()
        completion(context.isPreview ? Self.sample(now) : Self.entries(now: now)[0])
    }

    /// The live entry now and, for a connected or connecting snapshot, the entry in which it goes
    /// stale — so a killed app never leaves "Connected" standing. The app reloads this timeline
    /// when the glasses change; the periodic refresh is for listening changes the app makes
    /// without reloading.
    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeWidgetEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: Self.entries(now: now), policy: .after(now.addingTimeInterval(60 * 15))))
    }
}

struct HomeWidgetView: View {
    let entry: HomeWidgetEntry
    @Environment(\.widgetFamily) private var family

    /// The brand orange. Filled controls paint it solid and label it with
    /// `AccentColors.onAiCoral` — the same rule as the app's primary button.
    private var accent: Color { AccentColors.aiCoral }

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemMedium: mediumView
        default: largeView
        }
    }

    private var glasses: WidgetGlassesLine? { entry.glasses }

    /// Photo is the glasses' camera when they are in use, and the phone's otherwise — dimmed, not
    /// hidden, for glasses that are added but away; full strength on a copy without glasses.
    private var photoOpacity: Double {
        guard let glasses else { return 1 }
        return glasses.glassesUsable ? 1 : 0.4
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LogoIcon(size: 24)
                    .foregroundStyle(accent)
                Spacer()
                statusDot
            }
            Spacer()
            Text("Avenkin")
                .font(.headline)
                .foregroundStyle(.primary)
            glassesLine(font: .caption)
            Button(intent: ToggleListeningIntent()) {
                HStack {
                    Image(systemName: entry.isListening ? "mic.slash.fill" : "mic.fill")
                    Text(entry.isListening ? "Stop" : "Listen")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(AccentColors.onAiCoral)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var mediumView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LogoIcon(size: 20)
                        .foregroundStyle(accent)
                    Text("Avenkin")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                HStack(spacing: 6) {
                    statusDot
                    glassesLine(font: .subheadline)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button(intent: ToggleListeningIntent()) {
                    VStack(spacing: 4) {
                        Image(systemName: entry.isListening ? "mic.slash.fill" : "mic.fill")
                            .font(.title3)
                        Text(entry.isListening ? "Stop" : "Listen")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AccentColors.onAiCoral)
                    .frame(width: 96, height: 70)
                    .background(accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                // Dimmed, not hidden, without glasses in use: the link still opens the app, which
                // says why there is no photo.
                Link(destination: DeepLinkTrust.signedURL("openglasses://action/photo")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                        Text("Photo")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 96, height: 30)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                }
                .opacity(photoOpacity)
            }
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LogoIcon(size: 28)
                    .foregroundStyle(accent)
                Text("Avenkin")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            if let glasses {
                HStack(spacing: 10) {
                    Image(systemName: glasses.symbol)
                        .font(.title3)
                        .foregroundStyle(glasses.tone == .connected ? accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(glasses.deviceName ?? "Glasses")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(glasses.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    batteryLabel(font: .subheadline.weight(.medium))
                    statusDot
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(glasses.accessibilityLabel)
            } else {
                HStack {
                    Spacer()
                    statusDot
                }
            }
            Spacer()
            Button(intent: ToggleListeningIntent()) {
                HStack {
                    Image(systemName: entry.isListening ? "mic.slash.fill" : "mic.fill")
                        .font(.title3)
                    Text(entry.isListening ? "Stop Listening" : "Start Listening")
                        .font(.headline)
                }
                .foregroundStyle(AccentColors.onAiCoral)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(accent, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                quickActionLink(url: "openglasses://action/ask", icon: "questionmark.circle.fill", label: "Ask")
                quickActionLink(url: "openglasses://action/photo", icon: "camera.fill", label: "Photo")
                    .opacity(photoOpacity)
                quickActionLink(url: "openglasses://action/describe", icon: "eye.fill", label: "Describe")
            }
        }
    }

    /// The glasses' state in one line — words, then the live battery — read by VoiceOver as one
    /// element. Nothing on a copy that offers no glasses.
    @ViewBuilder
    private func glassesLine(font: Font) -> some View {
        if let glasses {
            HStack(spacing: 4) {
                Text(glasses.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                batteryLabel(font: font)
            }
            .font(font)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(glasses.accessibilityLabel)
        }
    }

    /// "72%", with a bolt while charging. Nothing unless the reading is live.
    @ViewBuilder
    private func batteryLabel(font: Font) -> some View {
        if let glasses, glasses.batteryText != nil || glasses.charging {
            HStack(spacing: 2) {
                if glasses.charging {
                    Image(systemName: "bolt.fill")
                }
                if let battery = glasses.batteryText {
                    Text(battery)
                        .monospacedDigit()
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
        }
    }

    private func quickActionLink(url: String, icon: String, label: String) -> some View {
        Link(destination: DeepLinkTrust.signedURL(url)!) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Follows the glasses: the accent while connected and in use, neutral otherwise. Listening
    /// is shown by the Listen button's own state.
    private var statusDot: some View {
        Circle()
            .fill(glasses?.tone == .connected ? accent : Color.secondary)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.3), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
