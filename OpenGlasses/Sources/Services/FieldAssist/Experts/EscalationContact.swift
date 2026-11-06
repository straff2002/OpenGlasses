import Foundation

/// A person a technician can call for help on a job (Plan KM §1). The type Plans IQ (P3, the
/// calling base) and JI (§6, the journeyman) reuse: KM builds it first.
///
/// **Human-set fields only.** Who an expert is, what they know (`specialties`), whether they are the
/// organisation's own (`staff`) or paid by agreement (`contracted`), when they are on call, and —
/// for a contracted expert only — the rate the statement is figured at. Nothing about how calls
/// went, how anyone rated them or how often they were called: `ExpertPicker` chooses by fixed rules
/// over these fields, and a test asserts no other field exists.
///
/// **A staff expert never carries a rate.** The memberwise init drops one, and decoding refuses
/// one, so a list that says otherwise is a named drop rather than a rate that quietly applies.
struct EscalationContact: Codable, Equatable, Identifiable, Sendable {

    enum Kind: String, Codable, CaseIterable, Sendable {
        /// The organisation's own people — a senior with a seat, a supervisor. No rate, no statement.
        case staff
        /// Paid under the organisation's own agreement with them. The only kind with a rate.
        case contracted
    }

    /// How a handover (Plan KM P1) goes to this expert. Recorded now so an imported list keeps it;
    /// nothing is sent in P0.
    enum HandoverChannel: String, Codable, CaseIterable, Sendable {
        case messages
        case whatsApp = "whatsapp"
        case email
        case airDrop = "airdrop"
    }

    /// What a contracted expert's time is figured at on the statement (Plan KM P4). **A figure for
    /// the statement; the app never charges it.**
    struct Rate: Codable, Equatable, Sendable {
        /// Per hour, in `currency`.
        let perHour: Decimal
        /// The least a call is billed at, in minutes.
        let minimumMinutes: Int
        /// Billable time rounds up to this many minutes.
        let roundingMinutes: Int
        /// ISO 4217, upper case ("GBP", "USD").
        let currency: String

        static let perHourRange: ClosedRange<Decimal> = 0...10_000
        static let minimumRange: ClosedRange<Int> = 0...480
        static let roundingRange: ClosedRange<Int> = 1...60

        var problem: String? {
            if !Self.perHourRange.contains(perHour) { return "a rate per hour is outside 0–10000" }
            if !Self.minimumRange.contains(minimumMinutes) { return "a minimum is outside 0–480 minutes" }
            if !Self.roundingRange.contains(roundingMinutes) { return "a rounding grain is outside 1–60 minutes" }
            let isCode = currency.count == 3 && currency.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
            return isCode ? nil : "a currency is not a three-letter code"
        }
    }

    let id: String
    let name: String
    /// A dialable number, as `CallRoute.cleanedNumber` accepts it.
    let phone: String?
    /// The handle FaceTime rings: an email address or a number.
    let faceTimeHandle: String?
    let handoverChannel: HandoverChannel?
    /// Tags from the organisation's own vocabulary: trade, equipment kind, brand ("furnace",
    /// "heat pump", "Lennox").
    let specialties: [String]
    let kind: Kind
    /// Weekly windows in the expert's own time zone. Empty means any time.
    let onCall: [OnCallWindow]
    /// The expert's time zone identifier. Nil means the phone's own zone.
    let timeZoneIdentifier: String?
    /// Contracted only. Always nil for staff.
    let rate: Rate?
    /// Contracted only (Plan KM decision 10): whether this expert's coaching steps may be offered
    /// as a team learning. A staff expert's always may — a senior's walkthrough becoming the team's
    /// is the point — so this is false for staff. **Off unless the organisation turns it on**: who
    /// owns a paid adviser's method is a matter for the agreement, not the app. Set, like the rate,
    /// only by the profile's list or the device owner's; a personal addition has no such field.
    let coachingMayBecomeTeamLearning: Bool

    init(id: String, name: String, phone: String? = nil, faceTimeHandle: String? = nil,
         handoverChannel: HandoverChannel? = nil, specialties: [String] = [], kind: Kind = .staff,
         onCall: [OnCallWindow] = [], timeZoneIdentifier: String? = nil, rate: Rate? = nil,
         coachingMayBecomeTeamLearning: Bool = false) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phone = Self.nonEmpty(phone)
        self.faceTimeHandle = Self.nonEmpty(faceTimeHandle)
        self.handoverChannel = handoverChannel
        self.specialties = ExpertSpecialty.cleaned(specialties)
        self.kind = kind
        self.onCall = onCall
        self.timeZoneIdentifier = Self.nonEmpty(timeZoneIdentifier)
        // The invariant: only a contracted expert has a rate, or the coaching flag.
        self.rate = kind == .contracted ? rate : nil
        self.coachingMayBecomeTeamLearning = kind == .contracted && coachingMayBecomeTeamLearning
    }

    /// The zone on-call windows are read in.
    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// What the escalation record keeps about the expert called: never the rate, never the number.
    var snapshot: ExpertSnapshot { ExpertSnapshot(id: id, name: name, kind: kind) }

    /// Why this entry cannot go on a list, or nil.
    var problem: String? {
        if name.isEmpty { return "an expert has no name" }
        if name.count > 120 { return "an expert's name is longer than 120 characters" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "an expert's name contains a control character"
        }
        if id.isEmpty || id.count > 64 { return "an expert's id is empty or longer than 64 characters" }
        if phone == nil && faceTimeHandle == nil { return "\(name) has no number or FaceTime handle" }
        if let phone, CallRoute.cleanedNumber(phone) == nil { return "\(name)'s number can't be dialled" }
        if let faceTimeHandle, CallRoute.cleanedHandle(faceTimeHandle) == nil {
            return "\(name)'s FaceTime handle is not an email address or a number"
        }
        if specialties.count > ExpertSpecialty.maxTags { return "\(name) has more than \(ExpertSpecialty.maxTags) specialties" }
        if onCall.count > OnCallWindow.maxWindows { return "\(name) has more than \(OnCallWindow.maxWindows) on-call windows" }
        if let identifier = timeZoneIdentifier, TimeZone(identifier: identifier) == nil {
            return "\(name)'s time zone is not one this phone knows"
        }
        if let rate, let problem = rate.problem { return problem }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, phone, faceTimeHandle = "faceTime", handoverChannel = "handover", specialties, kind,
             onCall, timeZoneIdentifier = "timeZone", rate, coachingMayBecomeTeamLearning = "coachingToTeam"
    }

    /// Strict: a staff entry with a rate, or a kind this build does not know, is an error, never a
    /// guess. An entry without an id gets one derived from what it says, so a list written by
    /// hand still rotates stably.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let phone = try c.decodeIfPresent(String.self, forKey: .phone)
        let handle = try c.decodeIfPresent(String.self, forKey: .faceTimeHandle)
        let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .staff
        let rate = try c.decodeIfPresent(Rate.self, forKey: .rate)
        if kind == .staff, rate != nil {
            throw DecodingError.dataCorruptedError(forKey: .rate, in: c,
                                                   debugDescription: "a staff expert carries a rate")
        }
        let id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? Self.derivedId(name: name, phone: phone, handle: handle)
        self.init(id: id, name: name, phone: phone, faceTimeHandle: handle,
                  handoverChannel: try c.decodeIfPresent(HandoverChannel.self, forKey: .handoverChannel),
                  specialties: try c.decodeIfPresent([String].self, forKey: .specialties) ?? [],
                  kind: kind,
                  onCall: try c.decodeIfPresent([OnCallWindow].self, forKey: .onCall) ?? [],
                  timeZoneIdentifier: try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier),
                  rate: rate,
                  // Absent means off; on a staff entry it means nothing and is dropped.
                  coachingMayBecomeTeamLearning: try c.decodeIfPresent(Bool.self, forKey: .coachingMayBecomeTeamLearning) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(faceTimeHandle, forKey: .faceTimeHandle)
        try c.encodeIfPresent(handoverChannel, forKey: .handoverChannel)
        if !specialties.isEmpty { try c.encode(specialties, forKey: .specialties) }
        try c.encode(kind, forKey: .kind)
        if !onCall.isEmpty { try c.encode(onCall, forKey: .onCall) }
        try c.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try c.encodeIfPresent(rate, forKey: .rate)
        if coachingMayBecomeTeamLearning { try c.encode(true, forKey: .coachingMayBecomeTeamLearning) }
    }

    /// A stable id from the entry's own words, for a list that gave none.
    static func derivedId(name: String, phone: String?, handle: String?) -> String {
        // FNV-1a over the normalised fields: stable across launches and builds, unlike `hashValue`.
        let text = [name.lowercased(), phone ?? "", handle?.lowercased() ?? ""].joined(separator: "|")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "x" + String(hash, radix: 16)
    }
}

/// What an escalation record keeps about the expert who was called (Plan KM P0): who, and which
/// kind. Never the rate (decision 6), never the number.
struct ExpertSnapshot: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: EscalationContact.Kind
}

/// A weekly on-call window, in the expert's own time zone. A window whose end is not after its
/// start runs past midnight into the next day ("Fri 22:00–06:00" covers Saturday's small hours).
struct OnCallWindow: Codable, Equatable, Hashable, Sendable {
    /// Gregorian weekday the window starts on: 1 is Sunday, 7 is Saturday (`Calendar`'s numbering).
    let weekday: Int
    /// Minutes after midnight, 0..<1440.
    let startMinute: Int
    /// Minutes after midnight, 1...1440. Not after `startMinute` means the window crosses midnight.
    let endMinute: Int

    static let maxWindows = 28

    init?(weekday: Int, startMinute: Int, endMinute: Int) {
        guard (1...7).contains(weekday), (0..<1440).contains(startMinute), (1...1440).contains(endMinute),
              startMinute != endMinute else { return nil }
        self.weekday = weekday
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    var crossesMidnight: Bool { endMinute <= startMinute }

    /// Whether `date` falls inside this window, read on the wall clock of `timeZone`. Daylight
    /// saving needs nothing of its own: the window is wall-clock time, and the calendar reads the
    /// wall clock the zone had at that instant.
    func contains(_ date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let day = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        let now = hour * 60 + minute
        if crossesMidnight {
            if day == weekday && now >= startMinute { return true }
            return day == weekday % 7 + 1 && now < endMinute
        }
        return day == weekday && now >= startMinute && now < endMinute
    }

    // MARK: - Codable: `{"day": "fri", "start": "22:00", "end": "06:00"}`, as a person writes it.

    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private enum CodingKeys: String, CodingKey { case day, start, end }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let day = try c.decode(String.self, forKey: .day).lowercased()
        guard let index = Self.dayNames.firstIndex(of: String(day.prefix(3))),
              let start = Self.minutes(try c.decode(String.self, forKey: .start), allowingEndOfDay: false),
              let end = Self.minutes(try c.decode(String.self, forKey: .end), allowingEndOfDay: true),
              let window = OnCallWindow(weekday: index + 1, startMinute: start, endMinute: end) else {
            throw DecodingError.dataCorruptedError(forKey: .day, in: c,
                                                   debugDescription: "an on-call window is not a day with HH:mm times")
        }
        self = window
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.dayNames[weekday - 1], forKey: .day)
        try c.encode(Self.clock(startMinute), forKey: .start)
        try c.encode(Self.clock(endMinute), forKey: .end)
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func minutes(_ text: String, allowingEndOfDay: Bool) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<60).contains(minute) else { return nil }
        let total = hour * 60 + minute
        if allowingEndOfDay && total == 1440 { return total }
        return (0..<24).contains(hour) ? total : nil
    }
}

/// Specialty tags: trimmed, at most 40 characters each, once each (case-insensitively), at most
/// `maxTags`. The organisation's spelling is kept for saying back.
enum ExpertSpecialty {
    static let maxTags = 20
    static let maxLength = 40

    static func cleaned(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let tag = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, tag.count <= maxLength, seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// Tags typed as one line: "furnace, heat pump, Lennox".
    static func parse(_ line: String) -> [String] {
        cleaned(line.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).map(String.init))
    }
}

/// An expert the technician added on this phone (Plan KM decision 1). **Always `staff`, never a
/// rate**: this type has neither field, so nothing written to the personal store can carry one, and
/// a stored payload that has them decodes without them.
struct PersonalExpert: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var phone: String?
    var faceTimeHandle: String?
    var handoverChannel: EscalationContact.HandoverChannel?
    var specialties: [String]

    init(id: String = UUID().uuidString, name: String, phone: String? = nil, faceTimeHandle: String? = nil,
         handoverChannel: EscalationContact.HandoverChannel? = nil, specialties: [String] = []) {
        self.id = id
        self.name = name
        self.phone = phone
        self.faceTimeHandle = faceTimeHandle
        self.handoverChannel = handoverChannel
        self.specialties = ExpertSpecialty.cleaned(specialties)
    }

    /// As a list entry: staff, no rate, on call any time.
    var contact: EscalationContact {
        EscalationContact(id: id, name: name, phone: phone, faceTimeHandle: faceTimeHandle,
                          handoverChannel: handoverChannel, specialties: specialties, kind: .staff)
    }
}

/// One row of the merged list, and where it came from.
struct ExpertListEntry: Equatable, Identifiable, Sendable {
    enum Source: String, Equatable, Sendable {
        /// The organisation's list: the profile's `organizationExperts`, or — with no profile — the
        /// device owner's, who is the organisation.
        case organization
        /// The technician's own addition.
        case personal
    }

    let contact: EscalationContact
    let source: Source

    var id: String { contact.id }
}

/// The wire form of an organisation's list: a JSON array of `EscalationContact`, carried as the
/// profile-owned string `organizationExperts` (Plan KM P0) and stored the same way on a phone the
/// device owner set up.
enum ExpertListCodec {
    static let maxExperts = 50

    /// The list, or why it can't be used. Deny by default: one bad entry refuses the whole list,
    /// as every other profile value is refused, so a list never applies half of what it says.
    static func decode(_ text: String) -> Result<[EscalationContact], ExpertListProblem> {
        guard let data = text.data(using: .utf8) else { return .failure(.init("the list is not text")) }
        let list: [EscalationContact]
        do {
            list = try JSONDecoder().decode([EscalationContact].self, from: data)
        } catch DecodingError.dataCorrupted(let context) {
            return .failure(.init(context.debugDescription))
        } catch {
            return .failure(.init("not a list of experts"))
        }
        if list.count > maxExperts { return .failure(.init("more than \(maxExperts) experts")) }
        if let problem = list.lazy.compactMap(\.problem).first { return .failure(.init(problem)) }
        if Set(list.map(\.id)).count != list.count { return .failure(.init("two experts share an id")) }
        return .success(list)
    }

    static func encode(_ list: [EscalationContact]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(list), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

struct ExpertListProblem: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
