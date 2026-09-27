/// Decides whether a hold heard any speech, from the per-block meter levels capture reports.
///
/// Parakeet transcribes a silent hold as filler ("Mm-.", "And then.") and that used to be
/// pasted. A hold passes only when at least `minimumVoicedBlocks` capture blocks reached
/// `voicedLevel`; one loud block (a key click, a bump) is not speech. The levels are the
/// meter's 0...1 scale (-50...0 dBFS RMS, see `AudioCapture.meterLevel(rms:)`).
struct SpeechGate: Sendable, Equatable {
    let voicedLevel: Float
    let minimumVoicedBlocks: Int

    /// Everything passes. The default for tests that do not emit levels.
    static let disabled = SpeechGate(voicedLevel: 0, minimumVoicedBlocks: 0)

    /// 0.3 is -35 dBFS RMS: well above a quiet room, below soft speech at laptop distance.
    /// Two blocks is about 85 ms at 48 kHz, shorter than any spoken word.
    static let standard = SpeechGate(voicedLevel: 0.3, minimumVoicedBlocks: 2)

    func isVoiced(_ level: Float) -> Bool {
        level >= voicedLevel
    }

    func heardSpeech(voicedBlocks: Int) -> Bool {
        voicedBlocks >= minimumVoicedBlocks
    }
}
