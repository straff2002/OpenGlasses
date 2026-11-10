import Foundation

/// Where a kept replay goes.
enum ReplayDestination: String, Equatable, CaseIterable {
    /// The app's Recordings folder, as an ordinary recording labelled Replay. The default.
    case recordings
    /// The open job, as a clip — only when the wearer names the job.
    case job
    /// The Recordings folder and the Photos library — only when Photos is asked for in the same
    /// request. The recorder's "Also Save to Photos" switch does not apply to a replay.
    case photos

    /// Read a destination the way a model or a Shortcut hands it over. Anything unknown is the
    /// default, never somewhere the wearer did not name.
    init(argument: String?) {
        switch argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "job", "the job", "work order", "job clip": self = .job
        case "photos", "photo", "camera roll", "photo library", "library": self = .photos
        default: self = .recordings
        }
    }
}

/// "Keep the last 30 seconds" — what was asked, as plain values (Instant Replay §6).
struct ReplaySaveRequest: Equatable {
    var seconds: TimeInterval
    var destination: ReplayDestination
    var caption: String?

    init(seconds: TimeInterval? = nil, destination: ReplayDestination = .recordings,
         caption: String? = nil) {
        if let seconds, seconds.isFinite, seconds > 0 {
            self.seconds = seconds.rounded()
        } else {
            self.seconds = ReplayBufferPlan.defaultSaveSeconds
        }
        self.destination = destination
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.caption = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The tool's arguments. `seconds` may arrive as a number or a numeric string; `minutes` is
    /// accepted for "save the last minute".
    init(arguments args: [String: Any]) {
        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let d = value as? Double { return d }
            if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        let seconds = number(args["seconds"]) ?? number(args["minutes"]).map { $0 * 60 }
        self.init(seconds: seconds,
                  destination: ReplayDestination(argument: args["destination"] as? String),
                  caption: args["caption"] as? String)
    }
}

/// What a save will actually do, decided before anything is written.
enum ReplaySaveDecision: Equatable {
    /// Save `seconds` (already held to the buffer and, for a job, to the job clip cap).
    /// `cappedForJob` is set when a job clip was asked longer than a job clip may be.
    case save(seconds: TimeInterval, destination: ReplayDestination, cappedForJob: Bool)
    case refuse(ReplaySaveRefusal)

    /// Pure: the request, what the buffer is doing, and the job.
    static func decide(_ request: ReplaySaveRequest, buffer: ReplayBufferPolicy.Decision,
                       jobOpen: Bool, jobClipMaximum: TimeInterval) -> ReplaySaveDecision {
        guard case .run(let plan) = buffer else {
            return .refuse(.notRunning(buffer.offReason ?? .cameraOff))
        }
        var seconds = min(request.seconds, plan.bufferSeconds)
        var capped = false
        if request.destination == .job {
            guard jobOpen else { return .refuse(.noOpenJob) }
            if seconds > jobClipMaximum {
                seconds = jobClipMaximum
                capped = true
            }
        }
        return .save(seconds: seconds, destination: request.destination, cappedForJob: capped)
    }
}

enum ReplaySaveRefusal: Equatable {
    case notRunning(ReplayOffReason)
    case noOpenJob
    case nothingBuffered
    case couldNotSave

    var spoken: String {
        switch self {
        case .notRunning(let reason): return reason.spoken
        case .noOpenJob: return "There's no job open, so there's nowhere to put the replay. "
            + "Say save the replay to keep it in Recordings instead."
        case .nothingBuffered: return "Instant Replay hasn't kept anything yet. Give it a few seconds."
        case .couldNotSave: return "The replay couldn't be saved."
        }
    }
}

/// How a save ended, and the sentence the wearer hears.
struct ReplaySaveOutcome: Equatable {
    enum Result: Equatable {
        case saved(destination: ReplayDestination, askedSeconds: TimeInterval,
                   keptSeconds: TimeInterval, cappedForJob: Bool, photosLanded: Bool?)
        case refused(ReplaySaveRefusal)
    }

    let result: Result

    var didSave: Bool { if case .saved = result { return true }; return false }

    /// "Saved the last 30 seconds to Recordings." The asked length is said when the buffer held
    /// it — the file's own length (30–32 s for a 30-second ask) is recorded, not announced. When
    /// it held less, the wearer is told how much.
    var spoken: String {
        switch result {
        case .refused(let refusal):
            return refusal.spoken
        case .saved(let destination, let asked, let kept, let capped, let photosLanded):
            let place: String
            switch destination {
            case .recordings: place = "Recordings"
            case .job: place = "the job"
            case .photos: place = photosLanded == false ? "Recordings" : "Recordings and Photos"
            }
            let short = Self.isShort(kept: kept, asked: asked)
            var line: String
            if capped {
                line = "A job clip is at most \(Self.length(asked)), so I saved "
                    + "\(Self.theLast(short ? kept : asked)) to the job."
            } else if short {
                line = "I only have \(Self.theLast(kept)); saved \(kept.rounded() == 60 ? "it" : "those") to \(place)."
            } else {
                line = "Saved \(Self.theLast(asked)) to \(place)."
            }
            if destination == .photos, photosLanded == false {
                line += " It couldn't be added to Photos."
            }
            return line
        }
    }

    /// The buffer held noticeably less than asked. A second under is the segment cut, not a
    /// shortfall worth a sentence.
    static func isShort(kept: TimeInterval, asked: TimeInterval) -> Bool {
        kept + 1 < asked
    }

    /// "30 seconds", "a minute", "2 minutes", "40 seconds".
    static func length(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole == 60 { return "a minute" }
        if whole % 60 == 0 { return "\(whole / 60) minutes" }
        return whole == 1 ? "a second" : "\(whole) seconds"
    }

    /// "the last 30 seconds", "the last minute", "the last 2 minutes".
    static func theLast(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole == 60 { return "the last minute" }
        if whole == 1 { return "the last second" }
        return "the last " + length(seconds)
    }
}

/// The passthrough composition, as a plan: which segment goes where on the clip's timeline.
///
/// Segments are inserted back to back in order, each at its own measured length, and exported
/// with no re-encode. Nothing is moved: the composition reads the segment files where they are.
struct ReplayCompositionPlan: Equatable {
    struct Insert: Equatable {
        let fileName: String
        let at: TimeInterval
        let duration: TimeInterval
    }

    let inserts: [Insert]

    var totalSeconds: TimeInterval { inserts.last.map { $0.at + $0.duration } ?? 0 }

    /// `durations` are the segments' own lengths, in the same order — the file's track duration
    /// when the composer has loaded it, the ring's frame times otherwise. A segment with no
    /// length is left out: it would add a frame of nothing.
    init(fileNames: [String], durations: [TimeInterval]) {
        var cursor: TimeInterval = 0
        var inserts: [Insert] = []
        for (name, duration) in zip(fileNames, durations) where duration > 0 {
            inserts.append(Insert(fileName: name, at: cursor, duration: duration))
            cursor += duration
        }
        self.inserts = inserts
    }

    init(span: ReplaySpan, frameRate: Int) {
        self.init(fileNames: span.segments.map(\.fileName),
                  durations: span.segments.map { $0.duration(frameRate: frameRate) })
    }
}
