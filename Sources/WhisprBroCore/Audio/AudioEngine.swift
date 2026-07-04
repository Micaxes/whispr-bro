import Accelerate
import AVFoundation
import Foundation

/// Always-running microphone capture producing 16kHz mono Float32 into a
/// `PreRollBuffer` (spec §4). The engine runs continuously so the 500ms
/// pre-roll is warm before the hotkey is ever pressed.
public final class AudioEngine: @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let buffer: PreRollBuffer
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioEngine.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Most recent block RMS, for the HUD waveform (task-008) and menu-bar
    /// level hinting today. Written from the audio thread; read-only elsewhere.
    public private(set) var lastRMS: Float = 0

    public init(preRollSeconds: Double = 0.5) {
        self.buffer = PreRollBuffer(
            preRollSampleCount: Int(preRollSeconds * Self.targetSampleRate)
        )
    }

    public func start() throws {
        guard converter == nil else { return } // already running
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw WhisprError.audioConverterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.process(pcmBuffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    public func beginUtterance() {
        buffer.beginUtterance()
    }

    /// Returns 16kHz mono samples: pre-roll + everything captured during the hold.
    public func endUtterance() -> [Float] {
        buffer.endUtterance()
    }

    // MARK: - Audio thread (AVAudioEngine tap queue — not the realtime render thread)

    private func process(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(pcmBuffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        guard status != .error, let channelData = out.floatChannelData else { return }

        let count = Int(out.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(count))
        lastRMS = rms

        buffer.append(samples)
    }
}
