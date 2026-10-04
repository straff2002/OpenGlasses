import Foundation

/// One thing a video model says it saw in a recorded job, once it has passed validation
/// (Contracts/recorded-session.md §7.1, §7.2).
struct ActionEvent: Equatable, Codable, Sendable {
    let id: String
    let start: SessionTime
    let end: SessionTime
    let action: String
    let object: String?
    let tool: String?
    /// Moments in the video that show it, in time order.
    let evidence: [Moment]
    /// The utterances the model says go with it. Its own claim: nothing relies on it.
    let utterances: [String]
    /// Nil when the model gave none that could be used.
    let confidence: Double?
    /// Below the confidence floor, or no confidence at all. Kept, and marked: never used for
    /// compliance and never shown as fact.
    let lowConfidence: Bool

    struct Moment: Equatable, Codable, Sendable {
        let t: SessionTime
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, action, object, tool, evidence, utterances, confidence
        case lowConfidence = "low_confidence"
    }
}

/// The validation every model's action events go through before anything else sees them
/// (Contracts/recorded-session.md §7.2): reject or repair, never guess.
///
/// Reference code for a rule both sides compute the same way. The phone analyses no video in this
/// version; the office does, and `Contracts/fixtures/action-events-v1.json` holds the cases and the
/// answer to each.
///
/// An event is **rejected** — in this order, the first that applies — when it is not an object;
/// has no usable `id`, or one already used; has no `start` or `end`; does not start before it ends;
/// is not wholly inside the analysed span; is not wholly on video (inside one part and touching no
/// gap); has no `action` or one that is too long; has an `object` or `tool` that is too long; or
/// is left with no evidence.
///
/// An event is **repaired** by taking out what cannot stand without inventing anything: an evidence
/// moment outside the event, an utterance id the transcript does not have. A confidence that is
/// missing, not a number or outside 0…1 is no confidence, and the event is kept as low-confidence.
enum ActionEventValidator {
    static let confidenceFloor = 0.4
    static let maximumActionCharacters = 200
    static let maximumDetailCharacters = 80
    static let maximumIDCharacters = 80

    /// What the events are checked against.
    struct Context: Equatable, Sendable {
        /// The stretch of the session the model was shown.
        let spanFrom: SessionTime
        let spanTo: SessionTime
        let timeline: SessionTimeline
        let transcript: TimedTranscript
    }

    enum Rejection: String, Sendable {
        case notAnObject = "not_an_object"
        case noID = "no_id"
        case duplicateID = "duplicate_id"
        case timesMissing = "times_missing"
        case timesReversed = "times_reversed"
        case outsideSpan = "outside_span"
        case outsideMedia = "outside_media"
        case actionLength = "action_length"
        case objectLength = "object_length"
        case toolLength = "tool_length"
        case noEvidence = "no_evidence"
    }

    enum Repair: String, Sendable {
        case evidenceRemoved = "evidence_removed"
        case utteranceRemoved = "utterance_removed"
    }

    struct Kept: Equatable, Sendable {
        let event: ActionEvent
        let repairs: [Repair]
    }

    struct Rejected: Equatable, Sendable {
        /// The event's place in the model's list, from 0.
        let index: Int
        let id: String?
        let reason: Rejection
    }

    struct Result: Equatable, Sendable {
        /// In the model's order.
        let kept: [Kept]
        let rejected: [Rejected]
        let viewLimitations: [String]
        /// True unless the model said plainly that its view was whole.
        let partialView: Bool

        var events: [ActionEvent] { kept.map(\.event) }
    }

    enum Refusal: Error, Equatable {
        /// Not JSON, not an object, or without an `action_events` list.
        case malformed
    }

    static func validate(_ modelOutput: Data, context: Context) throws -> Result {
        guard case let .object(root)? = try? JSONDecoder().decode(Loose.self, from: modelOutput),
              case let .array(entries)? = root["action_events"] else { throw Refusal.malformed }

        let clear = context.timeline.clearSpans(.video)
        let known = Set(context.transcript.utterances.map(\.id))
        var seen: Set<String> = []
        var kept: [Kept] = []
        var rejected: [Rejected] = []

        for (index, entry) in entries.enumerated() {
            guard case let .object(fields) = entry else {
                rejected.append(Rejected(index: index, id: nil, reason: .notAnObject))
                continue
            }
            guard let id = fields["id"]?.text.map(trimmed), (1...maximumIDCharacters).contains(length(id)) else {
                rejected.append(Rejected(index: index, id: nil, reason: .noID))
                continue
            }
            func reject(_ reason: Rejection) { rejected.append(Rejected(index: index, id: id, reason: reason)) }
            guard seen.insert(id).inserted else {
                reject(.duplicateID)
                continue
            }
            guard let start = fields["start"]?.time, let end = fields["end"]?.time else {
                reject(.timesMissing)
                continue
            }
            guard start < end else {
                reject(.timesReversed)
                continue
            }
            guard context.spanFrom <= start, end <= context.spanTo else {
                reject(.outsideSpan)
                continue
            }
            guard clear.contains(where: { $0.from <= start && end <= $0.to }) else {
                reject(.outsideMedia)
                continue
            }
            guard let action = fields["action"]?.text.map(trimmed),
                  (1...maximumActionCharacters).contains(length(action)) else {
                reject(.actionLength)
                continue
            }
            let object = fields["object"]?.text.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
            guard length(object ?? "") <= maximumDetailCharacters else {
                reject(.objectLength)
                continue
            }
            let tool = fields["tool"]?.text.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
            guard length(tool ?? "") <= maximumDetailCharacters else {
                reject(.toolLength)
                continue
            }

            var repairs: [Repair] = []
            let offered = fields["evidence"]?.list ?? []
            let moments = offered.compactMap { item -> SessionTime? in
                guard case let .object(moment) = item, let t = moment["t"]?.time, start <= t, t <= end else { return nil }
                return t
            }
            if moments.count < offered.count { repairs.append(.evidenceRemoved) }
            guard !moments.isEmpty else {
                reject(.noEvidence)
                continue
            }
            let claimed = fields["utterances"]?.list ?? []
            let utterances = claimed.compactMap { item in item.text.flatMap { known.contains($0) ? $0 : nil } }
            if utterances.count < claimed.count { repairs.append(.utteranceRemoved) }

            let confidence = fields["confidence"]?.number.flatMap { (0...1).contains($0) ? $0 : nil }
            kept.append(Kept(
                event: ActionEvent(
                    id: id, start: start, end: end, action: action, object: object, tool: tool,
                    evidence: Set(moments).sorted().map(ActionEvent.Moment.init),
                    utterances: context.transcript.utterances.map(\.id).filter(Set(utterances).contains),
                    confidence: confidence, lowConfidence: confidence.map { $0 < confidenceFloor } ?? true),
                repairs: repairs))
        }

        let limitations = (root["view_limitations"]?.list ?? []).compactMap { $0.text.map(trimmed) }
            .filter { !$0.isEmpty }
        var partial = true
        if case .bool(false)? = root["partial_view"] { partial = false }
        return Result(kept: kept, rejected: rejected, viewLimitations: limitations, partialView: partial)
    }

    /// Length as the contract counts it: in characters, meaning Unicode scalars.
    private static func length(_ text: String) -> Int { text.unicodeScalars.count }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JSON read without a schema, so that a member of the wrong type or one nobody defined can be
    /// dropped instead of failing the whole document.
    private enum Loose: Decodable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Loose])
        case object([String: Loose])

        init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: Key.self) {
                var object: [String: Loose] = [:]
                for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(Loose.self, forKey: key) }
                self = .object(object)
            } else if var list = try? decoder.unkeyedContainer() {
                var array: [Loose] = []
                while !list.isAtEnd { array.append(try list.decode(Loose.self)) }
                self = .array(array)
            } else {
                let value = try decoder.singleValueContainer()
                if value.decodeNil() {
                    self = .null
                } else if let bool = try? value.decode(Bool.self) {
                    self = .bool(bool)
                } else if let number = try? value.decode(Double.self) {
                    self = .number(number)
                } else {
                    self = .string(try value.decode(String.self))
                }
            }
        }

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        var text: String? {
            if case let .string(value) = self { return value }
            return nil
        }

        var number: Double? {
            if case let .number(value) = self, value.isFinite { return value }
            return nil
        }

        var list: [Loose]? {
            if case let .array(value) = self { return value }
            return nil
        }

        /// A time in seconds, when the number can be one.
        var time: SessionTime? {
            number.flatMap { abs($0 * 1000) <= Double(SessionTime.limit) ? SessionTime(seconds: $0) : nil }
        }
    }
}
