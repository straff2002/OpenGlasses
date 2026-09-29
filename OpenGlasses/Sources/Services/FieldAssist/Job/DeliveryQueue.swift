import Foundation

/// One report or addendum waiting to go out (Plan FO §6, P3b).
///
/// **This is not the offline store-and-forward queue.** That one holds records already authorised
/// to an endpoint and retries them; this one holds sends a technician asked for from the car,
/// where the ones that need a composer cannot be completed until the phone is in their hand
/// again. Keeping them apart is what stops "queued" meaning two different things — one of which
/// sends itself and one of which never will without a tap.
struct QueuedSend: Codable, Equatable, Identifiable {

    /// What is going: the work order itself, or a debrief appended to a job whose report has
    /// already gone. An addendum is a **second document**; it never rewrites the original.
    enum DocumentKind: String, Codable, Equatable {
        case report
        case addendum

        var label: String {
            switch self {
            case .report: return "Work order"
            case .addendum: return "Debrief addendum"
            }
        }

        /// How the confirmation names it mid-sentence.
        var spokenName: String {
            switch self {
            case .report: return "the work order"
            case .addendum: return "the debrief addendum"
            }
        }
    }

    /// Where the addresses came from. Recorded because "who did this go to, and who decided that?"
    /// is the question an audit actually asks — and because **speech is never one of the answers**.
    enum RecipientSource: String, Codable, Equatable {
        /// The job's own previous delivery.
        case previousDelivery = "previous_delivery"
        /// The vault's delivery settings on this device.
        case deliverySettings = "delivery_settings"
        /// The organisation's profile.
        case organisationProfile = "organisation_profile"
        /// The channel addresses itself — the share sheet, the endpoint.
        case channelOwned = "channel_owned"

        var label: String {
            switch self {
            case .previousDelivery: return "the job's last delivery"
            case .deliverySettings: return "this device's job-report settings"
            case .organisationProfile: return "the organisation profile"
            case .channelOwned: return "the channel itself"
            }
        }
    }

    /// Where the send has got to.
    enum State: String, Codable, Equatable {
        /// Goes without a screen, as soon as it can.
        case immediate
        /// Prepared and waiting for the technician's tap.
        case staged
        /// In flight on an immediate channel.
        case sending
        case sent
        case failed
        case cancelled

        /// Whether this entry is still waiting on somebody or something.
        var isWaiting: Bool { self == .immediate || self == .staged || self == .sending }
    }

    let id: String
    let sessionId: String
    /// "Job 1005" or "No job number" — what the card and the read-back say. Held rather than
    /// re-derived so a queue entry still names its job after the session it came from was deleted.
    let jobNumber: String
    let documentKind: DocumentKind
    let channel: DeliveryChannel
    let recipients: [String]
    let recipientSource: RecipientSource
    let createdAt: Date
    var updatedAt: Date
    var attempts: Int
    var state: State
    /// Why the last attempt failed, when one did.
    var failureReason: String?

    init(id: String = UUID().uuidString, sessionId: String, jobNumber: String,
         documentKind: DocumentKind, channel: DeliveryChannel, recipients: [String],
         recipientSource: RecipientSource, createdAt: Date = Date(),
         updatedAt: Date? = nil, attempts: Int = 0, state: State,
         failureReason: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.jobNumber = jobNumber
        self.documentKind = documentKind
        self.channel = channel
        self.recipients = recipients
        self.recipientSource = recipientSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.attempts = attempts
        self.state = state
        self.failureReason = failureReason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case jobNumber = "job_number"
        case documentKind = "document_kind"
        case channel
        case recipients
        case recipientSource = "recipient_source"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case attempts
        case state
        case failureReason = "failure_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        jobNumber = try c.decodeIfPresent(String.self, forKey: .jobNumber) ?? JobTabModel.noJobNumber
        documentKind = try c.decodeIfPresent(DocumentKind.self, forKey: .documentKind) ?? .report
        channel = try c.decode(DeliveryChannel.self, forKey: .channel)
        recipients = try c.decodeIfPresent([String].self, forKey: .recipients) ?? []
        recipientSource = try c.decodeIfPresent(RecipientSource.self, forKey: .recipientSource)
            ?? .deliverySettings
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .staged
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
    }

    /// "Work order · Job 1005 · email to office@example.com" — the card's row.
    var summaryLine: String {
        var line = "\(documentKind.label) · \(jobNumber) · \(channel.label)"
        if !recipients.isEmpty { line += " to \(recipients.joined(separator: ", "))" }
        return line
    }
}

/// The reports waiting to go out, in the order they were asked for (Plan FO §6, P3b).
///
/// Pure and `Codable`: ordering, cancelling and the read-back are provable without a file, and the
/// store below is the only thing that touches a disk. Per device, and deliberately not merged with
/// the offline queue.
struct DeliveryQueue: Codable, Equatable {

    /// Everything ever queued on this device, newest last. Sent and cancelled entries are kept
    /// for the read-back's sake — "did that go?" is the question the queue exists to answer —
    /// bounded so a year of jobs cannot grow without limit.
    private(set) var entries: [QueuedSend]

    /// How many entries are kept. Oldest settled ones are evicted first; a waiting entry is never
    /// evicted, because an entry nobody sent is the one thing this must not lose.
    static let entryCap = 200

    init(entries: [QueuedSend] = []) {
        self.entries = entries
    }

    // MARK: - Reading

    /// The ones still waiting, oldest first — the order Send all opens them in.
    var waiting: [QueuedSend] {
        entries.filter { $0.state.isWaiting }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The ones a tap will complete: staged, and prepared.
    var staged: [QueuedSend] { waiting.filter { $0.state == .staged } }

    var stagedCount: Int { staged.count }

    func entry(id: String) -> QueuedSend? { entries.first { $0.id == id } }

    /// Everything queued against one job, newest first.
    func entries(sessionId: String) -> [QueuedSend] {
        entries.filter { $0.sessionId == sessionId }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Writing

    mutating func append(_ entry: QueuedSend) {
        entries.append(entry)
        evict()
    }

    /// Move one entry along. A no-op for an id the queue does not hold, so a composer that closed
    /// after the entry was cancelled cannot resurrect it.
    mutating func update(id: String, to state: QueuedSend.State, at now: Date = Date(),
                         failureReason: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // A cancelled entry stays cancelled: the technician said no.
        guard entries[index].state != .cancelled || state == .staged else { return }
        entries[index].state = state
        entries[index].updatedAt = now
        entries[index].failureReason = failureReason
        if state == .sending || state == .sent || state == .failed { entries[index].attempts += 1 }
        evict()
    }

    /// The technician cancelled one. **Every other entry stays exactly where it was** — a
    /// cancelled composer in the middle of Send all must not take the rest of the queue with it.
    mutating func cancel(id: String, at now: Date = Date()) {
        update(id: id, to: .cancelled, at: now)
    }

    /// Drop settled entries past the cap, oldest first. Waiting entries are never dropped.
    private mutating func evict() {
        guard entries.count > Self.entryCap else { return }
        var settled = entries.enumerated()
            .filter { !$0.element.state.isWaiting }
            .sorted { $0.element.updatedAt < $1.element.updatedAt }
        var removable = entries.count - Self.entryCap
        var doomed = Set<String>()
        while removable > 0, let oldest = settled.first {
            doomed.insert(oldest.element.id)
            settled.removeFirst()
            removable -= 1
        }
        guard !doomed.isEmpty else { return }
        entries.removeAll { doomed.contains($0.id) }
    }

    // MARK: - How it reads

    /// "3 reports ready to send" — the card's headline, and nil when there is nothing waiting.
    var cardHeadline: String? {
        let count = stagedCount
        guard count > 0 else { return nil }
        return count == 1 ? "1 report ready to send" : "\(count) reports ready to send"
    }

    /// What "what's waiting?" says in the car. Names every staged report and who it goes to, then
    /// where it can be sent — because the answer a technician needs is "not yet, and here is why".
    var spokenReadBack: String {
        let ready = staged
        guard !ready.isEmpty else {
            let recentlySent = entries.filter { $0.state == .sent }.count
            return recentlySent > 0
                ? "Nothing's waiting. Everything you asked for has gone."
                : "Nothing's waiting to send."
        }
        var lines = [ready.count == 1
                     ? "One report is ready to send."
                     : "\(ready.count) reports are ready to send."]
        lines.append(contentsOf: ready.map { entry in
            let who = entry.recipients.isEmpty ? "" : " to \(entry.recipients.joined(separator: ", "))"
            return "\(entry.documentKind.spokenName.capitalisedFirst) for \(entry.jobNumber), "
                + "by \(entry.channel.spokenName)\(who)."
        })
        lines.append("They need one tap each on the phone — I can't send those from the car.")
        return lines.joined(separator: " ")
    }
}

private extension String {
    /// "the work order" → "The work order". Only the first character, so a job number keeps its
    /// shape.
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

/// Where the delivery queue lives (Plan FO §6, P3b).
///
/// One JSON file in Application Support, beside the other Field Assist state, loaded at
/// construction and written on every change. Registered in `DataStoreRegistry` as
/// `jobDeliveryQueue`: it holds recipient addresses, which are somebody's contact details, so it
/// is protected and excluded from backup rather than left to the container's default.
@MainActor
final class DeliveryQueueStore: ObservableObject {

    @Published private(set) var queue: DeliveryQueue

    private let fileURL: URL

    /// The default location, and the one the registry documents.
    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FieldAssist", isDirectory: true)
    }

    /// The queue's file. Named here rather than spelled out again by anyone who has to reach it,
    /// so a reset and the store cannot drift apart onto two different paths.
    nonisolated static func fileURL(in directory: URL? = nil) -> URL {
        (directory ?? defaultDirectory()).appendingPathComponent("delivery-queue.json")
    }

    /// Delete the stored queue outright, for a caller that has to start from no queue at all.
    ///
    /// Distinct from `removeAll()`, which empties a queue *through* a live store and writes the
    /// emptiness back. This is for the moment before a store exists — the UI-test seed, which
    /// resets the device's field state at launch and would otherwise inherit whatever the
    /// simulator was left holding.
    nonisolated static func eraseStoredQueue(in directory: URL? = nil) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }

    init(directory: URL? = nil) {
        let url = Self.fileURL(in: directory)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        fileURL = url
        queue = Self.read(url) ?? DeliveryQueue()
        protectFile()
    }

    // MARK: - Mutations

    func append(_ entry: QueuedSend) {
        queue.append(entry)
        save()
    }

    func update(id: String, to state: QueuedSend.State, failureReason: String? = nil) {
        queue.update(id: id, to: state, failureReason: failureReason)
        save()
    }

    func cancel(id: String) {
        queue.cancel(id: id)
        save()
    }

    /// Everything, for a wipe. Used by nothing in the app today; present so the registry's
    /// "what deletes this?" column is an API and not a shrug.
    func removeAll() {
        queue = DeliveryQueue()
        save()
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> DeliveryQueue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeliveryQueue.self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(queue) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        protectFile()
    }

    /// Complete protection and no backup: the entries carry customers' addresses, and a queue
    /// restored onto another phone would offer to send a report somebody already sent.
    private func protectFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
