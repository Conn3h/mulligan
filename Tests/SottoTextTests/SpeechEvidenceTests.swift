import Testing
@testable import SottoText

/// The speech detector's per-window probabilities, as measured on the author's Mac
/// (2026-09-27): silent holds peaked at 0.10-0.56, soft one-word answers at 0.96-1.00.
struct SpeechEvidenceTests {
    @Test(arguments: [
        [0.18, 0.06], [0.10, 0.02], [0.26, 0.04, 0.03, 0.03], [0.55, 0.18, 0.10, 0.05, 0.03, 0.02],
        [0.56, 0.12, 0.07, 0.13, 0.08, 0.05, 0.01, 0.01], [0.46, 0.06, 0.03],
    ] as [[Float]])
    func silentHoldsHaveNoSpeech(_ windows: [Float]) {
        #expect(SpeechEvidence.isSilent(windows))
    }

    @Test(arguments: [
        [0.94, 0.37, 0.13, 0.07, 1.00, 1.00, 0.97], [0.11, 1.00, 1.00, 1.00], [0.47, 1.00, 1.00],
        [0.16, 0.31, 0.96, 0.73], [0.24, 0.02, 0.02, 0.02, 0.02, 1.00, 1.00],
    ] as [[Float]])
    func softOneWordAnswersHaveSpeech(_ windows: [Float]) {
        #expect(!SpeechEvidence.isSilent(windows))
    }

    @Test func oneConfidentWindowAfterTheFirstIsEnough() {
        #expect(!SpeechEvidence.isSilent([0.01, 0.70, 0.01]))
    }

    @Test func justUnderTheThresholdIsSilent() {
        #expect(SpeechEvidence.isSilent([0.01, 0.69, 0.01]))
    }

    /// The first window holds Sotto's own start sound and the key click, which once scored
    /// 0.94 on a silent hold (2026-09-27). It is ignored whenever later windows exist.
    @Test func theFirstWindowAloneIsNotSpeech() {
        #expect(SpeechEvidence.isSilent([0.94, 0.46]))
        #expect(SpeechEvidence.isSilent([0.63, 0.11, 0.06]))
    }

    @Test func aSingleWindowIsJudgedOnItsOwn() {
        #expect(!SpeechEvidence.isSilent([0.94]))
        #expect(SpeechEvidence.isSilent([0.30]))
    }

    @Test func realSpeechAfterTheFirstWindowStillCounts() {
        #expect(!SpeechEvidence.isSilent([0.63, 1.00, 1.00, 0.32]))
        #expect(!SpeechEvidence.isSilent([0.53, 0.68, 0.86]))
        #expect(!SpeechEvidence.isSilent([0.34, 1.00]))
    }

    /// Without the start sound the first window holds nothing of Sotto's, so a quick word
    /// that lives only there counts (Codex, round 4).
    @Test func withoutTheStartSoundTheFirstWindowCounts() {
        #expect(!SpeechEvidence.isSilent([0.94, 0.05], ignoringFirstWindow: false))
        #expect(SpeechEvidence.isSilent([0.30, 0.05], ignoringFirstWindow: false))
    }

    @Test func noWindowsIsNotEvidenceOfSilence() {
        #expect(!SpeechEvidence.isSilent([]))
    }
}
