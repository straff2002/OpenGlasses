import WidgetKit
import SwiftUI
import AppIntents
import WatchConnectivity

private var watchWidgetFamilies: [WidgetFamily] {
    #if os(watchOS)
    [.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline]
    #else
    [.accessoryRectangular, .accessoryCircular, .accessoryInline]
    #endif
}

// MARK: - Shared State

private let appGroupId = "group.com.openglasses.app"

struct WatchState {
    var isListening: Bool
    var isRecording: Bool
    var isConnected: Bool

    static var current: WatchState {
        let defaults = UserDefaults(suiteName: appGroupId) ?? .standard
        return WatchState(
            isListening: defaults.bool(forKey: "isListening"),
            isRecording: defaults.bool(forKey: "isRecording"),
            isConnected: defaults.bool(forKey: "isConnected")
        )
    }
}

// MARK: - Timeline Entry

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let state: WatchState
}

// MARK: - Timeline Providers

struct ListenComplicationProvider: AppIntentTimelineProvider {
    typealias Intent = ListenComplicationConfig
    typealias Entry = WatchComplicationEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, state: WatchState(isListening: false, isRecording: false, isConnected: false))
    }

    func snapshot(for configuration: ListenComplicationConfig, in context: Context) async -> Entry {
        Entry(date: .now, state: .current)
    }

    func timeline(for configuration: ListenComplicationConfig, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: [Entry(date: .now, state: .current)], policy: .atEnd)
    }

    func recommendations() -> [AppIntentRecommendation<ListenComplicationConfig>] {
        [AppIntentRecommendation(intent: ListenComplicationConfig(), description: "Toggle Listen")]
    }
}

struct RecordComplicationProvider: AppIntentTimelineProvider {
    typealias Intent = RecordComplicationConfig
    typealias Entry = WatchComplicationEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, state: WatchState(isListening: false, isRecording: false, isConnected: false))
    }

    func snapshot(for configuration: RecordComplicationConfig, in context: Context) async -> Entry {
        Entry(date: .now, state: .current)
    }

    func timeline(for configuration: RecordComplicationConfig, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: [Entry(date: .now, state: .current)], policy: .atEnd)
    }

    func recommendations() -> [AppIntentRecommendation<RecordComplicationConfig>] {
        [AppIntentRecommendation(intent: RecordComplicationConfig(), description: "Toggle Transcribe")]
    }
}

// MARK: - Complication Views

struct ListenComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    private var icon: String { entry.state.isListening ? "mic.fill" : "mic.slash.fill" }
    private var label: String { entry.state.isListening ? "Listening" : "Listen" }
    private var tint: Color { entry.state.isListening ? .green : .primary }

    var body: some View {
        Button(intent: ToggleListenIntent()) {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(entry.state.isListening ? "Tap to stop" : "OG glasses")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
            #if os(watchOS)
            case .accessoryCorner:
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .widgetLabel(label)
            #endif
            default:
                Label(label, systemImage: icon)
            }
        }
        .buttonStyle(.plain)
    }
}

struct RecordComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    private var icon: String { entry.state.isRecording ? "record.circle.fill" : "record.circle" }
    private var label: String { entry.state.isRecording ? "Recording" : "Transcribe" }
    private var tint: Color { entry.state.isRecording ? .red : .primary }

    var body: some View {
        Button(intent: ToggleRecordIntent()) {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(entry.state.isRecording ? "Tap to stop" : "No AI response")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
            #if os(watchOS)
            case .accessoryCorner:
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .widgetLabel(label)
            #endif
            default:
                Label(label, systemImage: icon)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widgets

struct ListenComplication: Widget {
    static let kind = "ListenComplication"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: ListenComplicationConfig.self,
            provider: ListenComplicationProvider()
        ) { entry in
            ListenComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Listen")
        .description("Toggle listening on your glasses.")
        .supportedFamilies(watchWidgetFamilies)
    }
}

struct RecordComplication: Widget {
    static let kind = "RecordComplication"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: RecordComplicationConfig.self,
            provider: RecordComplicationProvider()
        ) { entry in
            RecordComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Transcribe")
        .description("Start/stop transcription without AI response.")
        .supportedFamilies(watchWidgetFamilies)
    }
}

// MARK: - Photo Note Complication

struct PhotoComplicationProvider: AppIntentTimelineProvider {
    typealias Intent = PhotoComplicationConfig
    typealias Entry = WatchComplicationEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, state: WatchState(isListening: false, isRecording: false, isConnected: false))
    }

    func snapshot(for configuration: PhotoComplicationConfig, in context: Context) async -> Entry {
        Entry(date: .now, state: .current)
    }

    func timeline(for configuration: PhotoComplicationConfig, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: [Entry(date: .now, state: .current)], policy: .atEnd)
    }

    func recommendations() -> [AppIntentRecommendation<PhotoComplicationConfig>] {
        [AppIntentRecommendation(intent: PhotoComplicationConfig(), description: "Photo Note")]
    }
}

struct PhotoComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Button(intent: CapturePhotoNoteIntent()) {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Photo Note")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Silent · added to transcript")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            #if os(watchOS)
            case .accessoryCorner:
                Image(systemName: "camera.fill")
                    .foregroundStyle(.primary)
                    .widgetLabel("Photo Note")
            #endif
            default:
                Label("Photo", systemImage: "camera.fill")
            }
        }
        .buttonStyle(.plain)
    }
}

struct PhotoNoteComplication: Widget {
    static let kind = "PhotoNoteComplication"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: PhotoComplicationConfig.self,
            provider: PhotoComplicationProvider()
        ) { entry in
            PhotoComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Photo Note")
        .description("Silently capture a photo and add it to the meeting transcript.")
        .supportedFamilies(watchWidgetFamilies)
    }
}

@main
struct OpenGlassesWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ListenComplication()
        RecordComplication()
        PhotoNoteComplication()
    }
}
