import Foundation
import SottoDictionary
import Testing
@testable import Sotto

/// Collects everything the pipeline hands to its seams. A class so the seam closures can
/// append to it after the harness is built.
@MainActor
private final class PipelineRecorder {
    var injected: [String] = []
    var recorded: [DictationRun] = []
    var soundPlays = 0
}

/// A pipeline wired to fakes on every seam: settings, corrector, history, injector and
/// sound. Nothing here reads `Settings`, the dictionary file, `history.jsonl`, the
/// pasteboard or the focused app.
@MainActor
private struct PipelineHarness {
    static let engineName = "FakeEngine"

    let recorder: PipelineRecorder
    let pipeline: UtterancePipeline

    init(
        cleanupEnabled: Bool = false,
        soundEnabled: Bool = false,
        entries: [DictionaryEntry] = [],
        injectOutcome: TextInjector.Outcome = .landed,
        frontmostProcessID: pid_t? = nil
    ) {
        let recorder = PipelineRecorder()
        let settings = UtterancePipeline.SettingsSnapshot(
            cleanupEnabled: cleanupEnabled,
            smartCleanup: false,
            soundEnabled: soundEnabled
        )
        self.recorder = recorder
        pipeline = UtterancePipeline(
            readEngineName: { Self.engineName },
            readSettings: { settings },
            makeCorrector: { DictionaryCorrector(entries: entries) },
            recordHistory: { run in recorder.recorded.append(run) },
            inject: { text, _ in
                recorder.injected.append(text)
                return injectOutcome
            },
            playEndSound: { recorder.soundPlays += 1 },
            readFrontmostProcessID: { frontmostProcessID }
        )
    }

    var injected: [String] { recorder.injected }
    var recorded: [DictationRun] { recorder.recorded }
    var soundPlays: Int { recorder.soundPlays }
}

private func makeUtterance(
    source: UtteranceSource,
    heldSeconds: TimeInterval = 1.5,
    releasedAt: Date = Date(timeIntervalSince1970: 1_788_256_800),
    targetProcessID: pid_t? = nil
) -> Utterance {
    Utterance(source: source, heldSeconds: heldSeconds, releasedAt: releasedAt, targetProcessID: targetProcessID)
}

private let cloudCodeCorrection = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")

@MainActor
@Suite(.serialized)
struct UtterancePipelineTests {
    @Test func focusMovedToAnotherAppSavesToHistoryWithoutTyping() async {
        let harness = PipelineHarness(soundEnabled: true, frontmostProcessID: 200)

        let notice = await harness.pipeline.process(
            raw: "meant for the editor", utterance: makeUtterance(source: .hotkey, targetProcessID: 100)
        )

        #expect(harness.injected.isEmpty)
        #expect(harness.recorded.map(\.text) == ["meant for the editor"])
        #expect(notice == UtterancePipeline.focusMovedMessage)
        #expect(harness.soundPlays == 0)
    }

    @Test func sameAppStillFrontmostIsTyped() async {
        let harness = PipelineHarness(soundEnabled: true, frontmostProcessID: 100)

        let notice = await harness.pipeline.process(
            raw: "typed here", utterance: makeUtterance(source: .hotkey, targetProcessID: 100)
        )

        #expect(harness.injected == ["typed here"])
        #expect(notice == nil)
        #expect(harness.soundPlays == 1)
    }

    @Test func focusMovingDuringInjectionReportsItAndSkipsTheSound() async {
        let harness = PipelineHarness(soundEnabled: true, injectOutcome: .focusMoved)

        let notice = await harness.pipeline.process(raw: "not here", utterance: makeUtterance(source: .hotkey))

        #expect(harness.recorded.map(\.text) == ["not here"])
        #expect(notice == UtterancePipeline.focusMovedMessage)
        #expect(harness.soundPlays == 0)
    }

    @Test func failedInjectionReportsAndSkipsTheLandedSound() async {
        let harness = PipelineHarness(soundEnabled: true, injectOutcome: .failed)

        let notice = await harness.pipeline.process(raw: "lost text", utterance: makeUtterance(source: .hotkey))

        #expect(harness.injected == ["lost text"])
        #expect(harness.recorded.map(\.text) == ["lost text"])
        #expect(notice == UtterancePipeline.insertFailedMessage)
        #expect(harness.soundPlays == 0)
    }

    @Test func buttonUtteranceIsRecordedButNeverInjected() async {
        let harness = PipelineHarness()

        await harness.pipeline.process(raw: "from the window", utterance: makeUtterance(source: .button))

        #expect(harness.injected.isEmpty)
        #expect(harness.recorded.map(\.text) == ["from the window"])
        #expect(harness.recorded.first?.source == "button")
    }

    @Test func hotkeyUtteranceInjectsTheCorrectedText() async {
        let harness = PipelineHarness(entries: [cloudCodeCorrection])

        await harness.pipeline.process(raw: "open cloud code", utterance: makeUtterance(source: .hotkey))

        #expect(harness.injected == ["open Claude Code"])
        #expect(harness.recorded.map(\.text) == ["open Claude Code"])
        #expect(harness.recorded.first?.source == "hotkey")
    }

    @Test func correctionsApplyWhenCleanupIsOff() async {
        let harness = PipelineHarness(cleanupEnabled: false, entries: [cloudCodeCorrection])

        await harness.pipeline.process(raw: "cloud code and cloud code", utterance: makeUtterance(source: .hotkey))

        #expect(harness.injected == ["Claude Code and Claude Code"])
        #expect(harness.recorded.first?.corrections == [
            AppliedCorrection(from: "cloud code", to: "Claude Code", count: 2),
        ])
    }

    @Test func cleanupOnRunsTheRulesBeforeCorrections() async {
        let harness = PipelineHarness(cleanupEnabled: true, entries: [cloudCodeCorrection])

        await harness.pipeline.process(raw: "um, open cloud code", utterance: makeUtterance(source: .hotkey))

        #expect(harness.injected == ["Open Claude Code."])
    }

    @Test func recordedRunCarriesSourceAndAudioSecondsFromTheUtterance() async {
        let harness = PipelineHarness()
        let releasedAt = Date(timeIntervalSince1970: 1_700_000_000)

        await harness.pipeline.process(
            raw: "hello",
            utterance: makeUtterance(source: .hotkey, heldSeconds: 2.75, releasedAt: releasedAt)
        )

        #expect(harness.recorded.count == 1)
        let run = harness.recorded[0]
        #expect(run.source == "hotkey")
        #expect(run.audioSeconds == 2.75)
        #expect(run.date == releasedAt)
        #expect(run.engine == PipelineHarness.engineName)
        #expect(run.processSeconds >= 0)
        #expect(run.corrections == nil)
    }

    @Test func emptyTextAfterCleanupSkipsInjectAndHistory() async {
        let harness = PipelineHarness(soundEnabled: true)

        await harness.pipeline.process(raw: "  \n\t ", utterance: makeUtterance(source: .hotkey))

        #expect(harness.injected.isEmpty)
        #expect(harness.recorded.isEmpty)
        #expect(harness.soundPlays == 0)
    }

    @Test func endSoundFollowsTheSoundSetting() async {
        let silent = PipelineHarness(soundEnabled: false)
        await silent.pipeline.process(raw: "quiet", utterance: makeUtterance(source: .hotkey))
        #expect(silent.soundPlays == 0)

        let audible = PipelineHarness(soundEnabled: true)
        await audible.pipeline.process(raw: "loud", utterance: makeUtterance(source: .button))
        #expect(audible.soundPlays == 1)
    }
}
