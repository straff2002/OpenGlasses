import Foundation

enum MyDayBriefingChannel: String, CaseIterable, Sendable {
    case phone
    case scheduled
    case voice
}

enum MyDayActionMetric: String, CaseIterable, Sendable {
    case completeReminder
    case openEvent
    case startDirections
}

enum MyDaySnapshotLatencyBucket: String, CaseIterable, Sendable {
    case under250Milliseconds
    case under500Milliseconds
    case underOneSecond
    case underTwoSeconds
    case twoSecondsOrMore

    init(seconds: TimeInterval) {
        switch max(0, seconds) {
        case ..<0.25: self = .under250Milliseconds
        case ..<0.5: self = .under500Milliseconds
        case ..<1: self = .underOneSecond
        case ..<2: self = .underTwoSeconds
        default: self = .twoSecondsOrMore
        }
    }
}

enum MyDaySpokenDurationBucket: String, CaseIterable, Sendable {
    case under20Seconds
    case target20Through35Seconds
    case over35Seconds

    init(seconds: TimeInterval) {
        switch max(0, seconds) {
        case ..<20: self = .under20Seconds
        case ...MyDaySpeechPolicy.maximumDuration: self = .target20Through35Seconds
        default: self = .over35Seconds
        }
    }
}

/// A closed metric vocabulary. There is deliberately no String, metadata dictionary, or generic
/// payload case: titles, locations, reminder text, notification bodies, and generated speech
/// cannot be represented by this API.
enum MyDayMetricEvent: Equatable, Sendable {
    case optedIn
    case briefingRequested(MyDayBriefingChannel)
    case action(MyDayActionMetric)
    case dismissal
    case sevenDayReturn
    case snapshotLatency(MyDaySnapshotLatencyBucket)
    case spokenDuration(MyDaySpokenDurationBucket)
}

protocol MyDayMetricsRecording: AnyObject {
    func record(_ event: MyDayMetricEvent, at date: Date)
}

struct MyDayMetricsSnapshot: Equatable, Sendable {
    let optIns: Int
    let briefingRequests: [MyDayBriefingChannel: Int]
    let actions: [MyDayActionMetric: Int]
    let dismissals: Int
    let sevenDayReturns: Int
    let snapshotLatencies: [MyDaySnapshotLatencyBucket: Int]
    let spokenDurations: [MyDaySpokenDurationBucket: Int]
}

/// Local-only aggregate learning for My Day. It stores counters and one content-free timestamp
/// used to recognize a seven-day return. It keeps no event log and has no network/export path.
final class MyDayMetricsStore: MyDayMetricsRecording, @unchecked Sendable {
    static let shared = MyDayMetricsStore()

    private enum Key {
        static let prefix = "myDayMetrics.v1."
        static let optIns = prefix + "optIns"
        static let dismissals = prefix + "dismissals"
        static let sevenDayReturns = prefix + "sevenDayReturns"
        static let firstBriefingAt = prefix + "firstBriefingAt"
        static let sevenDayReturnRecorded = prefix + "sevenDayReturnRecorded"

        static func briefing(_ channel: MyDayBriefingChannel) -> String {
            prefix + "briefing." + channel.rawValue
        }

        static func action(_ action: MyDayActionMetric) -> String {
            prefix + "action." + action.rawValue
        }

        static func latency(_ bucket: MyDaySnapshotLatencyBucket) -> String {
            prefix + "latency." + bucket.rawValue
        }

        static func spoken(_ bucket: MyDaySpokenDurationBucket) -> String {
            prefix + "spoken." + bucket.rawValue
        }
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func record(_ event: MyDayMetricEvent, at date: Date = Date()) {
        lock.withLock {
            switch event {
            case .optedIn:
                increment(Key.optIns)
            case .briefingRequested(let channel):
                increment(Key.briefing(channel))
                recordSevenDayReturnIfNeeded(at: date)
            case .action(let action):
                increment(Key.action(action))
            case .dismissal:
                increment(Key.dismissals)
            case .sevenDayReturn:
                guard !defaults.bool(forKey: Key.sevenDayReturnRecorded) else { return }
                defaults.set(true, forKey: Key.sevenDayReturnRecorded)
                increment(Key.sevenDayReturns)
            case .snapshotLatency(let bucket):
                increment(Key.latency(bucket))
            case .spokenDuration(let bucket):
                increment(Key.spoken(bucket))
            }
        }
    }

    func snapshot() -> MyDayMetricsSnapshot {
        lock.withLock {
            MyDayMetricsSnapshot(
                optIns: defaults.integer(forKey: Key.optIns),
                briefingRequests: Dictionary(uniqueKeysWithValues: MyDayBriefingChannel.allCases.map {
                    ($0, defaults.integer(forKey: Key.briefing($0)))
                }),
                actions: Dictionary(uniqueKeysWithValues: MyDayActionMetric.allCases.map {
                    ($0, defaults.integer(forKey: Key.action($0)))
                }),
                dismissals: defaults.integer(forKey: Key.dismissals),
                sevenDayReturns: defaults.integer(forKey: Key.sevenDayReturns),
                snapshotLatencies: Dictionary(uniqueKeysWithValues: MyDaySnapshotLatencyBucket.allCases.map {
                    ($0, defaults.integer(forKey: Key.latency($0)))
                }),
                spokenDurations: Dictionary(uniqueKeysWithValues: MyDaySpokenDurationBucket.allCases.map {
                    ($0, defaults.integer(forKey: Key.spoken($0)))
                })
            )
        }
    }

    private func recordSevenDayReturnIfNeeded(at date: Date) {
        guard !defaults.bool(forKey: Key.sevenDayReturnRecorded) else { return }
        guard let first = defaults.object(forKey: Key.firstBriefingAt) as? Date else {
            defaults.set(date, forKey: Key.firstBriefingAt)
            return
        }
        guard let threshold = calendar.date(byAdding: .day, value: 7, to: first), date >= threshold else {
            return
        }
        defaults.set(true, forKey: Key.sevenDayReturnRecorded)
        increment(Key.sevenDayReturns)
    }

    private func increment(_ key: String) {
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
