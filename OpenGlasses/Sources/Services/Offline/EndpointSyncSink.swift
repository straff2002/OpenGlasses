import Foundation

/// Delivers job records and stock checks to the organisation's own endpoint (Plan EM §5).
///
/// The unattended half of delivery: the composer needs a thumb, and this needs nothing — which is
/// exactly why it only ever runs when an organisation has configured an endpoint. With none
/// configured every operation falls through to the sink that was there before, so a device that
/// has not been told where base is behaves precisely as it did.
///
/// It handles the two Plan EM kinds and delegates every other kind, because photo uploads, audit
/// exports and grounding requests are not this plan's payloads and inventing a shape for them here
/// would commit an endpoint we have never spoken to.
@MainActor
final class EndpointSyncSink: SyncSink {

    private let fallback: SyncSink
    private let session: URLSession
    private let endpoint: () -> URL?
    private let token: () -> String

    /// Ops this sink is responsible for; everything else is the fallback's.
    static let handledKinds: Set<OpKind> = [.workRecord, .partsRequest]

    /// `endpoint` and `token` are read per delivery rather than captured, so changing the setting
    /// takes effect on the next flush instead of the next launch.
    init(fallback: SyncSink,
         session: URLSession = .shared,
         endpoint: @escaping () -> URL? = { DeliverySettings.load().endpointURL },
         token: @escaping () -> String = { DeliverySettings.load().endpointToken }) {
        self.fallback = fallback
        self.session = session
        self.endpoint = endpoint
        self.token = token
    }

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard Self.handledKinds.contains(op.kind), let configured = endpoint() else {
            return await fallback.deliver(op)
        }
        // A queued work record can carry a clinical fact, so the flush asks before it drains.
        guard let url = try? EndpointPolicy.requireOpenable(url: configured, for: .offlineEndpointSync) else {
            return .transient(reason: "the sync endpoint is not permitted right now")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The op id is stable across retries, so a receiver that honours this cannot be made to
        // file the same visit twice by a flaky connection.
        request.setValue(op.id, forHTTPHeaderField: "Idempotency-Key")
        let bearer = token().trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.body(for: op)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transient(reason: "the endpoint answered with something that isn't HTTP")
            }
            return Self.outcome(status: http.statusCode, data: data)
        } catch {
            // Offline, DNS, timeout, TLS: all worth trying again, and none worth losing the record.
            return .transient(reason: error.localizedDescription)
        }
    }

    /// The envelope: what kind of thing this is, which visit it belongs to, and the payload exactly
    /// as the queue holds it — the same bytes `WorkRecord.json` produced, so what a receiver stores
    /// and what the technician confirmed cannot drift apart.
    static func body(for op: QueuedOp) -> Data {
        var envelope: [String: Any] = [
            "op": op.kind.rawValue,
            "op_id": op.id,
            "session_id": op.sessionId,
            "created_at": ISO8601DateFormatter().string(from: op.createdAt)
        ]
        if let job = op.payloadJSON["job_reference"] as? String, !job.isEmpty {
            envelope["job_reference"] = job
        }
        envelope["payload"] = op.payloadJSON
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    /// Status to outcome, in the queue's own vocabulary.
    ///
    /// A 409 is the only 4xx that is a conflict rather than a refusal: it is the receiver saying
    /// the job moved on while the device was offline, which is what `ConflictResolver` was written
    /// for. Everything else in the 4xx range is a request this device will never get right by
    /// repeating it, so it fails rather than burning six attempts.
    static func outcome(status: Int, data: Data) -> SyncOutcome {
        switch status {
        case 200...299:
            return .done
        case 409:
            return .conflict(reason: reason(data) ?? "the office already has a different version of this job")
        case 401, 403:
            return .permanent(reason: "the office endpoint rejected the credentials"
                              + (reason(data).map { " (\($0))" } ?? ""))
        case 400...499:
            return .permanent(reason: reason(data) ?? "the office endpoint refused it (\(status))")
        default:
            return .transient(reason: reason(data) ?? "the office endpoint is having trouble (\(status))")
        }
    }

    /// A short reason out of the response body, when it offers one. Truncated: an error line
    /// belongs in a log and on a badge, not a whole HTML page.
    private static func reason(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "detail", "reason"] {
                if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(200)) }
            }
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}
