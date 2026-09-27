import AVFoundation
import Foundation
import Speech
import Synchronization

/// Apple's on-device `SpeechAnalyzer` behind the engine seam. One instance serves one
/// utterance: `start()` once, `feed()` many times, then `finish()` or `cancel()`.
actor AppleSpeechEngine: TranscriptionEngine {
    private enum Phase: Sendable {
        case idle
        case starting
        case running
        case finishing
        case finished
        case cancelled
        case failed
    }

    private static let fallbackLocale = Locale(identifier: "en-US")
    /// An asset check that takes longer than this is a real download; anything quicker is
    /// the inventory confirming the assets are already on disk.
    private static let assetDownloadThreshold: Duration = .milliseconds(250)

    /// Resolving a locale and confirming assets both cross into the Speech daemon. Neither
    /// answer changes for the life of the process, so both are memoised: `resolvedLocales`
    /// caches the resolution, and `confirmedAssets` records which locales are installed so a
    /// later press skips the inventory check entirely.
    private static let resolvedLocales = Mutex<[String: Locale]>([:])
    private static let confirmedAssets = Mutex<Set<String>>([])

    /// The analyzer's preferred capture format is fixed per resolved locale. Computing it
    /// calls into the Speech framework; cache it so a press does not pay that between
    /// analyzer start and capture start. AVAudioFormat is an immutable reference type; the
    /// Mutex confines access.
    private static let preferredFormats = Mutex<[String: AVAudioFormat]>([:])

    private let requestedLocale: Locale
    private let biasPhrases: [String]

    private var phase: Phase = .idle
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerStarted = false
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var outputContinuation: AsyncThrowingStream<TranscriptSnapshot, Error>.Continuation?
    private var drainTask: Task<Void, Never>?
    /// A result-stream failure that arrived while `analyzer.start` was still suspended.
    /// `start()` throws it once the analyzer resumes, so the controller hears about it
    /// instead of waiting on a stream that has already ended.
    private var startFailure: (any Error)?
    /// Final results, joined in arrival order.
    private var committed = ""
    /// The latest volatile result. Shown after `committed`, never stored, so the next
    /// revision replaces it cleanly.
    private var volatile = ""

    init(locale: Locale = .current, biasPhrases: [String] = []) {
        requestedLocale = locale
        self.biasPhrases = biasPhrases
    }

    /// Resolves the locale and installs assets ahead of time so the first hold is fast.
    /// Errors are logged, never thrown.
    static func prepare(locale: Locale = .current) async {
        guard SpeechTranscriber.isAvailable else {
            Log.speech.error("prepare: SpeechTranscriber is unavailable on this Mac")
            return
        }
        guard let resolved = await resolveLocale(requestedLocale: locale) else {
            Log.speech.error("prepare: no supported locale for \(locale.identifier, privacy: .public)")
            return
        }
        let transcriber = makeTranscriber(locale: resolved)
        do {
            try await installAssetsIfNeeded(for: transcriber, locale: resolved)
            if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
                preferredFormats.withLock { $0[resolved.identifier] = format }
            }
            Log.speech.info("prepare: speech ready for \(resolved.identifier, privacy: .public)")
        } catch {
            Log.speech.error("prepare failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: TranscriptionEngine

    func preferredInputFormat() async -> AVAudioFormat? {
        guard let locale = await Self.resolveLocale(requestedLocale: requestedLocale) else {
            Log.speech.error("preferredInputFormat: no supported locale for \(self.requestedLocale.identifier, privacy: .public)")
            return nil
        }
        if let cached = Self.preferredFormats.withLock({ $0[locale.identifier] }) {
            return cached
        }
        let source = transcriber ?? Self.makeTranscriber(locale: locale)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [source])
        if let format {
            Self.preferredFormats.withLock { $0[locale.identifier] = format }
        } else {
            Log.speech.error("preferredInputFormat: no compatible audio format reported")
        }
        return format
    }

    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        switch phase {
        case .idle:
            break
        case .cancelled:
            Log.speech.info("engine start skipped: already cancelled")
            throw CancellationError()
        default:
            Log.speech.error("engine start called in phase \(String(describing: self.phase), privacy: .public)")
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
        guard phase == .running, let inputContinuation else {
            Log.speech.debug("feed ignored in phase \(String(describing: self.phase), privacy: .public)")
            return
        }
        inputContinuation.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    func finish() async {
        switch phase {
        case .finished, .finishing, .cancelled:
            Log.speech.debug("finish ignored in phase \(String(describing: self.phase), privacy: .public)")
            return
        case .idle, .failed:
            Log.speech.info("finish with nothing running (phase \(String(describing: self.phase), privacy: .public))")
            phase = .finished
            outputContinuation?.finish()
            release()
            return
        case .starting:
            Log.speech.info("finish during start: cancelling instead")
            await cancel()
            return
        case .running:
            break
        }
        phase = .finishing
        inputContinuation?.finish()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Log.speech.error("finalize failed: \(error.localizedDescription, privacy: .public); cancelling analyzer")
                await analyzer.cancelAndFinishNow()
            }
        }
        // Results the module already published can still be pending after the analyzer
        // finishes; reading `committed` before the drain completes would lose them.
        await drainTask?.value
        guard phase == .finishing else {
            Log.speech.info("finish pre-empted by cancel")
            return
        }
        let text = Self.trimmed(committed)
        outputContinuation?.yield(TranscriptSnapshot(text: text, isFinal: true))
        outputContinuation?.finish()
        phase = .finished
        Log.speech.info("engine finished: \(text.count, privacy: .public) chars committed")
        release()
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
        inputContinuation?.finish()
        if analyzerStarted, let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        drainTask?.cancel()
        await drainTask?.value
        outputContinuation?.finish(throwing: CancellationError())
        if startInFlight {
            Log.speech.info("engine cancelled during start; start releases on resume")
        } else {
            release()
            Log.speech.info("engine cancelled")
        }
    }

    // MARK: Start sequence

    private func performStart() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.localeUnsupported(requestedLocale)
        }
        guard let locale = await Self.resolveLocale(requestedLocale: requestedLocale) else {
            throw TranscriptionError.localeUnsupported(requestedLocale)
        }
        try checkLive()

        let transcriber = Self.makeTranscriber(locale: locale)
        self.transcriber = transcriber
        try await Self.installAssetsIfNeeded(for: transcriber, locale: locale)
        try checkLive()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !biasPhrases.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = biasPhrases
            try await analyzer.setContext(context)
            try checkLive()
            Log.speech.info("bias phrases set: \(self.biasPhrases.count, privacy: .public)")
        }

        let (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (output, outputContinuation) = AsyncThrowingStream<TranscriptSnapshot, Error>.makeStream()
        self.inputContinuation = inputContinuation
        self.outputContinuation = outputContinuation
        committed = ""
        volatile = ""
        startFailure = nil
        drainTask = Task {
            await self.drainResults(from: transcriber)
        }

        try await analyzer.start(inputSequence: input)
        analyzerStarted = true
        if let startFailure {
            // The drain already finished the output stream with this error while the
            // analyzer was starting; reporting success here would strand the controller.
            throw startFailure
        }
        try checkLive()
        phase = .running
        Log.speech.info("analyzer start: locale \(locale.identifier, privacy: .public)")
        return output
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
            Log.speech.info("engine start abandoned: cancelled")
        } else {
            Log.speech.error("engine start failed: \(error.localizedDescription, privacy: .public)")
        }
        inputContinuation?.finish()
        if analyzerStarted, let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        drainTask?.cancel()
        await drainTask?.value
        outputContinuation?.finish(throwing: error)
        if phase != .cancelled {
            phase = .failed
        }
        release()
    }

    private func release() {
        drainTask = nil
        inputContinuation = nil
        outputContinuation = nil
        analyzer = nil
        transcriber = nil
        analyzerStarted = false
    }

    // MARK: Results

    private func drainResults(from transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                if Task.isCancelled {
                    break
                }
                fold(result)
            }
            Log.speech.debug("result stream ended")
        } catch is CancellationError {
            Log.speech.debug("result drain cancelled")
        } catch {
            Log.speech.error(
                "result stream failed in phase \(String(describing: self.phase), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            switch phase {
            case .starting:
                startFailure = error
                outputContinuation?.finish(throwing: error)
            case .running:
                outputContinuation?.finish(throwing: error)
            case .idle, .finishing, .finished, .cancelled, .failed:
                Log.speech.debug("result stream failure not forwarded: the session is already ending")
            }
        }
    }

    private func fold(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            committed = Self.join(committed, text)
            volatile = ""
        } else {
            volatile = text
        }
        let snapshot = TranscriptSnapshot(text: Self.trimmed(Self.join(committed, volatile)), isFinal: false)
        outputContinuation?.yield(snapshot)
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

    // MARK: Locale and assets

    private static func resolveLocale(requestedLocale: Locale) async -> Locale? {
        let key = requestedLocale.identifier
        if let cached = resolvedLocales.withLock({ $0[key] }) {
            return cached
        }
        let resolved: Locale?
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            resolved = match
        } else {
            Log.speech.info(
                "locale \(requestedLocale.identifier, privacy: .public) unsupported; trying \(fallbackLocale.identifier, privacy: .public)"
            )
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: fallbackLocale)
        }
        if let resolved {
            resolvedLocales.withLock { $0[key] = resolved }
        }
        return resolved
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private static func installAssetsIfNeeded(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let key = locale.identifier
        if confirmedAssets.withLock({ $0.contains(key) }) {
            return
        }
        // Run the install in the CALLER's own task, not a detached shared task. Awaiting a
        // detached Task's `.value` is not cancellation-aware, so a release during a cold
        // first-launch download would leave the setup task suspended and strand the
        // controller in `.finishing`, rejecting presses for the whole download (SPEC 6.7's
        // setup-cancellation contract). Running it here lets `downloadAndInstall` throw
        // CancellationError promptly when the setup task is cancelled. The rare concurrent
        // cold-launch case (a launch `prepare()` racing the first press) is deduplicated by
        // AssetInventory at the OS level, and `confirmedAssets` skips every later press.
        try await performAssetInstall(for: transcriber, locale: locale)
        confirmedAssets.withLock { _ = $0.insert(key) }
    }

    private static func performAssetInstall(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw TranscriptionError.modelInstallFailed("request failed: \(error.localizedDescription)")
        }
        guard let request else {
            Log.speech.info("speech assets already installed")
            return
        }
        // The inventory hands back a request even when everything is installed, and
        // installing then takes a few milliseconds; only a slow run is a real download.
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await request.downloadAndInstall()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
        let elapsed = clock.now - started
        let milliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        if elapsed > assetDownloadThreshold {
            Log.speech.info("speech asset download finished in \(milliseconds, privacy: .public) ms")
        } else {
            Log.speech.info("speech assets checked in \(milliseconds, privacy: .public) ms; nothing to download")
        }
    }
}
