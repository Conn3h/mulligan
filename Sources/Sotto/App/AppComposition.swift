import Foundation

/// The composition root. Exactly one instance for the life of the process, owned by the
/// AppDelegate; every scene reaches it through the delegate adaptor.
@MainActor
final class AppComposition {
    /// The engine the current (or most recent) press was built with. Set by the engine
    /// factory and read by the pipeline when it records history, so a Settings change made
    /// mid-utterance cannot mislabel the run.
    @MainActor
    private final class ActiveEngine {
        var name = SpeechEngineChoice.apple.engineName
    }

    let controller: DictationController
    let pipeline: UtterancePipeline
    let capture: AudioCapture
    // hud is added by milestone B2

    init() {
        let capture = AudioCapture()
        self.capture = capture
        let activeEngine = ActiveEngine()
        let pipeline = UtterancePipeline(readEngineName: { activeEngine.name })
        let controller = DictationController(
            hotkey: HotkeyMonitor(),
            capture: capture,
            requestMicrophone: { await Permissions.requestMicrophone() },
            // Read per press so an engine switch or a dictionary edit applies to the very
            // next hold.
            makeEngine: {
                // A hand edit to dictionary.txt must reach the very next hold, and hotkey
                // dictation never activates Sotto (the other reload trigger). The reload is a
                // size-and-date check that returns at once when the file is unchanged.
                DictionaryStore.shared.reloadFromDisk()
                let choice = Settings.shared.speechEngine
                activeEngine.name = choice.engineName
                switch choice {
                case .apple:
                    return AppleSpeechEngine(locale: .current, biasPhrases: DictionaryStore.shared.biasPhrases)
                case .parakeet:
                    return ParakeetSpeechEngine(biasPhrases: DictionaryStore.shared.biasPhrases)
                }
            },
            speechGate: .standard
        )
        controller.onFinalTranscript = { raw, utterance in
            await pipeline.process(raw: raw, utterance: utterance)
        }
        self.controller = controller
        self.pipeline = pipeline
    }
}
