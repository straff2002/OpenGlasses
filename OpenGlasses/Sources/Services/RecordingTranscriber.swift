@preconcurrency import AVFoundation
import Foundation

enum RecordingTranscriptionOutcome: Equatable, Sendable {
    case success(String)
    case failure(String)
    case unavailable(String)
}

/// Post-processes preserved recordings. Cloud diarization is preferred when configured (and not
/// HIPAA-locked); the downloaded on-device SenseVoice model is the private/offline fallback.
@MainActor
final class RecordingTranscriber {
    private let deepgram: DeepgramBatchService
    private let onDeviceEngine: OnDeviceASREngine
    private let chunkDuration: TimeInterval

    init(
        deepgram: DeepgramBatchService = DeepgramBatchService(),
        onDeviceEngine: OnDeviceASREngine? = nil,
        chunkDuration: TimeInterval = 30
    ) {
        self.deepgram = deepgram
        self.onDeviceEngine = onDeviceEngine ?? OnDeviceASREngine()
        self.chunkDuration = chunkDuration
    }

    func transcribe(fileURL: URL) async -> RecordingTranscriptionOutcome {
        var providerFailures: [String] = []
        let canUseDeepgram = !Config.deepgramAPIKey.isEmpty
            && !Config.hipaaMode

        if canUseDeepgram {
            do {
                let turns = try await deepgram.diarize(
                    fileURL: fileURL,
                    mimeType: "audio/m4a"
                )
                let transcript = Self.join(turns: turns)
                if !transcript.isEmpty {
                    return .success(transcript)
                }
                providerFailures.append("Deepgram returned no transcript.")
            } catch {
                providerFailures.append(error.localizedDescription)
            }
        }

        guard onDeviceEngine.isReady else {
            if providerFailures.isEmpty {
                return .unavailable(
                    "Configure Deepgram or download the on-device speech recognition model."
                )
            }
            return .failure(providerFailures.joined(separator: " "))
        }

        do {
            let reader = try RecordingAudioChunkReader(
                fileURL: fileURL,
                chunkDuration: chunkDuration
            )
            var transcriptChunks: [String] = []

            while let chunk = try await reader.nextChunk() {
                try Task.checkCancellation()
                let text = try await onDeviceEngine.transcribe(
                    samples: chunk.samples,
                    sampleRate: chunk.sampleRate
                )
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    transcriptChunks.append(cleaned)
                }
            }

            return .success(transcriptChunks.joined(separator: "\n"))
        } catch is CancellationError {
            return .failure("Transcription was cancelled.")
        } catch {
            providerFailures.append(error.localizedDescription)
            return .failure(providerFailures.joined(separator: " "))
        }
    }

    static func join(turns: [SpeakerTurn]) -> String {
        let usableTurns = turns.compactMap { turn -> SpeakerTurn? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SpeakerTurn(
                speaker: turn.speaker,
                text: text,
                start: turn.start,
                end: turn.end
            )
        }
        let hasMultipleSpeakers = Set(usableTurns.compactMap(\.speaker)).count > 1

        return usableTurns.map { turn in
            if hasMultipleSpeakers, let speaker = turn.speaker {
                return "Speaker \(speaker + 1): \(turn.text)"
            }
            return turn.text
        }
        .joined(separator: hasMultipleSpeakers ? "\n" : " ")
    }
}

private struct RecordingAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

/// Owns the decoder off the main actor and yields only one bounded PCM window at a time. A long
/// recording therefore never accumulates its decoded audio in memory while ASR is running.
private actor RecordingAudioChunkReader {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let frameCapacity: AVAudioFrameCount

    init(fileURL: URL, chunkDuration: TimeInterval) throws {
        guard chunkDuration > 0 else {
            throw RecordingTranscriberError.invalidAudioFormat
        }

        let file = try AVAudioFile(
            forReading: fileURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingTranscriberError.invalidAudioFormat
        }

        let requestedFrames = max(1, Int(format.sampleRate * chunkDuration))
        self.file = file
        self.format = format
        self.frameCapacity = AVAudioFrameCount(min(requestedFrames, Int(UInt32.max)))
    }

    func nextChunk() throws -> RecordingAudioChunk? {
        try Task.checkCancellation()
        guard file.framePosition < file.length else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            throw RecordingTranscriberError.couldNotAllocateBuffer
        }

        try file.read(into: buffer, frameCount: frameCapacity)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        guard let channelData = buffer.floatChannelData else {
            throw RecordingTranscriberError.unsupportedPCMFormat
        }

        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: channelData[0], count: frameCount)
            }
        } else {
            let scale = 1 / Float(channelCount)
            for channel in 0..<channelCount {
                let source = channelData[channel]
                for frame in 0..<frameCount {
                    mono[frame] += source[frame] * scale
                }
            }
        }

        return RecordingAudioChunk(samples: mono, sampleRate: format.sampleRate)
    }
}

private enum RecordingTranscriberError: LocalizedError {
    case invalidAudioFormat
    case couldNotAllocateBuffer
    case unsupportedPCMFormat

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            return "The recording has an invalid audio format."
        case .couldNotAllocateBuffer:
            return "The recording could not be decoded."
        case .unsupportedPCMFormat:
            return "The recording's decoded PCM format is unsupported."
        }
    }
}
