import Combine
import Foundation

enum TranscriptionState: String, Codable, Sendable {
    case pending
    case transcribing
    case done
    case failed
    case unavailable
}

struct RecordedSession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var audioFileName: String
    var transcript: String
    var state: TranscriptionState
    var failureReason: String?

    /// Applies a post-recording result without letting an empty recognizer result erase
    /// useful live captions collected while the recording was in progress.
    func applyingTranscription(
        _ postHocTranscript: String,
        state newState: TranscriptionState,
        failureReason newFailureReason: String? = nil
    ) -> RecordedSession {
        var updated = self
        let cleanedTranscript = postHocTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTranscript.isEmpty {
            updated.transcript = cleanedTranscript
        }
        updated.state = newState
        updated.failureReason = newFailureReason
        return updated
    }
}

/// Persists meeting recordings' metadata + transcript as JSON in Documents, alongside the audio
/// files that `AudioRecordingService` already saves under Documents/Recordings/.
@MainActor
final class RecordedSessionStore: ObservableObject {
    @Published private(set) var sessions: [RecordedSession] = []

    static let storageFileName = "recorded_sessions.json"
    static let recordingsDirectoryName = "Recordings"

    private let documentsDirectory: URL
    private let fileManager: FileManager

    init(
        documentsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        loadImmediately: Bool = true
    ) {
        self.fileManager = fileManager
        self.documentsDirectory = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        if loadImmediately {
            load()
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: storageURL)
            sessions = try JSONDecoder().decode([RecordedSession].self, from: data)
                .map(Self.normalized)
            sortNewestFirst()
        } catch {
            sessions = []
        }
    }

    func add(_ session: RecordedSession) {
        let normalized = Self.normalized(session)
        sessions.removeAll { $0.id == normalized.id }
        sessions.append(normalized)
        sortNewestFirst()
        persist()
    }

    func update(_ session: RecordedSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = Self.normalized(session)
        sortNewestFirst()
        persist()
    }

    func delete(_ session: RecordedSession) {
        let storedSession = sessions.first(where: { $0.id == session.id }) ?? session
        sessions.removeAll { $0.id == session.id }

        let fileName = Self.bareFileName(storedSession.audioFileName)
        if !fileName.isEmpty {
            let fileURL = recordingsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                PrivacyLog.store(.recordedSessions, .deleteFailed, error: SafeErrorSummary(error))
            }
        }

        persist()
    }

    /// Rebuilds the audio location from this launch's Documents container. Only the bare
    /// filename is persisted because an iOS sandbox's absolute container path is not stable.
    func audioURL(for session: RecordedSession) -> URL {
        recordingsDirectoryURL
            .appendingPathComponent(Self.bareFileName(session.audioFileName), isDirectory: false)
    }

    private var storageURL: URL {
        documentsDirectory.appendingPathComponent(Self.storageFileName, isDirectory: false)
    }

    private var recordingsDirectoryURL: URL {
        documentsDirectory.appendingPathComponent(Self.recordingsDirectoryName, isDirectory: true)
    }

    private func sortNewestFirst() {
        sessions.sort {
            if $0.startedAt == $1.startedAt {
                return $0.id.uuidString > $1.id.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            PrivacyLog.store(.recordedSessions, .saveFailed, error: SafeErrorSummary(error))
        }
    }

    private static func normalized(_ session: RecordedSession) -> RecordedSession {
        var session = session
        session.audioFileName = bareFileName(session.audioFileName)
        return session
    }

    private static func bareFileName(_ value: String) -> String {
        let fileName = (value as NSString).lastPathComponent
        return fileName == "." || fileName == ".." ? "" : fileName
    }
}
