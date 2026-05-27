import WidgetKit
import SwiftUI

struct OpenGlassesHomeWidget: Widget {
    let kind: String = "OpenGlassesHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeWidgetProvider()) { entry in
            HomeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    HomeWidgetBackground()
                }
        }
        .configurationDisplayName("OpenGlasses")
        .description("Glasses status and a quick Listen toggle.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Adaptive widget background — warm tinted gradient that switches with the
/// system appearance. Dark mode keeps the original coffee tones; light mode
/// uses a soft cream that lets `.primary` text stay legible.
private struct HomeWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.14, green: 0.09, blue: 0.07),
                   Color(red: 0.06, green: 0.05, blue: 0.04)]
                : [Color(red: 0.99, green: 0.96, blue: 0.93),
                   Color(red: 0.95, green: 0.91, blue: 0.86)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct HomeWidgetEntry: TimelineEntry {
    let date: Date
    let isListening: Bool
}

struct HomeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeWidgetEntry {
        HomeWidgetEntry(date: Date(), isListening: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeWidgetEntry) -> Void) {
        completion(HomeWidgetEntry(date: Date(), isListening: SharedAppState.isListening))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeWidgetEntry>) -> Void) {
        let entry = HomeWidgetEntry(date: Date(), isListening: SharedAppState.isListening)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 15))))
    }
}

struct HomeWidgetView: View {
    let entry: HomeWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var accent: Color { AccentColors.aiCoral }

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemMedium: mediumView
        default: largeView
        }
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
            Text("OpenGlasses")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(entry.isListening ? "Listening" : "Tap to listen")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(intent: ToggleListeningIntent()) {
                HStack {
                    Image(systemName: entry.isListening ? "mic.slash.fill" : "mic.fill")
                    Text(entry.isListening ? "Stop" : "Listen")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(accent.opacity(0.85), in: Capsule())
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
                    Text("OpenGlasses")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Text(entry.isListening ? "Listening for wake word" : "Listening disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                statusDot
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
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 70)
                    .background(accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                Link(destination: URL(string: "openglasses://action/photo")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                        Text("Photo")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 96, height: 30)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                }
            }
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LogoIcon(size: 28)
                    .foregroundStyle(accent)
                Text("OpenGlasses")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                statusDot
            }
            Text(entry.isListening ? "Listening for wake word" : "Listening disabled")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(intent: ToggleListeningIntent()) {
                HStack {
                    Image(systemName: entry.isListening ? "mic.slash.fill" : "mic.fill")
                        .font(.title3)
                    Text(entry.isListening ? "Stop Listening" : "Start Listening")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                quickActionLink(url: "openglasses://action/ask", icon: "questionmark.circle.fill", label: "Ask")
                quickActionLink(url: "openglasses://action/photo", icon: "camera.fill", label: "Photo")
                quickActionLink(url: "openglasses://action/describe", icon: "eye.fill", label: "Describe")
            }
        }
    }

    private func quickActionLink(url: String, icon: String, label: String) -> some View {
        Link(destination: URL(string: url)!) {
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

    private var statusDot: some View {
        Circle()
            .fill(entry.isListening ? Color.green : Color.gray)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.3), lineWidth: 1)
            )
    }
}
