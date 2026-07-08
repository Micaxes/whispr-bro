import Accelerate
import AVFoundation
import Foundation

/// On-demand microphone capture producing 16kHz mono Float32 into a
/// `PreRollBuffer` (spec §4).
///
/// The engine is **prepared** once (graph built, tap installed, resources
/// preallocated) but the input IOProc is started only while a dictation is
/// actually in progress, so the macOS microphone indicator is lit **only while
/// dictating** — matching Wispr Flow / VoiceInk's "prepare-ahead, start-late"
/// pattern. `prepare()` does not run the input IOProc, so it does not light the
/// orange dot; only `startCapture()` (`engine.start()`) does. On Apple Silicon
/// the built-in mic goes live within ~100ms of `start()`, which human reaction
/// time (~200–500ms before the first phoneme) hides — so on-demand start does
/// not clip the first word. (Bluetooth mics negotiate SCO/HFP for 1–3s and are
/// the one case where a warm stream would help; not handled here.)
public final class AudioEngine: @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let buffer: PreRollBuffer
    private var converter: AVAudioConverter?
    /// The hardware input format the current tap/converter were built for. Used
    /// to detect a device/route change and rebuild before the next capture (a
    /// stale tap format asserts inside `engine.start()`).
    private var preparedFormat: AVAudioFormat?
    private var capturing = false
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

    // MARK: - Lifecycle

    /// Build the capture graph (converter + tap) and preallocate resources
    /// WITHOUT starting the input IOProc. Idempotent. Does NOT light the mic
    /// indicator — call this at bring-up so `startCapture()` is a fast, warm
    /// start later. Rebuilds automatically if the hardware input format changed.
    public func prepare() throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if converter != nil, let prepared = preparedFormat, prepared == inputFormat {
            return // already prepared for this device
        }
        // Rebuild for a fresh/changed device.
        if converter != nil { engine.inputNode.removeTap(onBus: 0) }
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw WhisprError.audioConverterUnavailable
        }
        self.converter = converter
        self.preparedFormat = inputFormat

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.process(pcmBuffer)
        }
        engine.prepare()
    }

    /// Start the input IOProc — this lights the mic indicator. Fast because
    /// `prepare()` already did the expensive setup. Safe to call repeatedly;
    /// re-prepares first if the input device/format changed.
    public func startCapture() throws {
        guard !capturing else { return }
        try prepare()
        try engine.start()
        capturing = true
    }

    /// Stop the input IOProc — this clears the mic indicator (sub-second on a
    /// clean stop). Keeps the tap and converter installed so the next
    /// `startCapture()` is a warm, fast start.
    public func stopCapture() {
        guard capturing else { return }
        engine.stop()
        capturing = false
    }

    /// Full teardown: stop capture and release the tap/converter. Used by the
    /// bench harness and any hard reset. `prepare()` will rebuild on next use.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        preparedFormat = nil
        capturing = false
    }

    /// Prepare + start in one call (bench harness convenience / back-compat).
    public func start() throws {
        try prepare()
        try startCapture()
    }

    // MARK: - Utterance

    public func beginUtterance() {
        buffer.beginUtterance()
    }

    /// Utterance samples captured since the last call — for streaming VAD.
    public func drainNewSamples() -> [Float] {
        buffer.drainNewSamples()
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
