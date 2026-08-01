import Foundation
import SwiftUI
import Translation

enum TranslationEngineError: LocalizedError {
    /// No `TranslationSession` served the request in time — host view missing, or the language
    /// pair needs a model download the user hasn't approved.
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "On-device translation didn't respond (the language pair may need downloading)."
        }
    }
}

/// Plan BY P3 — on-device translation via Apple's Translation framework, zero cloud egress.
///
/// The framework only hands out a `TranslationSession` through the SwiftUI
/// `.translationTask(_:action:)` modifier, so this engine is split across that seam:
/// `translate(_:from:to:)` queues a request and (re)publishes a `configuration` for the pair;
/// `TranslationEngineHost` — an invisible view in the app root — runs the task and calls
/// `serve(_:)`, which drains the queue against the live session. Everything is `@MainActor`,
/// so queue/session handoff needs no locking.
@MainActor
final class AppleTranslationEngine: ObservableObject {

    /// Re-publishing (even an equal pair) restarts the translation task; only publish on change.
    @Published private(set) var configuration: TranslationSession.Configuration?

    private struct Request {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var pending: [Request] = []
    private var activeSession: TranslationSession?
    private var currentPair: (source: String?, target: String)?

    /// How long a request may wait for a session before failing (model download prompts are
    /// driven by the host's `prepareTranslation`, not by requests hanging forever).
    let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 10) {
        self.requestTimeout = requestTimeout
    }

    // MARK: - Request side

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        if currentPair?.source != source || currentPair?.target != target {
            currentPair = (source, target)
            activeSession = nil   // the old task's session is for the wrong pair
            configuration = TranslationSession.Configuration(
                source: source.map { Locale.Language(identifier: $0) },
                target: Locale.Language(identifier: target))
        }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Request(id: id, text: text, continuation: continuation))
            drain()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 10) * 1_000_000_000))
                self?.timeOut(id: id)
            }
        }
    }

    // MARK: - Session side (called from TranslationEngineHost)

    func serve(_ session: TranslationSession) async {
        // Surfaces the system download sheet the first time a pair is used. Throws if the user
        // declines — queued requests then fail via timeout, and the provider falls back honestly.
        try? await session.prepareTranslation()
        activeSession = session
        drain()
        // Stay resident so later requests reuse the session; cancellation (config change or
        // host teardown) ends the loop.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            drain()
        }
        if activeSession === session { activeSession = nil }
    }

    // MARK: - Private

    private func drain() {
        guard let session = activeSession else { return }
        while !pending.isEmpty {
            let request = pending.removeFirst()
            Task {
                do {
                    let response = try await session.translate(request.text)
                    request.continuation.resume(returning: response.targetText)
                } catch {
                    request.continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A request still queued after the timeout resumes as failed. Requests already handed to
    /// the session were removed from `pending` by `drain()`, so no double-resume is possible.
    private func timeOut(id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(throwing: TranslationEngineError.timeout)
    }
}

/// Invisible host that gives `AppleTranslationEngine` its `TranslationSession`. Lives in the
/// app root so the session survives navigation.
struct TranslationEngineHost: View {
    @ObservedObject var engine: AppleTranslationEngine

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .translationTask(engine.configuration) { session in
                await engine.serve(session)
            }
    }
}
