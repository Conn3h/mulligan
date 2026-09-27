import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Sotto

// MARK: - Gate

/// A latch a test can close ahead of time, watch being reached, and open later. Used to park
/// the controller's setup task at a chosen suspension point so a release can arrive while it
/// is suspended.
actor Gate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWatchers: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    init(open: Bool = true) {
        isOpen = open
    }

    /// Records an arrival and suspends until the gate is open.
    func pass() async {
        arrivals += 1
        let watchers = arrivalWatchers
        arrivalWatchers = []
        for watcher in watchers {
            watcher.resume()
        }
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed {
            waiter.resume()
        }
    }

    /// Suspends until at least `count` callers have reached the gate.
    func waitForArrival(count: Int = 1) async {
        while arrivals < count {
            await withCheckedContinuation { continuation in
                arrivalWatchers.append(continuation)
            }
        }
    }
}

// MARK: - Errors and waiting

struct TestError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct SettleTimeout: Error, CustomStringConvertible {
    let what: String

    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
@MainActor
func settle(
    _ what: String,
    timeout: Duration = .seconds(3),
    until condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline {
            throw SettleTimeout(what: what)
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Fake hotkey

@MainActor
final class FakeHotkey: HotkeySource {
    var key: PushToTalkKey = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var startResult = true
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var isRunning = false
    private(set) var keysAtStart: [PushToTalkKey] = []

    @discardableResult
    func start() -> Bool {
        startCalls += 1
        keysAtStart.append(key)
        isRunning = startResult
        return startResult
    }

    func stop() {
        stopCalls += 1
        isRunning = false
    }

    func press() {
        onPress?()
    }

    func release() {
        onRelease?()
    }
}

// MARK: - Fake capture

/// Records `start`/`stop` calls and lets the test push buffers and levels through the
/// callbacks it was handed, including the callbacks of a session that has already stopped.
final class FakeCapture: AudioCapturing {
    struct Session: Sendable {
        let format: AVAudioFormat
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void
        let onInterruption: @Sendable (String) -> Void
    }

    private struct State: Sendable {
        var current: Session?
        var previous: Session?
        var startCalls = 0
        var stopCalls = 0
        var startError: TestError?
    }

    private let state = Mutex(State())

    var startCalls: Int { state.withLock { $0.startCalls } }
    var stopCalls: Int { state.withLock { $0.stopCalls } }
    var isRunning: Bool { state.withLock { $0.current != nil } }

    func failNextStart(with error: TestError) {
        state.withLock { $0.startError = error }
    }

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterruption: @escaping @Sendable (String) -> Void
    ) throws {
        try state.withLock { state in
            state.startCalls += 1
            if let error = state.startError {
                state.startError = nil
                throw error
            }
            let session = Session(
                format: outputFormat, onBuffer: onBuffer, onLevel: onLevel, onInterruption: onInterruption
            )
            state.previous = state.current ?? state.previous
            state.current = session
        }
    }

    func stop() {
        state.withLock { state in
            state.stopCalls += 1
            if let current = state.current {
                state.previous = current
                state.current = nil
            }
        }
    }

    /// Emits one buffer to the running session. `frameLength` tags the buffer so a test can
    /// check arrival order. Returns false when nothing is capturing.
    @discardableResult
    func emitBuffer(frameLength: AVAudioFrameCount = 1) -> Bool {
        guard let session = state.withLock({ $0.current }) else {
            return false
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: session.format, frameCapacity: frameLength) else {
            return false
        }
        buffer.frameLength = frameLength
        session.onBuffer(AudioChunk(buffer: buffer))
        return true
    }

    /// Reports that capture could not survive a device change, as the real capture does
    /// after a failed restart. Returns false when nothing is capturing.
    @discardableResult
    func emitInterruption(_ message: String) -> Bool {
        guard let session = state.withLock({ $0.current }) else {
            return false
        }
        session.onInterruption(message)
        return true
    }

    /// Emits a level to the running session. Returns false when nothing is capturing.
    @discardableResult
    func emitLevel(_ level: Float) -> Bool {
        guard let session = state.withLock({ $0.current }) else {
            return false
        }
        session.onLevel(level)
        return true
    }

    /// Fires the level callback of the most recently stopped session, as a late audio
    /// callback would. Returns false when no session has stopped yet.
    @discardableResult
    func emitStaleLevel(_ level: Float) -> Bool {
        guard let session = state.withLock({ $0.previous }) else {
            return false
        }
        session.onLevel(level)
        return true
    }
}

// MARK: - Fake engine

/// A transcription engine whose `start()`, `preferredInputFormat()`, `feed()` and `finish()`
/// park at gates the test controls, and which records everything the controller does to it.
actor FakeEngine: TranscriptionEngine {
    struct Configuration: Sendable {
        var finalText = "hello world"
        var startError: TestError?
        var format: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        var startGate = Gate()
        var formatGate = Gate()
        /// Closed, it holds every `feed` call, so buffers pile up behind the drain and the
        /// test can see how many feeds are in flight at once.
        var feedGate = Gate()
        var finishGate = Gate()
    }

    nonisolated let id = UUID()
    private let configuration: Configuration
    private(set) var startCalls = 0
    private(set) var formatCalls = 0
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0
    private(set) var fedFrameLengths: [AVAudioFrameCount] = []
    private var continuation: AsyncThrowingStream<TranscriptSnapshot, Error>.Continuation?
    private var isTerminated = false

    init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        formatCalls += 1
        await configuration.formatGate.pass()
        return configuration.format
    }

    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        startCalls += 1
        await configuration.startGate.pass()
        if let error = configuration.startError {
            throw error
        }
        let (stream, continuation) = AsyncThrowingStream<TranscriptSnapshot, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        await configuration.feedGate.pass()
        fedFrameLengths.append(chunk.buffer.frameLength)
    }

    func finish() async {
        finishCalls += 1
        await configuration.finishGate.pass()
        guard !isTerminated else {
            return
        }
        isTerminated = true
        continuation?.yield(TranscriptSnapshot(text: configuration.finalText, isFinal: true))
        continuation?.finish()
    }

    func cancel() async {
        cancelCalls += 1
        guard !isTerminated else {
            return
        }
        isTerminated = true
        continuation?.finish(throwing: CancellationError())
    }

    /// Publishes a live (non-final) snapshot, as the analyzer would while the user speaks.
    func publish(_ text: String) {
        continuation?.yield(TranscriptSnapshot(text: text, isFinal: false))
    }

    /// Fails the snapshot stream, as a broken analyzer would.
    func failStream(_ error: TestError) {
        continuation?.finish(throwing: error)
    }

    var terminalCalls: Int { finishCalls + cancelCalls }
}

/// Hands out pre-configured engines in order, then default ones, recording every instance.
@MainActor
final class EngineFactory {
    private var queued: [FakeEngine]
    private(set) var made: [FakeEngine] = []

    init(_ engines: [FakeEngine]) {
        queued = engines
    }

    func make() -> any TranscriptionEngine {
        let engine = queued.isEmpty ? FakeEngine() : queued.removeFirst()
        made.append(engine)
        return engine
    }
}

// MARK: - Harness

/// A controller wired to the fakes, plus the record of every final transcript it delivered.
@MainActor
final class Harness {
    let hotkey: FakeHotkey
    let capture: FakeCapture
    let factory: EngineFactory
    let microphoneGate: Gate
    let controller: DictationController
    private(set) var received: [(text: String, utterance: Utterance)] = []
    /// What the fake delivery reports back, as the pipeline does when text could not be typed.
    var deliveryNotice: String?

    init(
        engines: [FakeEngine] = [],
        microphoneGate: Gate = Gate(),
        microphoneAllowed: Bool = true,
        errorDisplayDuration: Duration = .seconds(3),
        engineFinishTimeout: Duration = .seconds(2),
        minimumHold: Duration = .zero,
        maxHold: Duration = .seconds(180),
        deliveryTimeout: Duration = .seconds(10),
        speechGate: SpeechGate = .disabled
    ) {
        let hotkey = FakeHotkey()
        let capture = FakeCapture()
        let factory = EngineFactory(engines)
        self.hotkey = hotkey
        self.capture = capture
        self.factory = factory
        self.microphoneGate = microphoneGate
        controller = DictationController(
            hotkey: hotkey,
            capture: capture,
            requestMicrophone: {
                await microphoneGate.pass()
                return microphoneAllowed
            },
            makeEngine: { factory.make() },
            errorDisplayDuration: errorDisplayDuration,
            engineFinishTimeout: engineFinishTimeout,
            minimumHold: minimumHold,
            maxHold: maxHold,
            deliveryTimeout: deliveryTimeout,
            speechGate: speechGate
        )
        controller.onFinalTranscript = { [weak self] text, utterance in
            self?.received.append((text: text, utterance: utterance))
            return self?.deliveryNotice
        }
    }

    var state: DictationController.State { controller.state }

    func pressAndListen() async throws {
        hotkey.press()
        try await settle("listening") { self.controller.state == .listening }
    }

    func releaseAndIdle() async throws {
        hotkey.release()
        try await settle("idle after release") { self.controller.state == .idle }
    }
}
