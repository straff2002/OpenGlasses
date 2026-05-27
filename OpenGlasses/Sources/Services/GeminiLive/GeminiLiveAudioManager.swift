import AVFoundation
import Foundation

/// Dedicated audio engine for Gemini Live mode.
/// Captures microphone input as 16kHz Int16 PCM and plays back 24kHz Int16 PCM from Gemini.
/// Separate from WakeWordService's audio engine — the two cannot coexist.
class GeminiLiveAudioManager {
    var onAudioCaptured: ((Data) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isCapturing = false

    private let outputFormat: AVAudioFormat

    // Accumulate resampled PCM into ~100ms chunks before sending
    private let sendQueue = DispatchQueue(label: "audio.accumulator")
    private var accumulatedData = Data()
    private let minSendBytes = 3200  // 100ms at 16kHz mono Int16 = 1600 frames × 2 bytes

    init() {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Config.geminiLiveOutputSampleRate,
            channels: Config.geminiLiveAudioChannels,
            interleaved: true
        )!
    }

    /// Configure the audio session for Gemini Live.
    /// - Parameter useIPhoneMode: `true` for `.voiceChat` (iPhone mic), `false` for `.videoChat` (glasses mic).
    func setupAudioSession(useIPhoneMode: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = useIPhoneMode ? .voiceChat : .videoChat
        try session.setCategory(
            .playAndRecord,
            mode: mode,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(Config.geminiLiveInputSampleRate)
        try session.setPreferredIOBufferDuration(0.064)
        try session.setActive(true)
        NSLog("[Audio] Session mode: %@", useIPhoneMode ? "voiceChat (iPhone)" : "videoChat (glasses)")
    }

    /// Start capturing microphone audio and sending chunks via `onAudioCaptured`.
    func startCapture() throws {
        guard !isCapturing else { return }

        // Attach player node for playback
        audioEngine.attach(playerNode)
        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.geminiLiveOutputSampleRate,
            channels: Config.geminiLiveAudioChannels,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        let inputNode = audioEngine.inputNode
        let inputNativeFormat = inputNode.outputFormat(forBus: 0)

        NSLog("[Audio] Native input format: %@ sampleRate=%.0f channels=%d",
              inputNativeFormat.commonFormat == .pcmFormatFloat32 ? "Float32" :
              inputNativeFormat.commonFormat == .pcmFormatInt16 ? "Int16" : "Other",
              inputNativeFormat.sampleRate, inputNativeFormat.channelCount)

        let needsResample = inputNativeFormat.sampleRate != Config.geminiLiveInputSampleRate
            || inputNativeFormat.channelCount != Config.geminiLiveAudioChannels

        NSLog("[Audio] Needs resample: %@", needsResample ? "YES" : "NO")

        sendQueue.async { self.accumulatedData = Data() }

        var converter: AVAudioConverter?
        if needsResample {
            let resampleFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Config.geminiLiveInputSampleRate,
                channels: Config.geminiLiveAudioChannels,
                interleaved: false
            )!
            converter = AVAudioConverter(from: inputNativeFormat, to: resampleFormat)
        }

        var tapCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            tapCount += 1
            let pcmData: Data

            if let converter {
                let resampleFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Config.geminiLiveInputSampleRate,
                    channels: Config.geminiLiveAudioChannels,
                    interleaved: false
                )!
                guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: resampleFormat) else {
                    if tapCount <= 3 { NSLog("[Audio] Resample failed for tap #%d", tapCount) }
                    return
                }
                pcmData = self.float32BufferToInt16Data(resampled)
            } else {
                pcmData = self.float32BufferToInt16Data(buffer)
            }

            self.sendQueue.async {
                self.accumulatedData.append(pcmData)
                if self.accumulatedData.count >= self.minSendBytes {
                    let chunk = self.accumulatedData
                    self.accumulatedData = Data()
                    if tapCount <= 3 {
                        NSLog("[Audio] Sending chunk: %d bytes (~%dms)",
                              chunk.count, chunk.count / 32)
                    }
                    self.onAudioCaptured?(chunk)
                }
            }
        }

        try audioEngine.start()
        playerNode.play()
        isCapturing = true
    }

    /// Play received PCM audio data (Int16 at 24kHz) through the speaker.
    func playAudio(data: Data) {
        guard isCapturing, !data.isEmpty else { return }

        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.geminiLiveOutputSampleRate,
            channels: Config.geminiLiveAudioChannels,
            interleaved: false
        )!

        let frameCount = UInt32(data.count) / (Config.geminiLiveAudioBitsPerSample / 8 * Config.geminiLiveAudioChannels)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frameCount) {
                floatData[0][i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }

        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Stop playback but keep the engine running (used when interrupted).
    func stopPlayback() {
        playerNode.stop()
        playerNode.play()
    }

    /// Stop capture and tear down the audio engine.
    func stopCapture() {
        guard isCapturing else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isCapturing = false
        // Flush any remaining accumulated audio
        sendQueue.async {
            if !self.accumulatedData.isEmpty {
                let chunk = self.accumulatedData
                self.accumulatedData = Data()
                self.onAudioCaptured?(chunk)
            }
        }
    }

    // MARK: - Private Helpers

    private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
        var int16Array = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1.0, min(1.0, floatData[0][i]))
            int16Array[i] = Int16(sample * Float(Int16.max))
        }
        return int16Array.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil {
            return nil
        }

        return outputBuffer
    }
}
