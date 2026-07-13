// @preconcurrency: the iOS SDK marks AVAudioConverterInputBlock @Sendable,
// but AVAudioPCMBuffer isn't — the conversion below is synchronous and the
// buffer never escapes the call, so the capture is safe.
@preconcurrency import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Installed/downloadable state of the OS speech model for a locale.
/// Querying it is side-effect free — status checks NEVER trigger a download
/// (the OS owns speech assets; see `SpeechTranscriberEngine` header).
public enum SpeechAssetAvailability: String, Sendable, Equatable {
    case installed
    /// `AssetInventory` `.supported`: the OS can fetch the model if the user
    /// explicitly asks (see `requestAssetInstallation`).
    case downloadable
    /// An OS-side fetch is already in flight (started by us earlier or by
    /// another app — assets are system-wide).
    case downloading
    /// `AssetInventory` `.unsupported`: no speech asset for this locale in
    /// THIS environment. On a device that means the locale; in the iOS
    /// simulator it is reported for EVERY locale — the simulator runtime
    /// ships no SpeechTranscriber assets (`SpeechTranscriber.isAvailable`
    /// is false there) and refuses installs, so device runs are the only
    /// authoritative A/B for this engine.
    case unsupported
    /// `supportedLocale(equivalentTo:)` knows no equivalent — the language
    /// itself is outside the API's locale table.
    case unsupportedLocale
    /// No SpeechTranscriber API on this platform / OS version.
    case unavailable
}

/// Failure modes specific to the system-Speech engine. Separate from
/// `WhisprError` because the actionable fix is an OS-mediated asset install
/// or an OS update — never fetch-models.sh.
public enum SpeechTranscriberEngineError: Error, LocalizedError, Equatable {
    case unavailable
    case notLoaded
    case unsupportedLocale(String)
    case assetsNotInstalled(SpeechAssetAvailability)
    case audioFormatUnavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "System speech recognition (SpeechTranscriber) requires iOS 26 / macOS 26."
        case .notLoaded:
            return "SpeechTranscriberEngine used before load()."
        case .unsupportedLocale(let code):
            return "System speech recognition does not support the “\(code)” locale."
        case .assetsNotInstalled(let availability):
            return "System speech model not installed (status: \(availability.rawValue)). "
                + "Installing it is an OS-mediated action — see requestAssetInstallation()."
        case .audioFormatUnavailable:
            return "No compatible audio format for the system speech analyzer."
        }
    }
}

#if canImport(Speech)

/// Apple `SpeechTranscriber` (the WWDC25 `SpeechAnalyzer` API, iOS 26+/
/// macOS 26+) as a second `AsrEngine` backend — the A/B alternative to
/// Parakeet (issue #13 review amendment 2). Locale comes from
/// `DictationLanguage`; input is the pipeline's usual 16kHz mono Float32
/// samples, bridged to the analyzer's preferred format via `AVAudioPCMBuffer`
/// (+ `AVAudioConverter` only if the OS ever asks for something other than
/// 16kHz mono Float32).
///
/// Offline-audit boundary (spec §11.7): the speech model is a SYSTEM asset,
/// downloaded and owned by the OS (`AssetInventory`), never by this binary.
/// `load()` and `transcribe()` only QUERY asset status and throw
/// `.assetsNotInstalled` when the model is absent — they cannot start a
/// download. The single way assets get installed through this type is
/// `requestAssetInstallation()`, which must stay behind an explicit user
/// action in the UI: it asks the OS's own asset daemon to fetch (out of
/// process, like tapping a language in Settings → Keyboard → Dictation), so
/// the app binary still contains zero networking code and audit-offline.sh
/// Tier 0/1/2 remain green with this engine present.
@available(macOS 26.0, iOS 26.0, *)
public actor SpeechTranscriberEngine: AsrEngine {
    /// SpeechTranscriber publishes no input floor; hold it to Parakeet's
    /// ~300ms (spec: engines swap without callers changing their guard).
    public nonisolated let minimumSamples = Int(AudioEngine.targetSampleRate * 0.3)

    private let language: DictationLanguage
    /// Resolved by `load()` via `supportedLocale(equivalentTo:)` — nil until
    /// the OS has confirmed both locale support and installed assets.
    private var locale: Locale?

    public init(language: DictationLanguage) {
        self.language = language
    }

    public var isLoaded: Bool { locale != nil }

    /// Confirm locale support + installed assets, then pay the model spin-up
    /// on silence (mirrors ParakeetEngine's warm-up) so the first real
    /// dictation is fast. Never downloads — see the type header.
    public func load() async throws {
        guard locale == nil else { return }
        guard let resolved = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.code))
        else {
            throw SpeechTranscriberEngineError.unsupportedLocale(language.code)
        }
        let availability = await Self.availability(of: resolved)
        guard availability == .installed else {
            throw SpeechTranscriberEngineError.assetsNotInstalled(availability)
        }
        locale = resolved
        let silence = [Float](repeating: 0, count: max(minimumSamples, 8_000))
        _ = try? await run(silence, locale: resolved)
    }

    public func transcribe(_ samples: [Float]) async throws -> AsrResult {
        guard let locale else { throw SpeechTranscriberEngineError.notLoaded }
        return try await run(samples, locale: locale)
    }

    // MARK: - Asset state (query-only) + explicit OS-mediated install

    /// Side-effect-free asset probe for this engine's language — what the UI
    /// shows next to an "install" affordance. Never triggers a download.
    public func assetAvailability() async -> SpeechAssetAvailability {
        guard let resolved = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.code))
        else { return .unsupportedLocale }
        return await Self.availability(of: resolved)
    }

    /// EXPLICIT, user-initiated asset install — the ONE call in this type
    /// with a network side effect, and it is OS-mediated: the fetch runs in
    /// the system's asset daemon, not in this process, so the app binary
    /// gains no networking code (see the type header for the audit story).
    /// UI must gate this behind a deliberate user action; `load()` and
    /// `transcribe()` never call it. Returns when the model is installed.
    public func requestAssetInstallation() async throws {
        guard let resolved = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.code))
        else {
            throw SpeechTranscriberEngineError.unsupportedLocale(language.code)
        }
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        // nil request means the assets are already installed — success.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private static func availability(of locale: Locale) async -> SpeechAssetAvailability {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .downloading: return .downloading
        case .unsupported: return .unsupported
        @unknown default: return .unavailable
        }
    }

    // MARK: - One-shot analysis

    /// One utterance through a fresh analyzer. Modules bind to one analyzer,
    /// so both are per-call; `.processLifetime` retention keeps the model hot
    /// across calls, which is what makes per-call construction cheap.
    private func run(_ samples: [Float], locale: Locale) async throws -> AsrResult {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])
        else {
            throw SpeechTranscriberEngineError.audioFormatUnavailable
        }
        let buffer = try Self.pcmBuffer(samples, convertedTo: analyzerFormat)

        // Consumer first, then input: `.transcription` (no volatileResults)
        // reports finalized results only; the sequence ends when the
        // analyzer finishes.
        let collect = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        // Apple exposes no model-inference metric, so modelProcessingSeconds
        // is the analyze+finalize wall time (excludes the buffer conversion).
        let analyzeSeconds: Double
        do {
            let (_, seconds) = try await measured {
                try await analyzer.start(inputSequence: input)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            analyzeSeconds = seconds
        } catch {
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let text = try await collect.value
        return AsrResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            modelProcessingSeconds: analyzeSeconds
        )
    }

    /// Wrap the pipeline's 16kHz mono Float32 samples for the analyzer,
    /// converting only when the OS asks for a different format (it should
    /// not — Apple's speech models run at 16kHz mono).
    private static func pcmBuffer(
        _ samples: [Float], convertedTo format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioEngine.targetSampleRate, channels: 1, interleaved: false),
            let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = source.floatChannelData
        else {
            throw SpeechTranscriberEngineError.audioFormatUnavailable
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        if format.commonFormat == .pcmFormatFloat32,
           format.sampleRate == sourceFormat.sampleRate,
           format.channelCount == 1 {
            return source
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: format),
              let converted = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(
                      (Double(samples.count) * format.sampleRate / sourceFormat.sampleRate)
                          .rounded(.up)) + 1_024)
        else {
            throw WhisprError.audioConverterUnavailable
        }
        var fed = false
        var conversionError: NSError?
        // .endOfStream after the single buffer flushes the resampler tail.
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        if status == .error {
            throw conversionError ?? WhisprError.audioConverterUnavailable
        }
        return converted
    }
}

#else

/// Stub for platforms without the Speech framework: same API surface, every
/// entry point reports unavailable so callers need no conditional compilation.
public final class SpeechTranscriberEngine: AsrEngine, Sendable {
    public nonisolated let minimumSamples = Int(AudioEngine.targetSampleRate * 0.3)

    public init(language: DictationLanguage) {}

    public var isLoaded: Bool { get async { false } }

    public func assetAvailability() async -> SpeechAssetAvailability { .unavailable }

    public func requestAssetInstallation() async throws {
        throw SpeechTranscriberEngineError.unavailable
    }

    public func load() async throws {
        throw SpeechTranscriberEngineError.unavailable
    }

    public func transcribe(_ samples: [Float]) async throws -> AsrResult {
        throw SpeechTranscriberEngineError.unavailable
    }
}

#endif
