import FluidAudio
import Foundation
import Observation

/// The Parakeet CoreML bundles, plus the CTC model that vocabulary boosting needs, downloaded
/// and loaded once per process and shared by every `ParakeetSpeechEngine`. Loading is kicked off at launch (when Parakeet is selected) or
/// when the user switches to it, never by a press: a press that arrives while the models
/// are still on their way fails fast with a message instead of hanging the utterance.
@MainActor
@Observable
final class ParakeetModels {
    enum State: Equatable, Sendable {
        case idle
        case downloading(fraction: Double)
        case loading
        case ready
        case failed(String)
    }

    /// Everything one utterance needs. `ctc` is nil when that download or load failed; the
    /// engine then transcribes without bias phrases and logs it.
    struct Loaded: Sendable {
        let asr: AsrModels
        let ctc: CtcModels?
        /// Silero speech detector, scoring short holds (measurement, 2026-09-27). Nil when it
        /// failed to load; dictation is unaffected.
        let vad: VadManager?
    }

    static let shared = ParakeetModels()

    /// English-only v2: tighter vocabulary and better recall on English than the
    /// multilingual v3, which is what a side-by-side against Apple needs.
    nonisolated static let version: AsrModelVersion = .v2
    /// Progress is reported per byte; only whole-percent steps reach the UI.
    private static let progressStep = 0.01

    private(set) var state: State = .idle
    @ObservationIgnored private var loadTask: Task<Loaded, any Error>?
    @ObservationIgnored private var loaded: Loaded?
    @ObservationIgnored private var lastReportedFraction = -1.0

    private init() {}

    /// Starts the download and load if it is not already under way or done. Safe to call
    /// repeatedly; a failed load is retried on the next call.
    func prepare() {
        if loaded != nil || loadTask != nil {
            return
        }
        state = .downloading(fraction: 0)
        lastReportedFraction = -1
        Log.speech.info("parakeet: preparing models \(String(describing: Self.version), privacy: .public)")
        let task = Task { [weak self] () throws -> Loaded in
            let asr = try await AsrModels.downloadAndLoad(version: Self.version) { progress in
                Task { @MainActor in
                    self?.report(progress)
                }
            }
            return Loaded(asr: asr, ctc: await Self.loadCtcModels(), vad: await Self.loadVad())
        }
        loadTask = task
        Task { [weak self] in
            await self?.settle(task)
        }
    }

    /// The loaded models. Throws `modelInstallFailed` with a user-readable reason while
    /// they are still downloading or loading, or after the load failed.
    func readyModels() throws -> Loaded {
        if let loaded {
            return loaded
        }
        switch state {
        case .idle:
            prepare()
            throw TranscriptionError.modelInstallFailed("Parakeet models are not downloaded yet. Downloading now; try again shortly.")
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded(.down))
            throw TranscriptionError.modelInstallFailed("Parakeet models are still downloading (\(percent)%).")
        case .loading:
            throw TranscriptionError.modelInstallFailed("Parakeet models are still loading.")
        case .failed(let reason):
            // A press after a failure retries the load, so a transient network error does not
            // strand the engine until the next launch.
            prepare()
            throw TranscriptionError.modelInstallFailed("Parakeet models failed to load: \(reason). Retrying.")
        case .ready:
            Log.speech.error("parakeet: state is ready but no models are held")
            throw TranscriptionError.modelInstallFailed("Parakeet models are unavailable.")
        }
    }

    private func report(_ progress: DownloadProgress) {
        guard progress.fractionCompleted - lastReportedFraction >= Self.progressStep else {
            return
        }
        lastReportedFraction = progress.fractionCompleted
        if progress.fractionCompleted >= 1 {
            state = .loading
        } else {
            state = .downloading(fraction: progress.fractionCompleted)
        }
    }

    /// The CTC encoder behind vocabulary boosting. A failure here is logged and leaves the
    /// engine usable without bias phrases rather than failing the whole load.
    private static func loadCtcModels() async -> CtcModels? {
        do {
            let ctc = try await CtcModels.downloadAndLoad()
            Log.speech.info("parakeet: CTC models ready for vocabulary boosting")
            return ctc
        } catch {
            Log.speech.error("parakeet: CTC model load failed, bias phrases disabled: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The speech detector. A failure is logged and only disables the speech probe.
    private static func loadVad() async -> VadManager? {
        do {
            let vad = try await VadManager()
            Log.speech.info("parakeet: speech detector ready")
            return vad
        } catch {
            Log.speech.error("parakeet: speech detector load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func settle(_ task: Task<Loaded, any Error>) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let models = try await task.value
            loaded = models
            state = .ready
            let seconds = Self.seconds(clock.now - started)
            Log.speech.info("parakeet: models ready in \(seconds, privacy: .public) s")
        } catch {
            state = .failed(error.localizedDescription)
            Log.speech.error("parakeet: model load failed: \(error.localizedDescription, privacy: .public)")
        }
        loadTask = nil
    }

    private static func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }
}
