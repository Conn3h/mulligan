import AVFoundation
import FluidAudio
import Foundation
import SottoDictionary
import SottoText

/// NVIDIA Parakeet TDT (CoreML, via FluidAudio) behind the engine seam. Experimental, for
/// side-by-side accuracy testing against `AppleSpeechEngine`. One instance serves one
/// utterance: `start()` once, `feed()` many times, then `finish()` or `cancel()`.
///
/// Live text comes from FluidAudio's sliding-window manager, which decodes overlapping
/// windows of the audio so far and keeps a confirmed prefix plus a volatile tail, the same
/// shape as Apple's final and volatile results. The final transcript is whatever
/// `finish()` returns after the remaining audio is flushed.
actor ParakeetSpeechEngine: TranscriptionEngine {
    private enum Phase: Sendable {
        case idle
        case starting
        case running
        case finishing
        case finished
        case cancelled
        case failed
    }

    /// Parakeet consumes 16 kHz mono Float32. Capture converts to this once, so the
    /// library's own converter takes its no-op fast path.
    private static let sampleRate: Double = 16_000
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )

    /// The library's acoustic "spotter rescue" proposes a dictionary term wherever the CTC
    /// spotter hears it, even when the transcript looks nothing like it. On a personal
    /// dictionary that replaces correctly heard words with terms that were never spoken (a
    /// "Kubernetes" entry swallowed "the quick brown fox" in testing). Off, boosting only
    /// rescores spans that already resemble a term, which is the behaviour dictation wants.
    ///
    /// The short-term taper (pivot 5) shrinks the flat boost for terms of fewer than five
    /// tokens, which is nearly every personal-dictionary word, so a short term has to earn
    /// its replacement from acoustic evidence rather than from the boost alone.
    private static let rescorerConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: shortTermTaperPivot,
        spotterRescueEnabled: false
    )

    /// Token count below which the boost tapers; the library's documented opt-in value.
    private static let shortTermTaperPivot = 5

    /// Minimum Levenshtein similarity between a transcribed span and a term before the
    /// rescorer may swap it. The library's size-based default (0.55 for a dictionary this
    /// size) let "alright" become Playwright (0.60), "make sure" become Maestro (0.56) and
    /// "latest transcripts" become "Vitest TypeScript" (0.67, 0.64). At 0.75 those all fall
    /// through. The combined acoustic-plus-string confidence gate moves up with it. Short
    /// single-word terms get a stricter per-term floor on top; see `BiasStrictness`.
    private static let minBiasSimilarity: Float = 0.75
    private static let minBiasCombinedConfidence: Float = 0.75

    /// Minimum CTC log-probability the keyword spotter must reach before a term is even a
    /// candidate. The library default of -12 is documented as lenient; -6 requires the term
    /// to actually sound present rather than merely look similar on paper.
    private static let minBiasCtcScore: Float = -6

    private var phase: Phase = .idle
    private var manager: SlidingWindowAsrManager?
    private var outputContinuation: AsyncThrowingStream<TranscriptSnapshot, Error>.Continuation?
    private var drainTask: Task<Void, Never>?
    /// The last transcript shown, kept so a failed `finish()` still hands something back.
    private var latest = ""
    private let biasPhrases: [String]

    /// Short holds are where Parakeet invents words on silence ("Mm-.", "Yeah."). Their audio
    /// is kept, up to this many samples (3 s at 16 kHz), for the speech check at finish.
    private static let speechProbeLimit = 48_000
    private var probeSamples: [Float] = []
    private var probeOverflowed = false
    private var vad: VadManager?

    /// Whether this hold's start sound plays: its first speech-detector window then holds that
    /// sound and is left out of the speech check (§6.7).
    private let startSoundPlays: Bool

    init(biasPhrases: [String] = [], startSoundPlays: Bool = true) {
        self.biasPhrases = biasPhrases
        self.startSoundPlays = startSoundPlays
    }

    // MARK: TranscriptionEngine

    func preferredInputFormat() async -> AVAudioFormat? {
        if Self.inputFormat == nil {
            Log.speech.error("parakeet: could not build the 16 kHz mono input format")
        }
        return Self.inputFormat
    }

    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        switch phase {
        case .idle:
            break
        case .cancelled:
            Log.speech.info("parakeet start skipped: already cancelled")
            throw CancellationError()
        default:
            Log.speech.error("parakeet start called in phase \(String(describing: self.phase), privacy: .public)")
            throw TranscriptionError.notRunning
        }
        phase = .starting
        do {
            return try await performStart()
        } catch {
            await abandonStart(after: error)
            throw error
        }
    }

    func feed(_ chunk: AudioChunk) async {
        guard phase == .running, let manager else {
            Log.speech.debug("parakeet feed ignored in phase \(String(describing: self.phase), privacy: .public)")
            return
        }
        keepForSpeechProbe(chunk.buffer)
        await manager.streamAudio(chunk.buffer)
    }

    private func keepForSpeechProbe(_ buffer: AVAudioPCMBuffer) {
        guard !probeOverflowed, vad != nil, let channel = buffer.floatChannelData?[0] else {
            return
        }
        let count = Int(buffer.frameLength)
        guard probeSamples.count + count <= Self.speechProbeLimit else {
            probeOverflowed = true
            probeSamples = []
            return
        }
        probeSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
    }

    /// A short hold's final text is kept only if the speech detector heard speech in it
    /// (§6.7): Parakeet turns silence into real words such as "Yeah.". Holds too long to keep
    /// in memory, a missing detector, or a detector error all keep the text, as before.
    /// Logs numbers only, never the text.
    private func checkedForSpeech(_ text: String) async -> String {
        guard !text.isEmpty, let vad, !probeOverflowed, !probeSamples.isEmpty else {
            return text
        }
        let samples = probeSamples
        probeSamples = []
        do {
            let probabilities = try await vad.process(samples).map(\.probability)
            let silent = SpeechEvidence.isSilent(probabilities, ignoringFirstWindow: startSoundPlays)
            let listed = probabilities.map { String(format: "%.2f", $0) }.joined(separator: " ")
            Log.speech.info(
                "speech check: \(Double(samples.count) / 16_000, format: .fixed(precision: 2), privacy: .public) s, windows [\(listed, privacy: .public)], \(silent ? "no speech; dropping" : "speech; keeping", privacy: .public) \(text.count, privacy: .public) chars"
            )
            return silent ? "" : text
        } catch {
            Log.speech.error("speech check failed, keeping the text: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    func finish() async {
        switch phase {
        case .finished, .finishing, .cancelled:
            Log.speech.debug("parakeet finish ignored in phase \(String(describing: self.phase), privacy: .public)")
            return
        case .idle, .failed:
            Log.speech.info("parakeet finish with nothing running (phase \(String(describing: self.phase), privacy: .public))")
            phase = .finished
            outputContinuation?.finish()
            await release()
            return
        case .starting:
            Log.speech.info("parakeet finish during start: cancelling instead")
            await cancel()
            return
        case .running:
            break
        }
        phase = .finishing
        var text = latest
        if let manager {
            do {
                text = try await manager.finish()
            } catch {
                Log.speech.error(
                    "parakeet finalize failed: \(error.localizedDescription, privacy: .public); keeping the last live text"
                )
            }
        }
        // The library never ends its update stream on finish; stop the drain by hand once
        // the flush has published everything.
        drainTask?.cancel()
        await drainTask?.value
        guard phase == .finishing else {
            Log.speech.info("parakeet finish pre-empted by cancel")
            return
        }
        let trimmed = await checkedForSpeech(Self.trimmed(text))
        guard phase == .finishing else {
            Log.speech.info("parakeet finish pre-empted by cancel during the speech check")
            return
        }
        outputContinuation?.yield(TranscriptSnapshot(text: trimmed, isFinal: true))
        outputContinuation?.finish()
        phase = .finished
        Log.speech.info("parakeet finished: \(trimmed.count, privacy: .public) chars")
        await release()
    }

    func cancel() async {
        switch phase {
        case .cancelled, .finished:
            return
        default:
            break
        }
        let startInFlight = phase == .starting
        phase = .cancelled
        await manager?.cancel()
        drainTask?.cancel()
        await drainTask?.value
        outputContinuation?.finish(throwing: CancellationError())
        if startInFlight {
            Log.speech.info("parakeet cancelled during start; start releases on resume")
        } else {
            await release()
            Log.speech.info("parakeet cancelled")
        }
    }

    // MARK: Start sequence

    private func performStart() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        let loaded = try await ParakeetModels.shared.readyModels()
        let models = loaded.asr
        vad = loaded.vad
        probeSamples = []
        probeOverflowed = false
        try checkLive()

        // The streaming preset is tuned for live feedback; the blank id must match the
        // model version or the decoder falls back to guessing it.
        let config = SlidingWindowAsrConfig.streaming
            .applying(tdtConfig: TdtConfig(blankId: models.version.blankId))
        let manager = SlidingWindowAsrManager(config: config)
        self.manager = manager
        try await manager.loadModels(models)
        try checkLive()
        try await configureBias(on: manager, ctc: loaded.ctc)
        try checkLive()

        // The update stream must be taken before streaming starts or early windows are lost.
        let updates = await manager.transcriptionUpdates
        let (output, outputContinuation) = AsyncThrowingStream<TranscriptSnapshot, Error>.makeStream()
        self.outputContinuation = outputContinuation
        latest = ""
        drainTask = Task {
            await self.drainUpdates(updates, from: manager)
        }

        try await manager.startStreaming(source: .microphone)
        try checkLive()
        phase = .running
        Log.speech.info("parakeet start: model \(String(describing: models.version), privacy: .public)")
        return output
    }

    /// Bias phrases reach Parakeet as vocabulary boosting: a CTC keyword spotter scores each
    /// term against the audio and rescores the transcript where the evidence is strong.
    /// Nothing to do without phrases; logged and skipped when the CTC model is missing.
    private func configureBias(on manager: SlidingWindowAsrManager, ctc: CtcModels?) async throws {
        guard !biasPhrases.isEmpty else {
            return
        }
        guard let ctc else {
            Log.speech.error("parakeet: \(self.biasPhrases.count, privacy: .public) bias phrases skipped, no CTC model")
            return
        }
        let vocabulary = CustomVocabularyContext(
            terms: biasPhrases.map {
                CustomVocabularyTerm(text: $0, minSimilarity: BiasStrictness.minimumSimilarity(for: $0))
            },
            minCtcScore: Self.minBiasCtcScore,
            minSimilarity: Self.minBiasSimilarity,
            minCombinedConfidence: Self.minBiasCombinedConfidence
        )
        try await manager.configureVocabularyBoosting(
            vocabulary: vocabulary,
            ctcModels: ctc,
            config: Self.rescorerConfig
        )
        Log.speech.info("bias phrases set: \(self.biasPhrases.count, privacy: .public)")
    }

    /// Throws when the engine was cancelled or the calling task was, so a suspended
    /// `start()` stops at its next checkpoint instead of finishing a dead session.
    private func checkLive() throws {
        if phase == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func abandonStart(after error: Error) async {
        if error is CancellationError {
            Log.speech.info("parakeet start abandoned: cancelled")
        } else {
            Log.speech.error("parakeet start failed: \(error.localizedDescription, privacy: .public)")
        }
        await manager?.cancel()
        drainTask?.cancel()
        await drainTask?.value
        outputContinuation?.finish(throwing: error)
        if phase != .cancelled {
            phase = .failed
        }
        await release()
    }

    private func release() async {
        drainTask = nil
        outputContinuation = nil
        if let manager {
            await manager.cleanup()
        }
        manager = nil
    }

    // MARK: Results

    /// Each update carries only the window it came from; the running transcript lives on
    /// the manager as a confirmed prefix and a volatile tail, read after every update.
    private func drainUpdates(
        _ updates: AsyncStream<SlidingWindowTranscriptionUpdate>,
        from manager: SlidingWindowAsrManager
    ) async {
        for await update in updates {
            if Task.isCancelled {
                break
            }
            let confirmed = await manager.confirmedTranscript
            let volatile = await manager.volatileTranscript
            let text = Self.trimmed(Self.join(confirmed, volatile))
            latest = text
            outputContinuation?.yield(TranscriptSnapshot(text: text, isFinal: false))
            Log.speech.debug(
                "parakeet update: confirmed \(update.isConfirmed, privacy: .public), confidence \(update.confidence, privacy: .public), \(text.count, privacy: .public) chars"
            )
        }
        Log.speech.debug("parakeet update stream ended")
    }

    /// Concatenates two transcript pieces with a single space between words when neither
    /// side already provides one.
    private static func join(_ head: String, _ tail: String) -> String {
        if head.isEmpty {
            return tail
        }
        if tail.isEmpty {
            return head
        }
        let headEndsInSpace = head.last?.isWhitespace ?? false
        let tailStartsWithSpace = tail.first?.isWhitespace ?? false
        if headEndsInSpace || tailStartsWithSpace {
            return head + tail
        }
        return head + " " + tail
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
