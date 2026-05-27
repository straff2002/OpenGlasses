import AVFoundation
import Foundation

/// Audio engine for OpenAI Realtime mode.
/// Both input and output use 24kHz Int16 PCM mono (OpenAI's native format).
/// Includes client-side amplitude-based voice activity detection for fast interrupts.
class OpenAIRealtimeAudioManager {
    var onAudioCaptured: ((Data) -> Void)?

    /// Fires when the user's voice amplitude exceeds the interrupt threshold
    /// while the model is speaking. Faster than waiting for server VAD.
    var onVoiceInterrupt: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isCapturing = false

    // Audio format: 24kHz PCM16 mono for both directions
    static let sampleRate: Double = 24000
    static let channels: UInt32 = 1
    static let bitsPerSample: UInt32 = 16

    // Accumulate resampled PCM into ~100ms chunks before sending
    private let sendQueue = DispatchQueue(label: "openai.audio.accumulator")
    private var accumulatedData = Data()
    private let minSendBytes = 4800  // 100ms at 24kHz mono Int16 = 2400 frames * 2 bytes

    // Client-side VAD for interruption
    private var isModelCurrentlySpeaking = false
    private let interruptAmplitudeThreshold: Float = 0.05
    private var consecutiveHighFrames = 0
    private let requiredHighFrames = 3  // ~3 buffers above threshold to trigger

    /// Set this from the session manager to enable/disable interrupt detection.
    var modelSpeaking: Bool {
        get { isModelCurrentlySpeaking }
        set {
            isModelCurrentlySpeaking = newValue
            if !newValue { consecutiveHighFrames = 0 }
        }
    }

    /// Configure the audio session for OpenAI Realtime.
    func setupAudioSession(useIPhoneMode: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = useIPhoneMode ? .voiceChat : .videoChat
        try session.setCategory(
            .playAndRecord,
            mode: mode,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setPreferredIOBufferDuration(0.064)
        try session.setActive(true)
        NSLog("[OpenAI Audio] Session mode: %@", useIPhoneMode ? "voiceChat" : "videoChat")
    }

    /// Start capturing microphone audio.
    func startCapture() throws {
        guard !isCapturing else { return }

        audioEngine.attach(playerNode)
        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        let inputNode = audioEngine.inputNode
        let inputNativeFormat = inputNode.outputFormat(forBus: 0)

        let needsResample = inputNativeFormat.sampleRate != Self.sampleRate
            || inputNativeFormat.channelCount != Self.channels

        NSLog("[OpenAI Audio] Native: %.0fHz %dch, needs resample: %@",
              inputNativeFormat.sampleRate, inputNativeFormat.channelCount,
              needsResample ? "YES" : "NO")

        sendQueue.async { self.accumulatedData = Data() }

        var converter: AVAudioConverter?
        if needsResample {
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: Self.channels,
                interleaved: false
            )!
            converter = AVAudioConverter(from: inputNativeFormat, to: targetFormat)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let pcmData: Data
            let amplitudeBuffer: AVAudioPCMBuffer

            if let converter {
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Self.sampleRate,
                    channels: Self.channels,
                    interleaved: false
                )!
                guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: targetFormat) else {
                    return
                }
                pcmData = self.float32ToInt16Data(resampled)
                amplitudeBuffer = resampled
            } else {
                pcmData = self.float32ToInt16Data(buffer)
                amplitudeBuffer = buffer
            }

            // Client-side VAD: check amplitude for fast interrupt
            if self.isModelCurrentlySpeaking {
                let rms = self.calculateRMS(amplitudeBuffer)
                if rms > self.interruptAmplitudeThreshold {
                    self.consecutiveHighFrames += 1
                    if self.consecutiveHighFrames >= self.requiredHighFrames {
                        NSLog("[OpenAI Audio] Client VAD interrupt (RMS: %.4f)", rms)
                        self.consecutiveHighFrames = 0
                        self.onVoiceInterrupt?()
                    }
                } else {
                    self.consecutiveHighFrames = 0
                }
            }

            self.sendQueue.async {
                self.accumulatedData.append(pcmData)
                if self.accumulatedData.count >= self.minSendBytes {
                    let chunk = self.accumulatedData
                    self.accumulatedData = Data()
                    self.onAudioCaptured?(chunk)
                }
            }
        }

        try audioEngine.start()
        playerNode.play()
        isCapturing = true
    }

    /// Play received PCM audio (Int16 24kHz mono).
    func playAudio(data: Data) {
        guard isCapturing, !data.isEmpty else { return }

        let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        )!

        let frameCount = UInt32(data.count) / (Self.bitsPerSample / 8 * Self.channels)
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

    /// Stop playback but keep engine running (used on interrupt).
    func stopPlayback() {
        playerNode.stop()
        playerNode.play()
    }

    /// Stop capture and tear down.
    func stopCapture() {
        guard isCapturing else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
        isCapturing = false
        sendQueue.async {
            if !self.accumulatedData.isEmpty {
                let chunk = self.accumulatedData
                self.accumulatedData = Data()
                self.onAudioCaptured?(chunk)
            }
        }
    }

    // MARK: - Private

    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = floatData[0][i]
            sum += sample * sample
        }
        return sqrtf(sum / Float(count))
    }

    private func float32ToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
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

        return error == nil ? outputBuffer : nil
    }
}
