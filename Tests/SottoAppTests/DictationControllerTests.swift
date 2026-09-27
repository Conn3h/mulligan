import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Sotto

private let microphoneDeniedMessage =
    "Microphone access is off. Enable it in System Settings > Privacy & Security > Microphone."

@MainActor
@Suite(.serialized)
struct DictationControllerTests {
    init() {
        // Keep the suite silent; the controller reads this per press.
        Settings.shared.soundEnabled = false
    }

    // MARK: Happy path

    @Test func pressListensReleasesAndFiresOneCallback() async throws {
        let engine = FakeEngine(.init(finalText: "hello world"))
        let harness = Harness(engines: [engine])
        #expect(harness.controller.activate())
        #expect(harness.state == .idle)
        #expect(harness.hotkey.startCalls == 1)

        harness.hotkey.press()
        #expect(harness.state == .starting)
        #expect(harness.state.isActive)
        #expect(harness.state.showsHUD)
        #expect(harness.controller.holdStartedAt != nil)
        #expect(harness.controller.transcript.isEmpty)

        try await settle("listening") { harness.state == .listening }
        #expect(harness.capture.startCalls == 1)
        #expect(harness.capture.isRunning)

        await engine.publish("hel")
        try await settle("live transcript") { harness.controller.transcript == "hel" }

        harness.hotkey.release()
        #expect(harness.state == .finishing)
        #expect(harness.capture.stopCalls >= 1)

        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "hello world")
        #expect(harness.received.first?.utterance.source == .hotkey)
        #expect((harness.received.first?.utterance.heldSeconds ?? -1) >= 0)
        #expect(harness.controller.transcript == "hello world")
        #expect(harness.controller.holdStartedAt == nil)
        #expect(harness.controller.liveTaskCount == 0)
        #expect(await engine.finishCalls == 1)
        #expect(await engine.cancelCalls == 0)
        #expect(!harness.state.showsHUD)
    }

    // MARK: Release while setup is suspended

    @Test func releaseWhileSuspendedAtMicrophoneRequest() async throws {
        let microphoneGate = Gate(open: false)
        let harness = Harness(microphoneGate: microphoneGate)
        harness.controller.activate()

        harness.hotkey.press()
        await microphoneGate.waitForArrival()
        #expect(harness.state == .starting)

        harness.hotkey.release()
        #expect(harness.state == .finishing)
        #expect(!harness.capture.emitBuffer())

        await microphoneGate.open()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.factory.made.isEmpty)
        #expect(harness.capture.startCalls == 0)
        #expect(harness.received.isEmpty)
        #expect(harness.controller.liveTaskCount == 0)

        try await harness.pressAndListen()
        #expect(harness.factory.made.count == 1)
        #expect(harness.controller.transcript.isEmpty)
        #expect(harness.capture.startCalls == 1)
        try await harness.releaseAndIdle()
        #expect(harness.received.count == 1)
    }

    @Test func releaseWhileSuspendedAtEngineStart() async throws {
        let startGate = Gate(open: false)
        let first = FakeEngine(.init(finalText: "stale", startGate: startGate))
        let second = FakeEngine(.init(finalText: "fresh"))
        let harness = Harness(engines: [first, second])
        harness.controller.activate()

        harness.hotkey.press()
        await startGate.waitForArrival()
        #expect(harness.factory.made.count == 1)

        harness.hotkey.release()
        #expect(harness.state == .finishing)
        #expect(harness.capture.startCalls == 0)
        #expect(!harness.capture.emitBuffer())

        await startGate.open()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.controller.liveTaskCount == 0)
        #expect(harness.capture.startCalls == 0)
        #expect(await first.fedFrameLengths.isEmpty)
        #expect(await first.terminalCalls == 1)
        #expect(harness.received.isEmpty)
        #expect(harness.controller.transcript.isEmpty)

        try await harness.pressAndListen()
        #expect(harness.factory.made.count == 2)
        #expect(harness.factory.made[1].id == second.id)
        #expect(harness.factory.made[1].id != first.id)
        #expect(harness.controller.transcript.isEmpty)
        #expect(await first.terminalCalls == 1)

        await second.publish("fre")
        try await settle("fresh transcript") { harness.controller.transcript == "fre" }
        try await harness.releaseAndIdle()
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "fresh")
    }

    @Test func releaseWhileSuspendedAtPreferredInputFormat() async throws {
        let formatGate = Gate(open: false)
        let first = FakeEngine(.init(finalText: "stale", formatGate: formatGate))
        let second = FakeEngine(.init(finalText: "fresh"))
        let harness = Harness(engines: [first, second])
        harness.controller.activate()

        harness.hotkey.press()
        await formatGate.waitForArrival()
        #expect(await first.startCalls == 1)

        harness.hotkey.release()
        #expect(harness.state == .finishing)
        #expect(harness.capture.startCalls == 0)

        await formatGate.open()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.controller.liveTaskCount == 0)
        #expect(harness.capture.startCalls == 0)
        #expect(!harness.capture.emitBuffer())
        #expect(await first.fedFrameLengths.isEmpty)
        #expect(await first.terminalCalls == 1)
        #expect(harness.received.isEmpty)

        try await harness.pressAndListen()
        #expect(harness.factory.made.count == 2)
        #expect(harness.factory.made[1].id == second.id)
        #expect(harness.controller.transcript.isEmpty)
        #expect(harness.capture.startCalls == 1)
        try await harness.releaseAndIdle()
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "fresh")
        #expect(await first.terminalCalls == 1)
    }

    // MARK: Terminal-event discipline

    @Test func duplicateReleaseFiresOneCallback() async throws {
        let engine = FakeEngine()
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()

        harness.hotkey.release()
        harness.hotkey.release()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(await engine.finishCalls == 1)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func pressWhileFinishingIsIgnored() async throws {
        let finishGate = Gate(open: false)
        let engine = FakeEngine(.init(finishGate: finishGate))
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()

        harness.hotkey.release()
        await finishGate.waitForArrival()
        #expect(harness.state == .finishing)

        harness.hotkey.press()
        #expect(harness.state == .finishing)
        #expect(harness.factory.made.count == 1)
        #expect(harness.capture.startCalls == 1)

        await finishGate.open()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(harness.factory.made.count == 1)
    }

    @Test func failureAfterReleaseIsIgnored() async throws {
        let finishGate = Gate(open: false)
        let engine = FakeEngine(.init(finalText: "unused", finishGate: finishGate))
        let harness = Harness(engines: [engine], errorDisplayDuration: .seconds(5))
        harness.controller.activate()
        try await harness.pressAndListen()
        await engine.publish("partial")
        try await settle("partial transcript") { harness.controller.transcript == "partial" }

        harness.hotkey.release()
        await finishGate.waitForArrival()
        #expect(harness.state == .finishing)

        // The analyzer dies while the release is already being finished: the release wins.
        await engine.failStream(TestError("late failure"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.state == .finishing)

        await finishGate.open()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "partial")
        #expect(await engine.cancelCalls == 0)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func deactivateWhileFinishingKeepsTheRelease() async throws {
        let finishGate = Gate(open: false)
        let engine = FakeEngine(.init(finalText: "kept", finishGate: finishGate))
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()

        harness.hotkey.release()
        await finishGate.waitForArrival()
        harness.controller.deactivate()
        #expect(harness.hotkey.stopCalls == 1)
        #expect(harness.state == .finishing)

        await finishGate.open()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "kept")
        #expect(await engine.finishCalls == 1)
        #expect(await engine.cancelCalls == 0)
        #expect(harness.controller.liveTaskCount == 0)
    }

    // MARK: Failures

    @Test func engineStartFailureShowsErrorThenIdle() async throws {
        let engine = FakeEngine(.init(startError: TestError("boom")))
        let harness = Harness(engines: [engine], errorDisplayDuration: .milliseconds(80))
        harness.controller.activate()

        harness.hotkey.press()
        try await settle("error state") { harness.state == .error("boom") }
        #expect(harness.state.showsHUD)
        #expect(!harness.state.isActive)
        #expect(harness.capture.startCalls == 0)
        #expect(harness.controller.holdStartedAt == nil)

        try await settle("idle after display") { harness.state == .idle }
        #expect(harness.received.isEmpty)
        #expect(await engine.cancelCalls == 1)
        #expect(await engine.finishCalls == 0)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func snapshotStreamFailureShowsErrorAndStopsCapture() async throws {
        let engine = FakeEngine()
        let harness = Harness(engines: [engine], errorDisplayDuration: .seconds(5))
        harness.controller.activate()
        try await harness.pressAndListen()
        let stopsBefore = harness.capture.stopCalls

        await engine.failStream(TestError("analyzer died"))
        try await settle("error state") { harness.state == .error("analyzer died") }
        #expect(harness.capture.stopCalls > stopsBefore)
        #expect(!harness.capture.isRunning)
        #expect(harness.received.isEmpty)
        #expect(await engine.cancelCalls == 1)
        #expect(await engine.finishCalls == 0)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func microphoneDeniedShowsMessageWithoutEngine() async throws {
        let harness = Harness(microphoneAllowed: false, errorDisplayDuration: .seconds(5))
        harness.controller.activate()

        harness.hotkey.press()
        try await settle("error state") { harness.state == .error(microphoneDeniedMessage) }
        #expect(harness.factory.made.isEmpty)
        #expect(harness.capture.startCalls == 0)
        #expect(harness.received.isEmpty)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func pressFromErrorStartsANewUtterance() async throws {
        let harness = Harness(microphoneAllowed: false, errorDisplayDuration: .seconds(5))
        harness.controller.activate()
        harness.hotkey.press()
        try await settle("error state") { harness.state == .error(microphoneDeniedMessage) }

        harness.hotkey.press()
        #expect(harness.state == .starting)
        try await settle("second error") {
            harness.state == .error(microphoneDeniedMessage) && harness.controller.liveTaskCount == 0
        }
    }

    // MARK: Lifecycle

    @Test func deactivateDuringListeningCancelsEngine() async throws {
        let engine = FakeEngine()
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()

        harness.controller.deactivate()
        #expect(harness.hotkey.stopCalls == 1)
        #expect(!harness.hotkey.isRunning)
        try await settle("idle") { harness.state == .idle }
        #expect(await engine.cancelCalls == 1)
        #expect(await engine.finishCalls == 0)
        #expect(harness.received.isEmpty)
        #expect(!harness.capture.isRunning)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func reloadHotkeyDuringListeningEndsAsRelease() async throws {
        let previousKey = Settings.shared.pushToTalkKey
        defer { Settings.shared.pushToTalkKey = previousKey }
        Settings.shared.pushToTalkKey = .rightOption

        let engine = FakeEngine(.init(finalText: "kept"))
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        #expect(harness.hotkey.key == .rightOption)
        try await harness.pressAndListen()

        Settings.shared.pushToTalkKey = .fn
        #expect(harness.controller.reloadHotkey())
        #expect(harness.hotkey.stopCalls == 1)
        #expect(harness.hotkey.startCalls == 2)
        #expect(harness.hotkey.key == .fn)
        #expect(harness.hotkey.keysAtStart == [.rightOption, .fn])

        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "kept")
        #expect(await engine.finishCalls == 1)
        #expect(harness.controller.liveTaskCount == 0)
    }

    // MARK: Audio path

    @Test func fiftyBuffersArriveInOrder() async throws {
        let engine = FakeEngine()
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()

        for index in 1...50 {
            #expect(harness.capture.emitBuffer(frameLength: AVAudioFrameCount(index)))
        }
        try await harness.releaseAndIdle()
        #expect(await engine.fedFrameLengths == (1...50).map { AVAudioFrameCount($0) })
    }

    /// Invariant 2 (§4): one unbounded stream, one drain task. With `feed` blocked, exactly
    /// one feed is in flight (a task per buffer would park a hundred at the gate) and the
    /// buffers queued behind it are delivered in capture order once it is released.
    @Test func hundredBuffersQueuedBehindABlockedFeedArriveInOrder() async throws {
        let feedGate = Gate(open: false)
        let engine = FakeEngine(.init(feedGate: feedGate))
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()

        #expect(harness.capture.emitBuffer(frameLength: 1))
        await feedGate.waitForArrival()
        for index in 2...100 {
            #expect(harness.capture.emitBuffer(frameLength: AVAudioFrameCount(index)))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await engine.fedFrameLengths.isEmpty)
        #expect(await feedGate.arrivals == 1)

        await feedGate.open()
        try await harness.releaseAndIdle()
        #expect(await engine.fedFrameLengths == (1...100).map { AVAudioFrameCount($0) })
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func blankFinalTranscriptSkipsCallback() async throws {
        let engine = FakeEngine(.init(finalText: "  \n "))
        let harness = Harness(engines: [engine])
        harness.controller.activate()
        try await harness.pressAndListen()
        try await harness.releaseAndIdle()
        #expect(harness.received.isEmpty)
        #expect(await engine.finishCalls == 1)
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func staleLevelCallbackDoesNotChangeLevel() async throws {
        let harness = Harness()
        harness.controller.activate()
        try await harness.pressAndListen()
        #expect(harness.controller.level == 0)

        #expect(harness.capture.emitLevel(0.8))
        try await settle("level rises") { harness.controller.level > 0 }
        let raised = harness.controller.level
        #expect(abs(raised - 0.8 * 0.35) < 0.001)

        try await harness.releaseAndIdle()
        #expect(harness.controller.level == 0)

        #expect(harness.capture.emitStaleLevel(1.0))
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.controller.level == 0)

        try await harness.pressAndListen()
        #expect(harness.capture.emitStaleLevel(1.0))
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.controller.level == 0)

        #expect(harness.capture.emitLevel(0.5))
        try await settle("current level applies") { harness.controller.level > 0 }
        try await harness.releaseAndIdle()
    }

    @Test func buttonSourceReachesCallback() async throws {
        let engine = FakeEngine(.init(finalText: "from the window"))
        let harness = Harness(engines: [engine])

        harness.controller.startButtonRecording()
        try await settle("listening") { harness.state == .listening }
        harness.controller.stopButtonRecording()
        try await settle("idle") { harness.state == .idle }

        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "from the window")
        #expect(harness.received.first?.utterance.source == .button)
        #expect(harness.hotkey.startCalls == 0)
    }

    @Test func captureStartFailureShowsError() async throws {
        let engine = FakeEngine()
        let harness = Harness(engines: [engine], errorDisplayDuration: .seconds(5))
        harness.capture.failNextStart(with: TestError("no input device"))
        harness.controller.activate()

        harness.hotkey.press()
        try await settle("error state") { harness.state == .error("no input device") }
        #expect(await engine.cancelCalls == 1)
        #expect(harness.received.isEmpty)
        #expect(harness.controller.liveTaskCount == 0)
    }

    // MARK: A quick tap recovers instantly

    @Test func quickTapCancelsInstantlyWithoutFinishing() async throws {
        // A hold shorter than `minimumHold` is a mis-tap: the controller cancels the engine
        // instead of finalizing it, never entering `.finishing`, and returns to idle at once
        // with no callback. This is the instant-recovery path for the reported quick tap; the
        // large threshold makes the test's near-instant release fall below it.
        let engine = FakeEngine()
        let harness = Harness(engines: [engine], minimumHold: .seconds(10))
        harness.controller.activate()
        try await harness.pressAndListen()

        harness.hotkey.release()
        // No "Transcribing..." flash: a tap never routes through .finishing on its way to idle.
        #expect(harness.state != .finishing)

        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.isEmpty)
        #expect(await engine.cancelCalls == 1)
        #expect(await engine.finishCalls == 0)
        #expect(harness.controller.holdStartedAt == nil)
        #expect(harness.controller.liveTaskCount == 0)
    }

    // MARK: A hung transcript delivery must not wedge .finishing

    @Test func stalledDeliveryTimesOutAndReachesIdle() async throws {
        // The other await in the terminal path is transcript delivery (format + inject). A
        // hung pipeline or AX injection must not hold the controller in .finishing, which the
        // Stop button cannot rescue. Delivery is bounded; on timeout the controller idles.
        let deliverGate = Gate(open: false)
        let engine = FakeEngine(.init(finalText: "text"))
        let harness = Harness(engines: [engine], deliveryTimeout: .milliseconds(120))
        harness.controller.activate()
        var deliveryStarted = false
        harness.controller.onFinalTranscript = { _, _ in
            deliveryStarted = true
            await deliverGate.pass()
            return nil
        }
        try await harness.pressAndListen()

        harness.hotkey.release()
        try await settle("idle after delivery timeout", timeout: .seconds(2)) { harness.state == .idle }
        #expect(deliveryStarted)
        #expect(harness.controller.liveTaskCount == 0)
        await deliverGate.open()
    }

    // MARK: A lost release must not leave the mic hot forever

    @Test func maxHoldWatchdogEndsAStuckListen() async throws {
        // If a release event is never delivered (tap disabled across a lost key-up, sleep,
        // screen lock), nothing else ends the utterance. The watchdog must cap .listening and
        // end it as a release so the mic does not stay hot and the transcript is still handed
        // over. No release is issued here at all; only the watchdog can end it.
        let engine = FakeEngine(.init(finalText: "salvaged"))
        let harness = Harness(engines: [engine], maxHold: .milliseconds(120))
        harness.controller.activate()
        try await harness.pressAndListen()

        try await settle("idle after watchdog", timeout: .seconds(2)) { harness.state == .idle }
        #expect(harness.received.count == 1)
        #expect(harness.received.first?.text == "salvaged")
        #expect(await engine.finishCalls == 1)
        #expect(harness.controller.holdStartedAt == nil)
        #expect(harness.controller.liveTaskCount == 0)
    }

    // MARK: A stalled engine finish must not wedge the utterance

    @Test func stalledEngineFinishTimesOutAndRecovers() async throws {
        // A quick tap can leave the real engine's finalize stuck; model that with a finish
        // gate that never opens. The controller must time out, cancel the engine, and idle
        // rather than sitting in .finishing forever (the reported quick-tap wedge).
        let finishGate = Gate(open: false)
        let engine = FakeEngine(.init(finishGate: finishGate))
        let harness = Harness(
            engines: [engine],
            errorDisplayDuration: .milliseconds(100),
            engineFinishTimeout: .milliseconds(150)
        )
        harness.controller.activate()
        try await harness.pressAndListen()

        harness.hotkey.release()
        #expect(harness.state == .finishing)

        // Nothing was transcribed before the timeout: say so rather than going quietly idle.
        try await settle("error after finish timeout", timeout: .seconds(2)) {
            harness.state == .error(DictationController.transcriptionTimedOutMessage)
        }
        #expect(await engine.cancelCalls >= 1)
        #expect(harness.received.isEmpty)
        try await settle("idle after the error", timeout: .seconds(2)) { harness.state == .idle }
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func finishTimeoutGrowsWithTheHoldUpToACap() {
        let base = Duration.seconds(2)
        #expect(DictationController.finishTimeout(base: base, heldSeconds: 0) == base)
        #expect(DictationController.finishTimeout(base: base, heldSeconds: 12) > .seconds(4))
        #expect(DictationController.finishTimeout(base: base, heldSeconds: 180) == DictationController.finishTimeoutCap)
    }

    // MARK: Speech gate

    @Test func silentHoldIsDiscardedBySpeechGate() async throws {
        let engine = FakeEngine(.init(finalText: "Mm-."))
        let harness = Harness(engines: [engine], speechGate: SpeechGate(voicedLevel: 0.3, minimumVoicedBlocks: 2))
        harness.controller.activate()
        try await harness.pressAndListen()
        for _ in 0..<6 {
            #expect(harness.capture.emitLevel(0.05))
        }
        try await Task.sleep(for: .milliseconds(30))
        try await harness.releaseAndIdle()
        #expect(harness.received.isEmpty)
        #expect(await engine.finishCalls == 1)
    }

    @Test func voicedHoldPassesSpeechGate() async throws {
        let engine = FakeEngine(.init(finalText: "yes"))
        let harness = Harness(engines: [engine], speechGate: SpeechGate(voicedLevel: 0.3, minimumVoicedBlocks: 2))
        harness.controller.activate()
        try await harness.pressAndListen()
        for level: Float in [0.05, 0.6, 0.7, 0.1] {
            #expect(harness.capture.emitLevel(level))
        }
        try await Task.sleep(for: .milliseconds(30))
        try await harness.releaseAndIdle()
        #expect(harness.received.map(\.text) == ["yes"])
    }

    @Test func singleLoudBlockDoesNotPassSpeechGate() async throws {
        // A key click or a bump is one loud block, not speech.
        let engine = FakeEngine(.init(finalText: "Mm-."))
        let harness = Harness(engines: [engine], speechGate: SpeechGate(voicedLevel: 0.3, minimumVoicedBlocks: 2))
        harness.controller.activate()
        try await harness.pressAndListen()
        for level: Float in [0.05, 0.9, 0.05] {
            #expect(harness.capture.emitLevel(level))
        }
        try await Task.sleep(for: .milliseconds(30))
        try await harness.releaseAndIdle()
        #expect(harness.received.isEmpty)
    }

    @Test func captureInterruptionEndsTheUtteranceWithItsMessage() async throws {
        let engine = FakeEngine(.init(finalText: "never delivered"))
        let harness = Harness(engines: [engine], errorDisplayDuration: .milliseconds(100))
        harness.controller.activate()
        try await harness.pressAndListen()

        #expect(harness.capture.emitInterruption("The microphone changed."))
        try await settle("error") { harness.state == .error("The microphone changed.") }
        #expect(harness.received.isEmpty)
        #expect(await engine.cancelCalls == 1)
        try await settle("idle after the error") { harness.state == .idle }
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func deliveryNoticeIsShownAsAnError() async throws {
        let engine = FakeEngine(.init(finalText: "meant for another app"))
        let harness = Harness(engines: [engine], errorDisplayDuration: .milliseconds(100))
        harness.deliveryNotice = "Not typed: the text is in History."
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.release()
        try await settle("notice shown") { harness.state == .error("Not typed: the text is in History.") }
        #expect(harness.received.count == 1)
        try await settle("idle after the notice") { harness.state == .idle }
    }

    // MARK: Sources

    @Test func hotkeyReleaseDoesNotEndAButtonRecording() async throws {
        let engine = FakeEngine(.init(finalText: "from the window"))
        let harness = Harness(engines: [engine])
        harness.controller.activate()

        harness.controller.startButtonRecording()
        try await settle("listening") { harness.state == .listening }
        // The user taps the push-to-talk key (Right Command for Command-Tab, say).
        harness.hotkey.press()
        harness.hotkey.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.state == .listening)

        harness.controller.stopButtonRecording()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.map(\.text) == ["from the window"])
    }
}

@Suite
struct PushToTalkKeyTests {
    @Test func keyCodesMatchTheHIToolboxConstants() {
        #expect(PushToTalkKey.rightOption.keyCode == 61)
        #expect(PushToTalkKey.rightCommand.keyCode == 54)
        #expect(PushToTalkKey.fn.keyCode == 63)
    }

    @Test func flagsAreTheDeviceSpecificBits() {
        #expect(PushToTalkKey.rightOption.flag.rawValue == 0x40)
        #expect(PushToTalkKey.rightCommand.flag.rawValue == 0x10)
        #expect(PushToTalkKey.fn.flag == .maskSecondaryFn)
        // The public Option mask cannot tell the two Option keys apart.
        #expect(PushToTalkKey.rightOption.flag != .maskAlternate)
    }

    @Test func onlyModifiersAreSwallowed() {
        #expect(PushToTalkKey.rightOption.consumesEvent)
        #expect(PushToTalkKey.rightCommand.consumesEvent)
        #expect(!PushToTalkKey.fn.consumesEvent)
    }

    @Test func displayNames() {
        #expect(PushToTalkKey.rightOption.displayName == "Right \u{2325}")
        #expect(PushToTalkKey.rightCommand.displayName == "Right \u{2318}")
        #expect(PushToTalkKey.fn.displayName == "fn")
        #expect(PushToTalkKey.allCases.count == 3)
    }
}
