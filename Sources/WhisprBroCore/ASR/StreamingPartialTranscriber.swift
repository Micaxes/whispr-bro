// @preconcurrency: same rationale as SpeechTranscriberEngine — the SDK marks
// AVAudioConverterInputBlock @Sendable but AVAudioPCMBuffer isn't; conversion
// is synchronous inside `feed` and the buffer never escapes the call.
@preconcurrency import AVFoundation
import Foundation
#if canImport(Speech)
import Speech

/// Live-preview streaming transcriber (keyboard-parity phase 3): ONE
/// SpeechAnalyzer session per dictation segment, with `SpeechTranscriber`
/// preset `.progressiveTranscription` — the volatile-results preset, so the
/// results sequence interleaves replace-in-place volatile guesses with the
/// finalized text they harden into. The hybrid split with the batch engines
/// is deliberate: this type feeds a DISPLAY-ONLY preview (the keyboard's
/// partial page) and its output is never inserted, stored, or merged into the
/// final transcript — Parakeet transcribes the full segment at stop exactly
/// as before, so a preview bug can show stale text but never type it.
///
/// Offline-audit boundary: identical to `SpeechTranscriberEngine` — the
/// speech model is a SYSTEM asset owned by the OS. `makeIfAvailable` only
/// QUERIES asset status (never downloads); anything but installed means no
/// partials, silently. Per-segment construction is cheap for the same reason
/// the batch engine's is: `.processLifetime` retention keeps the model hot.
@available(macOS 26.0, iOS 26.0, *)
public actor StreamingPartialTranscriber {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// The one way to get an instance: nil unless the OS confirms locale
    /// support AND installed assets (`SpeechTranscriberEngine.availability`,
    /// the same query-only probe as the batch engine — a status check must
    /// NEVER trigger a download). Nil simply means partials are off for this
    /// segment; the caller's final-transcript path is unaffected.
    public static func makeIfAvailable(
        language: DictationLanguage
    ) async -> StreamingPartialTranscriber? {
        guard let resolved = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.code)),
            await SpeechTranscriberEngine.availability(of: resolved) == .installed
        else { return nil }
        return StreamingPartialTranscriber(locale: resolved)
    }

    private init(locale: Locale) {
        self.locale = locale
    }

    /// Open the segment's analyzer session. `onPartial` receives the full
    /// display text so far — finalized prefix + current volatile suffix — on
    /// every transcriber result (volatile results REPLACE the suffix; a final
    /// result freezes it into the prefix, per the volatile-results contract).
    /// Callbacks arrive on this actor's executor, in results-sequence order;
    /// the callee is expected to hop them onto its own serial lane.
    public func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        guard analyzer == nil else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])
        else {
            throw SpeechTranscriberEngineError.audioFormatUnavailable
        }
        // Consumer first, then input — mirrors the batch engine's `run`.
        resultsTask = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        onPartial(finalized)
                    } else {
                        onPartial(finalized + text)
                    }
                }
            } catch {
                // Preview-only: a dead results stream just freezes the
                // preview until the segment closes. Parakeet is untouched.
            }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.input = continuation
        // `start` (not `analyzeSequence`) — analysis proceeds autonomously
        // while the caller's drain loop keeps yielding input. Self-cleaning
        // on throw: the results consumer and input continuation above already
        // exist, and without the teardown they would outlive the failed start
        // forever (callers only `finish()` instances that started). `finish`
        // also nils `analyzer`, so a caller may even retry `start`.
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            await finish()
            throw error
        }
    }

    /// Feed the next 16kHz mono Float32 chunk (the session's ~100ms drain
    /// batches). A conversion failure drops the chunk — for a display-only
    /// preview a skipped 100ms is invisible, and throwing would force the
    /// caller to care. No-op before `start` / after `finish`.
    public func feed(_ samples: [Float]) {
        guard let input, let analyzerFormat, !samples.isEmpty else { return }
        guard let buffer = try? SpeechTranscriberEngine.pcmBuffer(
            samples, convertedTo: analyzerFormat)
        else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Close the segment: input finished, results consumer torn down, and the
    /// analysis CANCELLED (never finalized — nobody consumes a final from
    /// this engine, and `cancelAndFinishNow` returns without paying for one).
    /// Idempotent; safe to call on a never-started instance.
    public func finish() async {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        analyzerFormat = nil
    }
}

#endif
