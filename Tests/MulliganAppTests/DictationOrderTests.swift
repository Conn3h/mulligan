import Foundation
import Testing
@testable import Mulligan

// The controller's event-order matrix: every event the controller can receive, delivered in
// every state it can be in, plus the two-event sequences where the order matters. Each cell
// ends by checking the same invariants: at most one final callback per utterance and none for
// a cancelled one, the controller back at idle with no live tasks, capture stopped, every
// engine ended, and no engine created unless a press that should start one arrived.

/// One thing that can happen to the controller from outside.
enum OrderEvent: String, Sendable, CustomTestStringConvertible {
    case hotkeyPress
    case hotkeyRelease
    /// Press then release at once, as a quick tap of the key.
    case hotkeyTap
    /// What the monitor emits when it recovers a lost key-up: the release, then the press.
    case lostRelease
    case recordButton
    case stopButton
    case reloadHotkey
    case deactivate
    /// Capture could not survive a device change under the running session.
    case interruption
    /// A late interruption callback from a session that has already stopped.
    case staleInterruption
    case snapshotFailure
    /// Waits past the harness's short `maxHold`.
    case maxHold
    /// The erase key while push to talk is held (§6.16).
    case erase

    var testDescription: String { rawValue }
}

private let interruptionMessage = "The microphone changed and could not be restarted. Try again."
private let shortMaxHold: Duration = .milliseconds(100)
private let errorDisplay: Duration = .milliseconds(150)

@MainActor
fileprivate extension Harness {
    /// A harness for one matrix cell: the watchdog is short only when the cell is about it,
    /// so no other cell can be cut short by it on a busy machine.
    static func cell(
        _ event: OrderEvent,
        engines: [FakeEngine] = [FakeEngine(.init(finalText: "said"))],
        microphoneGate: Gate = Gate(),
        errorDisplayDuration: Duration = errorDisplay
    ) -> Harness {
        let harness = Harness(
            engines: engines,
            microphoneGate: microphoneGate,
            errorDisplayDuration: errorDisplayDuration,
            maxHold: event == .maxHold ? shortMaxHold : .seconds(180)
        )
        harness.controller.activate()
        return harness
    }

    func begin(_ source: UtteranceSource) {
        switch source {
        case .hotkey: hotkey.press()
        case .button: controller.startButtonRecording()
        }
    }

    func start(_ source: UtteranceSource) async throws {
        begin(source)
        try await settle("listening") { self.state == .listening }
    }

    func end(_ source: UtteranceSource) {
        switch source {
        case .hotkey: hotkey.release()
        case .button: controller.stopButtonRecording()
        }
    }

    func apply(_ event: OrderEvent) async throws {
        switch event {
        case .hotkeyPress: hotkey.press()
        case .hotkeyRelease: hotkey.release()
        case .hotkeyTap:
            hotkey.press()
            hotkey.release()
        case .lostRelease:
            hotkey.release()
            hotkey.press()
        case .recordButton: controller.startButtonRecording()
        case .stopButton: controller.stopButtonRecording()
        case .reloadHotkey: controller.reloadHotkey()
        case .deactivate: controller.deactivate()
        case .interruption: capture.emitInterruption(interruptionMessage)
        case .staleInterruption: capture.emitStaleInterruption(interruptionMessage)
        case .snapshotFailure: await factory.made.last?.failStream(TestError("analyzer died"))
        case .maxHold: try await Task.sleep(for: shortMaxHold * 3)
        case .erase: hotkey.erase()
        }
    }

    /// Waits for idle, then checks every invariant that must hold once the dust settles.
    func expectQuiet(
        engines: Int,
        callbacks: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await settle("idle with no live tasks") {
            self.state == .idle && self.controller.liveTaskCount == 0
        }
        // Long enough for a wrongly queued press to have started.
        try await Task.sleep(for: .milliseconds(30))
        #expect(state == .idle, sourceLocation: sourceLocation)
        #expect(controller.liveTaskCount == 0, sourceLocation: sourceLocation)
        #expect(controller.holdStartedAt == nil, sourceLocation: sourceLocation)
        #expect(!capture.isRunning, sourceLocation: sourceLocation)
        #expect(received.count == callbacks, sourceLocation: sourceLocation)
        #expect(factory.made.count == engines, sourceLocation: sourceLocation)
        for engine in factory.made {
            #expect(await engine.finishCalls <= 1, sourceLocation: sourceLocation)
            #expect(await engine.cancelCalls <= 1, sourceLocation: sourceLocation)
            #expect(await engine.terminalCalls >= 1, sourceLocation: sourceLocation)
        }
    }
}

// MARK: - Matrix axes

enum SetupPoint: String, CaseIterable, Sendable {
    case microphone
    case engineStart
    case inputFormat
}

enum EndingPhase: String, CaseIterable, Sendable {
    /// `engine.finish()` is suspended.
    case finishing
    /// `onFinalTranscript` is suspended.
    case delivering
}

private let startingEvents: [OrderEvent] = [
    .hotkeyPress, .hotkeyRelease, .lostRelease, .recordButton, .stopButton, .reloadHotkey, .deactivate,
    .erase,
]
private let listeningEvents: [OrderEvent] = [
    .hotkeyPress, .hotkeyRelease, .hotkeyTap, .lostRelease, .recordButton, .stopButton,
    .reloadHotkey, .deactivate, .interruption, .snapshotFailure, .maxHold, .erase,
]
private let endingEvents: [OrderEvent] = [
    .hotkeyPress, .hotkeyRelease, .hotkeyTap, .lostRelease, .recordButton, .stopButton,
    .reloadHotkey, .deactivate, .staleInterruption, .snapshotFailure, .maxHold, .erase,
]
private let queuedEvents: [OrderEvent] = [
    .hotkeyRelease, .lostRelease, .stopButton, .reloadHotkey, .deactivate, .staleInterruption,
    .snapshotFailure, .erase,
]
private let restingEvents: [OrderEvent] = [
    .hotkeyPress, .hotkeyRelease, .hotkeyTap, .lostRelease, .recordButton, .stopButton,
    .reloadHotkey, .deactivate, .staleInterruption, .erase,
]

@MainActor
@Suite(.serialized)
struct DictationOrderTests {
    init() {
        Settings.shared.soundEnabled = false
    }

    // MARK: Starting

    /// Parks a hotkey press at one of the three setup suspension points.
    private func parked(at point: SetupPoint, for event: OrderEvent) async -> (Harness, Gate) {
        let gate = Gate(open: false)
        let harness: Harness
        switch point {
        case .microphone:
            harness = .cell(event, microphoneGate: gate)
        case .engineStart:
            harness = .cell(event, engines: [FakeEngine(.init(startGate: gate))])
        case .inputFormat:
            harness = .cell(event, engines: [FakeEngine(.init(formatGate: gate))])
        }
        harness.hotkey.press()
        await gate.waitForArrival()
        return (harness, gate)
    }

    @Test(arguments: SetupPoint.allCases, startingEvents)
    func eventWhileStarting(_ point: SetupPoint, _ event: OrderEvent) async throws {
        let (harness, gate) = await parked(at: point, for: event)
        let enginesMade = harness.factory.made.count
        #expect(harness.state == .starting)
        try await harness.apply(event)

        switch event {
        case .hotkeyRelease, .stopButton, .reloadHotkey:
            // Ends as a release; nothing was heard, so no callback and no capture.
            #expect(harness.state == .finishing)
            await gate.open()
            try await harness.expectQuiet(engines: enginesMade, callbacks: 0)
            #expect(harness.capture.startCalls == 0)
        case .deactivate:
            #expect(harness.state == .starting)
            await gate.open()
            try await harness.expectQuiet(engines: enginesMade, callbacks: 0)
            #expect(harness.capture.startCalls == 0)
            for engine in harness.factory.made {
                #expect(await engine.finishCalls == 0)
            }
        case .lostRelease:
            // The recovered release ends this press; the press after it is queued.
            #expect(harness.state == .finishing)
            await gate.open()
            try await settle("queued press listening") { harness.state == .listening }
            #expect(harness.capture.startCalls == 1)
            harness.hotkey.release()
            try await harness.expectQuiet(engines: enginesMade + 1, callbacks: 1)
        case .hotkeyPress, .recordButton:
            #expect(harness.state == .starting)
            await gate.open()
            try await settle("listening") { harness.state == .listening }
            harness.hotkey.release()
            try await harness.expectQuiet(engines: 1, callbacks: 1)
        case .erase:
            // Cancelled like a tap; once setup unwinds, the erase runs and the held key
            // starts a fresh utterance.
            #expect(harness.state == .starting)
            await gate.open()
            try await settle("restarted") { harness.state == .listening }
            #expect(harness.eraseCalls == 1)
            harness.hotkey.release()
            try await harness.expectQuiet(engines: enginesMade + 1, callbacks: 1)
        default:
            Issue.record("no expectation for \(event)")
        }
    }

    @Test func snapshotFailureWhileSuspendedAtInputFormat() async throws {
        let gate = Gate(open: false)
        let engine = FakeEngine(.init(formatGate: gate))
        let harness = Harness.cell(.snapshotFailure, engines: [engine])
        harness.hotkey.press()
        await gate.waitForArrival()
        await engine.failStream(TestError("analyzer died"))
        await gate.open()

        try await settle("error") { harness.state == .error("analyzer died") }
        #expect(!harness.capture.isRunning)
        try await harness.expectQuiet(engines: 1, callbacks: 0)
        #expect(await engine.cancelCalls == 1)
    }

    @Test func noInputFormatFailsWithoutCapture() async throws {
        let harness = Harness.cell(.hotkeyPress, engines: [FakeEngine(.init(format: nil))])
        harness.hotkey.press()
        try await settle("error") {
            harness.state == .error(TranscriptionError.noAudioFormat.localizedDescription)
        }
        #expect(harness.capture.startCalls == 0)
        try await harness.expectQuiet(engines: 1, callbacks: 0)
    }

    enum CaptureFailure: String, CaseIterable, Sendable {
        case generic
        case noInputDevice
        case inputNotReady

        var error: any Error {
            switch self {
            case .generic: TestError("capture broke")
            case .noInputDevice: AudioCaptureError.noInputDevice
            case .inputNotReady: AudioCaptureError.inputNotReady
            }
        }
    }

    @Test(arguments: CaptureFailure.allCases)
    func captureStartFailureShowsErrorAndTheNextPressWorks(_ failure: CaptureFailure) async throws {
        let harness = Harness.cell(.hotkeyPress, engines: [FakeEngine(), FakeEngine(.init(finalText: "second"))])
        harness.capture.failNextStart(with: failure.error)
        harness.hotkey.press()
        try await settle("error") { harness.state == .error(failure.error.localizedDescription) }
        harness.hotkey.release()
        #expect(!harness.capture.isRunning)

        try await harness.start(.hotkey)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 1)
        #expect(harness.received.map(\.text) == ["second"])
    }

    // MARK: Listening

    private enum ListeningOutcome {
        case ignored
        case delivered
        case deliveredThenMessage
        case cancelled
        case failed
        case deliveredThenQueuedStarts
        case erasedThenRestarts
    }

    private func expectedWhileListening(_ event: OrderEvent, _ source: UtteranceSource) -> ListeningOutcome {
        switch (event, source) {
        case (.hotkeyPress, _), (.recordButton, _): .ignored
        // A hotkey key-up, and a hotkey reload whose new monitor will never see a key-up,
        // concern only an utterance the hotkey started.
        case (.hotkeyRelease, .hotkey), (.hotkeyTap, .hotkey), (.reloadHotkey, .hotkey): .delivered
        case (.hotkeyRelease, .button), (.hotkeyTap, .button), (.reloadHotkey, .button): .ignored
        case (.lostRelease, .hotkey): .deliveredThenQueuedStarts
        case (.lostRelease, .button): .ignored
        case (.stopButton, _), (.maxHold, _): .delivered
        case (.deactivate, _): .cancelled
        case (.interruption, _): .deliveredThenMessage
        case (.snapshotFailure, _): .failed
        case (.staleInterruption, _): .ignored
        case (.erase, .hotkey): .erasedThenRestarts
        case (.erase, .button): .ignored
        }
    }

    @Test(arguments: listeningEvents, [UtteranceSource.hotkey, .button])
    func eventWhileListening(_ event: OrderEvent, _ source: UtteranceSource) async throws {
        let harness = Harness.cell(event)
        try await harness.start(source)
        let engine = try #require(harness.factory.made.first)
        await engine.publish("sa")
        try await settle("live transcript") { harness.controller.transcript == "sa" }
        try await harness.apply(event)

        switch expectedWhileListening(event, source) {
        case .ignored:
            try await Task.sleep(for: .milliseconds(30))
            #expect(harness.state == .listening)
            #expect(harness.capture.isRunning)
            harness.controller.stopButtonRecording()
            try await harness.expectQuiet(engines: 1, callbacks: 1)
        case .delivered:
            try await harness.expectQuiet(engines: 1, callbacks: 1)
            #expect(harness.received.map(\.text) == ["said"])
            #expect(await engine.cancelCalls == 0)
        case .deliveredThenMessage:
            try await settle("message") { harness.state == .error(interruptionMessage) }
            #expect(harness.received.map(\.text) == ["said"])
            try await harness.expectQuiet(engines: 1, callbacks: 1)
        case .cancelled:
            try await harness.expectQuiet(engines: 1, callbacks: 0)
            #expect(await engine.finishCalls == 0)
        case .failed:
            try await settle("error") { harness.state == .error("analyzer died") }
            try await harness.expectQuiet(engines: 1, callbacks: 0)
            #expect(await engine.finishCalls == 0)
        case .deliveredThenQueuedStarts:
            try await settle("queued press listening") {
                harness.state == .listening && harness.factory.made.count == 2
            }
            #expect(harness.received.map(\.text) == ["said"])
            harness.hotkey.release()
            try await harness.expectQuiet(engines: 2, callbacks: 2)
        case .erasedThenRestarts:
            try await settle("restarted") {
                harness.state == .listening && harness.factory.made.count == 2
            }
            #expect(harness.eraseCalls == 1)
            #expect(harness.received.isEmpty)
            #expect(await engine.finishCalls == 0)
            harness.hotkey.release()
            try await harness.expectQuiet(engines: 2, callbacks: 1)
        }
        if expectedWhileListening(event, source) == .ignored {
            #expect(harness.eraseCalls == 0)
        }
    }

    // MARK: Finishing and delivering

    /// A hotkey utterance released and parked either in `engine.finish()` or in delivery.
    private func parkedEnding(_ phase: EndingPhase, for event: OrderEvent) async throws -> (Harness, Gate) {
        let gate = Gate(open: false)
        let engine = FakeEngine(.init(finalText: "said", finishGate: phase == .finishing ? gate : Gate()))
        let harness = Harness.cell(event, engines: [engine])
        if phase == .delivering {
            harness.deliveryGate = gate
        }
        try await harness.start(.hotkey)
        await engine.publish("sa")
        try await settle("live transcript") { harness.controller.transcript == "sa" }
        harness.hotkey.release()
        await gate.waitForArrival()
        #expect(harness.state == .finishing)
        return (harness, gate)
    }

    @Test(arguments: EndingPhase.allCases, endingEvents)
    func eventWhileEnding(_ phase: EndingPhase, _ event: OrderEvent) async throws {
        let (harness, gate) = try await parkedEnding(phase, for: event)
        try await harness.apply(event)
        #expect(harness.state == .finishing)
        #expect(harness.factory.made.count == 1)
        await gate.open()

        let queued: UtteranceSource? = switch event {
        case .hotkeyPress, .lostRelease: .hotkey
        case .recordButton: .button
        default: nil
        }
        if let queued {
            try await settle("queued press listening") { harness.state == .listening }
            #expect(harness.received.count == 1)
            harness.end(queued)
            try await harness.expectQuiet(engines: 2, callbacks: 2)
            #expect(harness.received.map(\.utterance.source) == [.hotkey, queued])
        } else {
            try await harness.expectQuiet(engines: 1, callbacks: 1)
            let text = harness.received.first?.text
            #expect(text == (event == .snapshotFailure && phase == .finishing ? "sa" : "said"))
        }
        #expect(harness.hotkey.isRunning == (event != .deactivate))
        // Ending with no press queued, the key is not held: an erase cannot apply.
        #expect(harness.eraseCalls == 0)
    }

    // MARK: Queued press

    /// A hotkey utterance parked in `engine.finish()` with a second hotkey press queued.
    private func queuedBehindFinishing(for event: OrderEvent) async throws -> (Harness, Gate) {
        let gate = Gate(open: false)
        let engine = FakeEngine(.init(finalText: "said", finishGate: gate))
        let harness = Harness.cell(event, engines: [engine])
        try await harness.start(.hotkey)
        await engine.publish("sa")
        try await settle("live transcript") { harness.controller.transcript == "sa" }
        harness.hotkey.release()
        await gate.waitForArrival()
        harness.hotkey.press()
        return (harness, gate)
    }

    @Test(arguments: queuedEvents)
    func eventWhileAPressIsQueued(_ event: OrderEvent) async throws {
        let (harness, gate) = try await queuedBehindFinishing(for: event)
        try await harness.apply(event)
        await gate.open()

        switch event {
        case .hotkeyRelease, .stopButton, .reloadHotkey, .deactivate:
            // The queued key is no longer held, or its release can no longer be seen.
            try await harness.expectQuiet(engines: 1, callbacks: 1)
        case .lostRelease, .staleInterruption, .snapshotFailure:
            try await settle("queued press listening") { harness.state == .listening }
            harness.hotkey.release()
            try await harness.expectQuiet(engines: 2, callbacks: 2)
        case .erase:
            // Erases what the ending utterance delivered, then the queued press restarts.
            try await settle("queued press listening") { harness.state == .listening }
            #expect(harness.eraseCalls == 1)
            #expect(harness.received.map(\.text) == ["said"])
            harness.hotkey.release()
            try await harness.expectQuiet(engines: 2, callbacks: 2)
        default:
            Issue.record("no expectation for \(event)")
        }
    }

    @Test func queuedPressStartsAfterAFinishTimeout() async throws {
        let gate = Gate(open: false)
        let harness = Harness(
            engines: [FakeEngine(.init(finishGate: gate))],
            errorDisplayDuration: errorDisplay,
            engineFinishTimeout: .milliseconds(80)
        )
        harness.controller.activate()
        try await harness.start(.hotkey)
        harness.hotkey.release()
        await gate.waitForArrival()
        harness.hotkey.press()

        try await settle("queued press listening") { harness.state == .listening }
        #expect(harness.received.isEmpty)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 1)
        await gate.open()
    }

    @Test func queuedPressStartsAfterADeliveryNotice() async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(.hotkeyPress)
        harness.deliveryGate = gate
        harness.deliveryNotice = "Not typed."
        try await harness.start(.hotkey)
        harness.hotkey.release()
        await gate.waitForArrival()
        harness.hotkey.press()
        await gate.open()

        try await settle("queued press listening") { harness.state == .listening }
        harness.deliveryNotice = nil
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 2)
    }

    @Test func queuedPressWhoseEngineFailsShowsItsError() async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(
            .hotkeyPress,
            engines: [FakeEngine(.init(finishGate: gate)), FakeEngine(.init(startError: TestError("boom")))]
        )
        try await harness.start(.hotkey)
        harness.hotkey.release()
        await gate.waitForArrival()
        harness.hotkey.press()
        await gate.open()

        try await settle("second press failed") { harness.state == .error("boom") }
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 1)
    }

    // MARK: Error display and idle

    @Test(arguments: restingEvents)
    func eventWhileShowingAnError(_ event: OrderEvent) async throws {
        let harness = Harness.cell(event, errorDisplayDuration: .milliseconds(400))
        try await harness.start(.hotkey)
        harness.capture.emitInterruption(interruptionMessage)
        try await settle("error") { harness.state == .error(interruptionMessage) }
        try await harness.apply(event)
        try await expectRestingOutcome(harness, event, resting: .error(interruptionMessage))
    }

    @Test(arguments: restingEvents)
    func eventWhileIdle(_ event: OrderEvent) async throws {
        let harness = Harness.cell(event)
        try await harness.start(.hotkey)
        try await harness.releaseAndIdle()
        try await harness.apply(event)
        try await expectRestingOutcome(harness, event, resting: .idle)
    }

    /// Idle and the error display behave alike: a press starts a new utterance, anything else
    /// leaves the state alone.
    private func expectRestingOutcome(
        _ harness: Harness, _ event: OrderEvent, resting: DictationController.State
    ) async throws {
        switch event {
        case .hotkeyPress, .lostRelease, .recordButton:
            try await settle("listening") { harness.state == .listening }
            harness.end(event == .recordButton ? .button : .hotkey)
            try await harness.expectQuiet(engines: 2, callbacks: 2)
        case .hotkeyTap:
            // Released before setup got past the microphone: no engine, no callback.
            try await harness.expectQuiet(engines: 1, callbacks: 1)
        default:
            try await Task.sleep(for: .milliseconds(30))
            #expect(harness.state == resting)
            try await harness.expectQuiet(engines: 1, callbacks: 1)
            #expect(harness.eraseCalls == 0)
        }
    }

    // MARK: Two-event sequences

    @Test func eraseThenAnImmediateReleaseErasesWithoutRestarting() async throws {
        let harness = Harness.cell(.erase)
        try await harness.start(.hotkey)
        harness.hotkey.erase()
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 0)
        #expect(harness.eraseCalls == 1)
    }

    @Test func aSecondEraseInTheSameHoldIsIgnored() async throws {
        let harness = Harness.cell(.erase)
        harness.eraseGate = Gate(open: false)
        try await harness.start(.hotkey)
        harness.hotkey.erase()
        await harness.eraseGate?.waitForArrival()
        harness.hotkey.erase()
        await harness.eraseGate?.open()
        try await settle("restarted") { harness.state == .listening && harness.factory.made.count == 2 }
        #expect(harness.eraseCalls == 1)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 1)
    }

    @Test func eraseAfterAQueuedPressWhoseDeliveryShowedANotice() async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(.erase)
        harness.deliveryGate = gate
        harness.deliveryNotice = "Not typed."
        harness.eraseOutcome = .notTyped
        try await harness.start(.hotkey)
        harness.hotkey.release()
        await gate.waitForArrival()
        harness.hotkey.press()
        harness.hotkey.erase()
        await gate.open()
        // The erase refuses; its message wins over the delivery's, and nothing restarts.
        try await settle("erase message") { harness.state == .error(EraseOutcome.notTyped.message!) }
        #expect(harness.factory.made.count == 1)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func interruptionThenReleaseShowsTheMessageOnce() async throws {
        let harness = Harness.cell(.interruption)
        try await harness.start(.hotkey)
        harness.capture.emitInterruption(interruptionMessage)
        try await settle("capture stopped") { !harness.capture.isRunning }
        harness.hotkey.release()
        try await settle("message") { harness.state == .error(interruptionMessage) }
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func releaseThenStaleInterruptionShowsNoMessage() async throws {
        let harness = Harness.cell(.staleInterruption, errorDisplayDuration: .seconds(5))
        try await harness.start(.hotkey)
        harness.hotkey.release()
        #expect(harness.capture.emitStaleInterruption(interruptionMessage))
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func interruptionRacingAReleaseLetsTheReleaseWin() async throws {
        // The interruption's hop to the main actor is still pending when the key-up lands.
        let harness = Harness.cell(.interruption, errorDisplayDuration: .seconds(5))
        try await harness.start(.hotkey)
        harness.capture.emitInterruption(interruptionMessage)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func interruptionTwiceEndsOnceWithTheFirstMessage() async throws {
        let harness = Harness.cell(.interruption)
        try await harness.start(.hotkey)
        harness.capture.emitInterruption("first")
        harness.capture.emitInterruption("second")
        try await settle("first message") { harness.state == .error("first") }
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func interruptionDuringCaptureStartEndsTheUtteranceAfterListening() async throws {
        let harness = Harness.cell(.interruption)
        harness.capture.interruptDuringNextStart(interruptionMessage)
        harness.hotkey.press()
        try await settle("message") { harness.state == .error(interruptionMessage) }
        #expect(!harness.capture.isRunning)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func interruptionWithinTheMinimumHoldCancelsButStillShowsTheMessage() async throws {
        let harness = Harness(errorDisplayDuration: errorDisplay, minimumHold: .seconds(10))
        harness.controller.activate()
        try await harness.start(.hotkey)
        harness.capture.emitInterruption(interruptionMessage)
        try await settle("message") { harness.state == .error(interruptionMessage) }
        try await harness.expectQuiet(engines: 1, callbacks: 0)
        #expect(await harness.factory.made[0].finishCalls == 0)
    }

    @Test func interruptionWithAQueuedPressThenASwitchingInputRecovers() async throws {
        // Bluetooth drops mid-hold: the utterance ends, the queued press meets an input that
        // is still switching, and the press after that works.
        let gate = Gate(open: false)
        let harness = Harness.cell(.interruption, engines: [FakeEngine(.init(finalText: "said", finishGate: gate))])
        try await harness.start(.hotkey)
        harness.capture.emitInterruption(interruptionMessage)
        await gate.waitForArrival()
        harness.hotkey.release()
        harness.hotkey.press()
        harness.capture.failNextStart(with: AudioCaptureError.inputNotReady)
        await gate.open()

        let switching = AudioCaptureError.inputNotReady.localizedDescription
        try await settle("queued press failed") { harness.state == .error(switching) }
        harness.hotkey.release()
        try await harness.start(.hotkey)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 3, callbacks: 2)
    }

    enum LateSetupFailure: String, CaseIterable, Sendable {
        case microphoneDenied
        case engineStartThrows
        case noInputFormat
    }

    @Test(arguments: LateSetupFailure.allCases)
    func aSetupFailureAfterTheReleaseIsSilent(_ failure: LateSetupFailure) async throws {
        // The user let go first; the release wins and nothing is shown. The next press
        // meets the failure again and shows it then.
        // A long display, so an error shown by mistake would outlast the wait for idle.
        let gate = Gate(open: false)
        let harness: Harness
        switch failure {
        case .microphoneDenied:
            harness = Harness(microphoneGate: gate, microphoneAllowed: false, errorDisplayDuration: .seconds(5))
        case .engineStartThrows:
            harness = Harness(
                engines: [FakeEngine(.init(startError: TestError("boom"), startGate: gate))],
                errorDisplayDuration: .seconds(5)
            )
        case .noInputFormat:
            harness = Harness(
                engines: [FakeEngine(.init(format: nil, formatGate: gate))],
                errorDisplayDuration: .seconds(5)
            )
        }
        harness.controller.activate()
        harness.hotkey.press()
        await gate.waitForArrival()
        harness.hotkey.release()
        await gate.open()
        try await harness.expectQuiet(engines: failure == .microphoneDenied ? 0 : 1, callbacks: 0)
    }

    @Test func pressReloadReleaseEndsOnce() async throws {
        let harness = Harness.cell(.reloadHotkey)
        try await harness.start(.hotkey)
        harness.controller.reloadHotkey()
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
        #expect(harness.hotkey.startCalls == 2)
    }

    @Test func pressReloadReleaseWhileStartingEndsOnce() async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(.reloadHotkey, microphoneGate: gate)
        harness.hotkey.press()
        await gate.waitForArrival()
        harness.controller.reloadHotkey()
        harness.hotkey.release()
        await gate.open()
        try await harness.expectQuiet(engines: 0, callbacks: 0)
    }

    @Test func reloadDuringAButtonRecordingDropsOnlyAQueuedHotkeyPress() async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(.reloadHotkey, engines: [FakeEngine(.init(finishGate: gate))])
        try await harness.start(.button)
        harness.controller.stopButtonRecording()
        await gate.waitForArrival()
        harness.hotkey.press()
        harness.controller.reloadHotkey()
        await gate.open()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func deactivateDuringDeliveryDropsAQueuedPressAndKeepsTheText() async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(.deactivate)
        harness.deliveryGate = gate
        try await harness.start(.hotkey)
        harness.hotkey.release()
        await gate.waitForArrival()
        harness.hotkey.press()
        harness.controller.deactivate()
        #expect(!harness.hotkey.isRunning)
        await gate.open()
        try await harness.expectQuiet(engines: 1, callbacks: 1)

        // The window's Record button still works without the hotkey.
        try await harness.start(.button)
        harness.end(.button)
        try await harness.expectQuiet(engines: 2, callbacks: 2)
    }

    @Test func watchdogThenTheLateReleaseEndsOnce() async throws {
        let harness = Harness.cell(.maxHold)
        try await harness.start(.hotkey)
        try await harness.expectQuiet(engines: 1, callbacks: 1)
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }

    @Test func finishTimeoutThenALateFinishDeliversOnce() async throws {
        let gate = Gate(open: false)
        let engine = FakeEngine(.init(finalText: "late", finishGate: gate))
        let harness = Harness(
            engines: [engine], errorDisplayDuration: errorDisplay, engineFinishTimeout: .milliseconds(80)
        )
        harness.controller.activate()
        try await harness.start(.hotkey)
        await engine.publish("partial")
        try await settle("live transcript") { harness.controller.transcript == "partial" }
        harness.hotkey.release()

        try await settle("incomplete") {
            harness.state == .error(DictationController.transcriptionIncompleteMessage)
        }
        #expect(harness.received.map(\.text) == ["partial"])
        await gate.open()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
        #expect(await engine.cancelCalls == 1)
    }

    @Test func deliveryTimeoutThenANewUtteranceEachDeliverOnce() async throws {
        let gate = Gate(open: false)
        let harness = Harness(errorDisplayDuration: errorDisplay, deliveryTimeout: .milliseconds(80))
        harness.controller.activate()
        harness.deliveryGate = gate
        try await harness.start(.hotkey)
        harness.hotkey.release()
        try await settle("idle after delivery timeout") { harness.state == .idle }

        try await harness.start(.hotkey)
        harness.hotkey.release()
        try await settle("second delivery parked") { harness.received.count == 2 }
        try await harness.expectQuiet(engines: 2, callbacks: 2)
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.received.count == 2)
        #expect(harness.state == .idle)
    }

    @Test func tapThenAnImmediatePressStartsOnce() async throws {
        let harness = Harness(errorDisplayDuration: errorDisplay, minimumHold: .seconds(10))
        harness.controller.activate()
        try await harness.start(.hotkey)
        harness.hotkey.release()
        #expect(harness.state != .finishing)
        harness.hotkey.press()
        try await settle("second press listening") {
            harness.state == .listening && harness.factory.made.count == 2
        }
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 0)
    }

    @Test(arguments: [true, false])
    func hotkeyPressWhileAButtonRecordingEnds(keyStillHeld: Bool) async throws {
        let gate = Gate(open: false)
        let harness = Harness.cell(.hotkeyPress, engines: [FakeEngine(.init(finishGate: gate))])
        try await harness.start(.button)
        harness.controller.stopButtonRecording()
        await gate.waitForArrival()
        harness.hotkey.press()
        if !keyStillHeld {
            harness.hotkey.release()
        }
        await gate.open()

        if keyStillHeld {
            try await settle("queued hotkey press listening") { harness.state == .listening }
            harness.hotkey.release()
            try await harness.expectQuiet(engines: 2, callbacks: 2)
            #expect(harness.received.map(\.utterance.source) == [.button, .hotkey])
        } else {
            try await harness.expectQuiet(engines: 1, callbacks: 1)
        }
    }

    @Test func lostReleaseTwiceWhileListeningQueuesOnePress() async throws {
        let harness = Harness.cell(.lostRelease)
        try await harness.start(.hotkey)
        try await harness.apply(.lostRelease)
        try await harness.apply(.lostRelease)
        try await settle("queued press listening") {
            harness.state == .listening && harness.factory.made.count == 2
        }
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 2, callbacks: 2)
    }

    @Test func stopDuringAQueuedPressDropsIt() async throws {
        let (harness, gate) = try await queuedBehindFinishing(for: .stopButton)
        harness.controller.stopButtonRecording()
        await gate.open()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
        // The key's own release, arriving later, finds nothing to end.
        harness.hotkey.release()
        try await harness.expectQuiet(engines: 1, callbacks: 1)
    }
}
