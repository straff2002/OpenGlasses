import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// What the phone keeps of one crash: where it happened, never what anyone was doing.
///
/// Built from the crash diagnostic the system hands the app on a later launch (MetricKit). That is
/// a local delivery from the OS, not a report: nothing here is sent anywhere, and a note leaves the
/// phone only inside a support report the person reviews and sends.
///
/// Kept: the build and system the crash happened on, the exception type, code and signal, the
/// termination reason, and the crashed thread's frames as binary name, binary UUID and offset —
/// no symbol is resolved on the phone (the Mac does that against the archive,
/// `Scripts/symbolicate-crash-report.sh`). For an Objective-C exception: its name, the class that
/// raised it, and its format string with only the **numeric** arguments filled in. The composed
/// message is never kept, because an exception message can embed an object's description, and an
/// object's description can be someone's text; "invalid number of items in section %ld" is what
/// a fix needs, and it survives.
///
/// Two shapes of input reach the same value: the JSON of an `MXDiagnosticPayload` (iOS 26), and
/// the `CrashDiagnostic` struct the newer MetricKit API delivers (iOS 27), whose Objective-C
/// reason is a nested `CrashDiagnostic.ObjectiveCExceptionReason`. Pure apart from the adapter,
/// so the core is tested on JSON fixtures.
struct CrashNote: Codable, Equatable, Identifiable {

    /// One frame of the crashed thread, newest first.
    struct Frame: Codable, Equatable {
        let binary: String
        /// The binary's UUID, upper case, as `dwarfdump --uuid` prints it.
        let uuid: String
        let offset: UInt64
    }

    /// An Objective-C exception, reduced to what cannot carry anyone's text.
    struct ExceptionReason: Codable, Equatable {
        let name: String
        let className: String
        /// The format string with numeric arguments filled in and every other argument left as
        /// its specifier (`CrashNote.numericOnly`).
        let message: String
    }

    /// A stable fingerprint, so the same crash delivered twice (late, or by both MetricKit APIs)
    /// is one note.
    let id: String
    /// The window the system dated the crash to. MetricKit stamps to the minute, so `start` can be
    /// up to a minute before the crash itself.
    let windowStart: Date
    let windowEnd: Date
    let appVersion: String
    let build: String
    let osVersion: String
    let exceptionType: Int?
    let exceptionCode: Int64?
    let signal: Int?
    let terminationReason: String?
    let exception: ExceptionReason?
    let frames: [Frame]

    /// The moment the note is dated to: the start of the system's window.
    var at: Date { windowStart }

    /// The crashed thread's frames kept, at most.
    static let maxFrames = 40
    /// A termination reason longer than this is cut: it is the system's text, and only its start
    /// ("Namespace SIGNAL, Code 0xb") matters.
    static let maxReasonLength = 200
    static let maxMessageLength = 300

    init(windowStart: Date, windowEnd: Date, appVersion: String, build: String, osVersion: String,
         exceptionType: Int?, exceptionCode: Int64?, signal: Int?, terminationReason: String?,
         exception: ExceptionReason?, frames: [Frame]) {
        self.windowStart = windowStart
        self.windowEnd = max(windowEnd, windowStart)
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason.map { String($0.prefix(Self.maxReasonLength)) }
        self.exception = exception
        self.frames = Array(frames.prefix(Self.maxFrames))
        self.id = Self.fingerprint(build: build, windowStart: windowStart, exceptionType: exceptionType,
                                   exceptionCode: exceptionCode, signal: signal,
                                   frames: Array(frames.prefix(3)))
    }

    // MARK: - Summary

    /// "SIGABRT (EXC_CRASH), NSInternalInconsistencyException (UICollectionView): invalid number of
    /// items in section 0 …" — one line, for the report and the export.
    var summary: String {
        var head: [String] = []
        let signalName = signal.map(Self.signalName)
        let exceptionName = exceptionType.map(Self.machExceptionName)
        switch (signalName, exceptionName) {
        case let (signal?, exception?): head.append("\(signal) (\(exception))")
        case let (signal?, nil): head.append(signal)
        case let (nil, exception?): head.append(exception)
        case (nil, nil): head.append("crash")
        }
        if let exception {
            head.append("\(exception.name) (\(exception.className)): \(exception.message)")
        } else if let reason = terminationReason, !reason.isEmpty {
            head.append(reason)
        }
        if isWatchdog { head.append("the system ended the app for not responding in time (watchdog)") }
        return head.joined(separator: ", ")
    }

    /// The watchdog's own code, or the iOS 27 category.
    var isWatchdog: Bool {
        guard let reason = terminationReason?.lowercased() else { return false }
        return reason.contains("8badf00d") || reason == "watchdog"
    }

    static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        case 15: return "SIGTERM"
        default: return "signal \(signal)"
        }
    }

    static func machExceptionName(_ type: Int) -> String {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return "exception \(type)"
        }
    }

    // MARK: - The numeric-argument filter

    /// The format string with each numeric specifier replaced by its argument when that argument
    /// is a plain number, and every other specifier (`%@`, `%s`, …) left as written — its argument
    /// is dropped, because it can be anybody's text. Positional (`%1$@`) and `*` widths are not
    /// filled at all: the arguments could not be paired with confidence.
    static func numericOnly(format: String, arguments: [String]) -> String {
        let characters = Array(format)
        var out = ""
        var argument = 0
        var index = 0
        let flags = Set("-+ #0'")
        let lengths = Set("hlqLztj")
        let numeric = Set("diouxXeEfFgGaA")
        while index < characters.count {
            let character = characters[index]
            guard character == "%" else {
                out.append(character)
                index += 1
                continue
            }
            var cursor = index + 1
            if cursor < characters.count, characters[cursor] == "%" {
                out.append("%")
                index = cursor + 1
                continue
            }
            // A positional argument or a `*` width: give up on filling, keep the format as it is.
            var probe = cursor
            while probe < characters.count, characters[probe].isNumber { probe += 1 }
            if probe < characters.count, characters[probe] == "$", probe > cursor {
                return String(format.prefix(maxMessageLength))
            }
            while cursor < characters.count, flags.contains(characters[cursor]) { cursor += 1 }
            while cursor < characters.count, characters[cursor].isNumber || characters[cursor] == "*" {
                if characters[cursor] == "*" { return String(format.prefix(maxMessageLength)) }
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "." {
                cursor += 1
                while cursor < characters.count, characters[cursor].isNumber || characters[cursor] == "*" {
                    if characters[cursor] == "*" { return String(format.prefix(maxMessageLength)) }
                    cursor += 1
                }
            }
            while cursor < characters.count, lengths.contains(characters[cursor]) { cursor += 1 }
            guard cursor < characters.count else {
                out += String(characters[index...])
                break
            }
            let conversion = characters[cursor]
            let specifier = String(characters[index...cursor])
            let value = argument < arguments.count ? arguments[argument] : nil
            argument += 1
            if numeric.contains(conversion), let value, isPlainNumber(value) {
                out += value
            } else {
                out += specifier
            }
            index = cursor + 1
        }
        return String(out.prefix(maxMessageLength))
    }

    /// Digits with an optional sign and decimal part, or a hex literal — never a word.
    static func isPlainNumber(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 24 else { return false }
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            let digits = text.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy(\.isHexDigit)
        }
        var body = Substring(text)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    // MARK: - Frames

    /// A frame as both shapes give it: the binary, the offset and the frames under it.
    struct RawFrame {
        let binary: String?
        let uuid: String?
        let offset: UInt64?
        let subFrames: [RawFrame]
    }

    /// The crashed thread's frames, newest first: each root frame, then the chain of first
    /// sub-frames beneath it, as MetricKit nests a crash's call stack. Frames with no binary UUID
    /// or offset are skipped — nothing could be symbolicated from them.
    static func flatten(_ roots: [RawFrame]) -> [Frame] {
        var frames: [Frame] = []
        func walk(_ frame: RawFrame) {
            guard frames.count < maxFrames else { return }
            if let uuid = frame.uuid, let offset = frame.offset {
                frames.append(Frame(binary: frame.binary ?? "?", uuid: uuid.uppercased(), offset: offset))
            }
            for sub in frame.subFrames { walk(sub) }
        }
        for root in roots { walk(root) }
        return frames
    }

    // MARK: - Fingerprint

    /// FNV-1a over the fields that make a crash itself, in hex. Deterministic across launches,
    /// unlike `hashValue`.
    static func fingerprint(build: String, windowStart: Date, exceptionType: Int?, exceptionCode: Int64?,
                            signal: Int?, frames: [Frame]) -> String {
        var parts = [build, String(Int(windowStart.timeIntervalSince1970)),
                     exceptionType.map(String.init) ?? "-", exceptionCode.map(String.init) ?? "-",
                     signal.map(String.init) ?? "-"]
        parts += frames.map { "\($0.uuid)+\($0.offset)" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - iOS 26: the payload's JSON

extension CrashNote {

    /// Every crash in an `MXDiagnosticPayload`'s `jsonRepresentation()`. A payload with no crash
    /// (hangs, CPU or disk exceptions only) gives none. Anything that does not parse gives none —
    /// diagnostics must never take the app down.
    static func notes(fromPayloadJSON data: Data, timeZone: TimeZone = .current) -> [CrashNote] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else { return [] }
        let start = date(payload["timeStampBegin"], timeZone: timeZone)
        let end = date(payload["timeStampEnd"], timeZone: timeZone)
        guard let windowStart = start ?? end else { return [] }
        let windowEnd = end ?? windowStart
        let crashes = payload["crashDiagnostics"] as? [[String: Any]] ?? []
        return crashes.map { note(fromCrash: $0, windowStart: windowStart, windowEnd: windowEnd) }
    }

    private static func note(fromCrash crash: [String: Any], windowStart: Date, windowEnd: Date) -> CrashNote {
        let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
        let reasonObject = (meta["objectiveCexceptionReason"] ?? meta["objectiveCExceptionReason"]
            ?? crash["objectiveCexceptionReason"] ?? crash["exceptionReason"]) as? [String: Any]
        let exception = reasonObject.flatMap { reason -> ExceptionReason? in
            let format = reason["formatString"] as? String ?? ""
            let arguments = (reason["arguments"] as? [Any] ?? []).map { "\($0)" }
            let name = (reason["exceptionName"] as? String) ?? (reason["exceptionType"] as? String) ?? "exception"
            return ExceptionReason(name: name, className: reason["className"] as? String ?? "?",
                                   message: numericOnly(format: format, arguments: arguments))
        }
        let tree = crash["callStackTree"] as? [String: Any] ?? [:]
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        let crashed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        let roots = (crashed?["callStackRootFrames"] as? [[String: Any]] ?? []).map(rawFrame)
        return CrashNote(windowStart: windowStart, windowEnd: windowEnd,
                         appVersion: meta["appVersion"] as? String ?? "–",
                         build: meta["appBuildVersion"] as? String ?? "–",
                         osVersion: meta["osVersion"] as? String ?? "–",
                         exceptionType: integer(meta["exceptionType"]),
                         exceptionCode: integer(meta["exceptionCode"]).map(Int64.init),
                         signal: integer(meta["signal"]),
                         terminationReason: meta["terminationReason"] as? String,
                         exception: exception,
                         frames: flatten(roots))
    }

    private static func rawFrame(_ object: [String: Any]) -> RawFrame {
        let offset: UInt64? = (object["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value
        return RawFrame(binary: object["binaryName"] as? String, uuid: object["binaryUUID"] as? String,
                        offset: offset,
                        subFrames: (object["subFrames"] as? [[String: Any]] ?? []).map(rawFrame))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// "2026-11-16 21:45:00", the payload's own format (local time), or ISO 8601.
    static func date(_ value: Any?, timeZone: TimeZone) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - iOS 27: the CrashDiagnostic struct

// The type is in the iOS 27 SDK only (Xcode 27, Swift 6.4); a 26.x toolchain builds without it and
// reads every crash through `MXDiagnosticPayload`'s JSON, which iOS 27 still delivers.
#if canImport(MetricKit) && compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, *)
extension CrashNote {

    /// The newer API's crash, with the report's build, system and time range beside it.
    init(crash: CrashDiagnostic, appVersion: String, build: String, osVersion: String, window: DateInterval) {
        let tree = crash.callStackTree
        let threads = Array(tree.callStackThreads)
        let crashed = threads.first { $0.threadAttributed == true } ?? threads.first
        func raw(_ frame: CallStackFrame) -> RawFrame {
            RawFrame(binary: frame.binaryName(from: tree), uuid: frame.binaryUUID?.uuidString,
                     offset: frame.offsetIntoBinaryTextSegment, subFrames: frame.subFrames.map(raw))
        }
        let exception = crash.exceptionReason.map { reason in
            ExceptionReason(name: reason.exceptionName.isEmpty ? reason.exceptionType : reason.exceptionName,
                            className: reason.className,
                            message: CrashNote.numericOnly(format: reason.formatString,
                                                           arguments: reason.arguments))
        }
        let code = crash.exceptionCode.map { Int64(truncatingIfNeeded: $0) }
        self.init(windowStart: window.start, windowEnd: window.end, appVersion: appVersion, build: build,
                  osVersion: osVersion, exceptionType: crash.exceptionType, exceptionCode: code,
                  signal: crash.signal,
                  terminationReason: crash.terminationReason?.rawValue
                    ?? crash.terminationCategory?.rawValue,
                  exception: exception,
                  frames: CrashNote.flatten(crashed.map { $0.rootFrames.map(raw) } ?? []))
    }
}
#endif
