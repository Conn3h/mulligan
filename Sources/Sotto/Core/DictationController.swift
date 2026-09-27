import AppKit
import AVFoundation
import Foundation
import Observation
import SottoText

enum UtteranceSource: String, Sendable {
    case hotkey
    case button
}

struct Utterance: Sendable {
    let source: UtteranceSource
    /// Key down to key up, measured with `ContinuousClock`.
    let heldSeconds: TimeInterval
    /// Wall clock, for history display only.
    let releasedAt: Date
    /// The frontmost app when the key was released: the text is typed only if it is still
    /// frontmost when the text is ready. Nil when unknown.
    let targetProcessID: pid_t?

    init(source: UtteranceSource, heldSeconds: TimeInterval, releasedAt: Date, targetProcessID: pid_t? = nil) {
        self.source = source
        self.heldSeconds = heldSeconds
        self.releasedAt = releasedAt
        self.targetProcessID = targetProcessID
    }
}

/// The one-utterance-at-a-time state machine between the hotkey, capture and the engine.
/// Each press starts a generation; every terminal event funnels into one terminal task per
/// generation, which is the only code that finishes the engine, fires the final callback,
/// and returns the controller to idle.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        /// Removing the last dictation from the target app (§6.16).
        case erasing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing, .erasing: true
            case .idle, .error: false
            }
        }

        var showsHUD: Bool {
            if case .error = self {
                return true
            }
            return isActive
        }
    }

    private enum TerminalReason {
        case released
        /// A release too brief to be dictation. Cancels the engine like `.aborted`, but is
        /// its own case so the log and the SPEC can tell a mis-tap from a real abort.
        case tapped
        case failed(String)
        case aborted
        /// The erase key: cancels like `.tapped`, then the terminal task erases (§6.16).
        case erased

        /// True only for `.released`: the path that finalizes the engine, fires the callback,
        /// and shows `.finishing`. A tap is deliberately not a release.
        var isRelease: Bool {
            if case .released = self {
                return true
            }
            return false
        }

        var label: String {
            switch self {
            case .released: "released"
            case .tapped: "tapped"
            case .failed: "failed"
            case .aborted: "aborted"
            case .erased: "erased"
            }
        }
    }

    /// One utterance. Created on press, cleared by the terminal task and by nothing else.
    @MainActor
    private final class Session {
        let id: Int
        let source: UtteranceSource
        let pressedAt: ContinuousClock.Instant
        var releasedAt: ContinuousClock.Instant?
        var releasedDate: Date?
        var targetProcessID: pid_t?
        /// Why capture stopped under this utterance, shown once its text is delivered.
        var interruptionNotice: String?
        /// An interruption that arrived while setup was still running (capture starts off the
        /// main actor); applied once setup finishes, so it ends the utterance the same way
        /// whichever side of that boundary it lands on.
        var interruptionDuringSetup: String?
        var engine: (any TranscriptionEngine)?
        var audioContinuation: AsyncStream<AudioChunk>.Continuation?
        var setupTask: Task<Void, Never>?
        var drainTask: Task<Void, Never>?
        var consumeTask: Task<Void, Never>?
        var terminalTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?
        /// Loudest raw meter level this hold, logged at release for diagnosis.
        var peakLevel: Float = 0
        /// The terminal task erases the last dictation before returning to idle (§6.16):
        /// this utterance's own, cancelled by the erase key, or one that was already ending
        /// when the key was pressed again and the erase key tapped.
        var eraseRequested = false

        init(id: Int, source: UtteranceSource, pressedAt: ContinuousClock.Instant) {
            self.id = id
            self.source = source
            self.pressedAt = pressedAt
        }

        var isTerminating: Bool { terminalTask != nil }

        func heldSeconds(now: ContinuousClock.Instant) -> TimeInterval {
            let duration = (releasedAt ?? now) - pressedAt
            let (seconds, attoseconds) = duration.components
            return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
        }
    }

    static let microphoneDeniedMessage =
        "Microphone access is off. Enable it in System Settings > Privacy & Security > Microphone."
    static let transcriptionTimedOutMessage = "Transcription took too long; nothing was typed. Try again."
    static let transcriptionIncompleteMessage = "Transcription took too long; the end may be missing."
    /// The most `finishTimeout` ever grows to, however long the hold.
    static let finishTimeoutCap: Duration = .seconds(15)
    /// Extra finish time per second held. Parakeet decodes nothing until 13 s of audio is
    /// buffered, so a shorter hold is decoded entirely after release (about 0.1 s per
    /// second held on an idle machine); this leaves room for a busy one.
    private static let finishTimeoutPerHeldSecond = 0.25
    private static let levelSmoothing: Float = 0.35
    private static let startSoundName = "Tink"

    private(set) var state: State = .idle
    /// Live transcript, drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0...1 meter level.
    private(set) var level: Float = 0
    /// For the main window's elapsed counter.
    private(set) var holdStartedAt: Date?
    /// Number of tasks belonging to any utterance that have not completed. Exposed for tests.
    private(set) var liveTaskCount = 0

    /// Receives the final raw transcript once per utterance. Awaited before returning to idle.
    /// A returned message (the text was recorded but not typed) is shown as the ending error.
    @ObservationIgnored var onFinalTranscript: (@MainActor (String, Utterance) async -> String?)?

    @ObservationIgnored private let hotkey: any HotkeySource
    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let requestMicrophone: @MainActor () async -> Bool
    @ObservationIgnored private let makeEngine: @MainActor () -> any TranscriptionEngine
    @ObservationIgnored private let errorDisplayDuration: Duration
    /// A cap on `engine.finish()` in the terminal path. The engine's
    /// `finalizeAndFinishThroughEndOfInput` can stall when finishing an analyzer that saw
    /// almost no audio (a quick tap released just after listening began), which used to
    /// wedge the controller in `.finishing` forever, ignoring Stop and new presses. If
    /// finish does not return within this, the engine is cancelled and the utterance ends.
    /// This is the base: the cap grows with the hold, see `finishTimeout(base:heldSeconds:)`.
    @ObservationIgnored private let engineFinishTimeout: Duration
    /// A release held for less than this is a mis-tap, not dictation: the engine is
    /// cancelled instead of finalized, the state never enters `.finishing`, and no final
    /// callback fires. This is the instant-recovery path for a quick tap (the finalize would
    /// otherwise stall, and even bounded by `engineFinishTimeout` it flashes "Transcribing..."
    /// for the length of the timeout). Real speech, even one short word, comfortably clears
    /// this; anything longer that still captured no usable audio falls back to the bounded
    /// finish. Zero disables the fast path, so a release is always finalized.
    @ObservationIgnored private let minimumHold: Duration
    /// A cap on how long one utterance may stay in `.listening`. If a release is never
    /// delivered (the event tap was disabled across a lost key-up, or the key came up during
    /// sleep or screen lock), nothing else would end the utterance and the mic would stay hot.
    /// When this elapses the utterance ends as a release, so a stuck recording self-heals and
    /// whatever was transcribed is still delivered. Generous by default so no real hold is cut
    /// short; hotkey reconciliation handles the common lost-release case long before this.
    @ObservationIgnored private let maxHold: Duration
    /// A cap on final-transcript delivery (`onFinalTranscript`, which formats and injects the
    /// text). Its steps are individually bounded today, but this guarantees the terminal task
    /// cannot hold `.finishing` beyond a fixed cap if the pipeline or an AX injection ever
    /// hangs, and `.finishing` is the one state the Stop button cannot rescue. On timeout the
    /// controller stops waiting and returns to idle; the in-flight delivery is left to finish
    /// on its own rather than cancelled mid-paste.
    @ObservationIgnored private let deliveryTimeout: Duration
    /// A cap on the erase so a stuck target cannot hold `.erasing`. On timeout the eraser's
    /// token is revoked, so it stops before its next side effect.
    @ObservationIgnored private let eraseTimeout: Duration
    @ObservationIgnored private let eraseLast: @MainActor (EraseToken) async -> EraseOutcome
    /// The erase in flight, revoked by a timeout or `deactivate()`.
    @ObservationIgnored private var eraseToken: EraseToken?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var session: Session?
    /// A press that arrived while the previous utterance was still ending. It starts once
    /// that utterance returns to idle, unless its own release arrives first.
    @ObservationIgnored private var pendingPress: UtteranceSource?
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?

    init(
        hotkey: any HotkeySource,
        capture: any AudioCapturing,
        requestMicrophone: @escaping @MainActor () async -> Bool,
        makeEngine: @escaping @MainActor () -> any TranscriptionEngine,
        errorDisplayDuration: Duration = .seconds(3),
        engineFinishTimeout: Duration = .seconds(2),
        minimumHold: Duration = .milliseconds(250),
        maxHold: Duration = .seconds(180),
        deliveryTimeout: Duration = .seconds(10),
        eraseTimeout: Duration = .seconds(3),
        eraseLast: @escaping @MainActor (EraseToken) async -> EraseOutcome = { _ in .nothingToErase }
    ) {
        self.hotkey = hotkey
        self.capture = capture
        self.requestMicrophone = requestMicrophone
        self.makeEngine = makeEngine
        self.errorDisplayDuration = errorDisplayDuration
        self.engineFinishTimeout = engineFinishTimeout
        self.minimumHold = minimumHold
        self.maxHold = maxHold
        self.deliveryTimeout = deliveryTimeout
        self.eraseTimeout = eraseTimeout
        self.eraseLast = eraseLast
    }

    // MARK: Public controls

    /// Installs the hotkey from Settings. False means the tap could not be created, which
    /// means Accessibility is not granted.
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.eraseKey = Settings.shared.eraseKey
        hotkey.onPress = { [weak self] in
            self?.press(source: .hotkey)
        }
        hotkey.onRelease = { [weak self] in
            self?.release(onlyFrom: .hotkey)
        }
        hotkey.onErase = { [weak self] in
            self?.erase()
        }
        let started = hotkey.start()
        if !started {
            Log.hotkey.error("hotkey activation failed; Accessibility is required")
        }
        return started
    }

    /// Ends any utterance without a final callback, then stops the hotkey.
    func deactivate() {
        // An erase already running stops before its next side effect; one requested but not
        // yet started (its utterance is still unwinding) never starts.
        eraseToken?.revoke()
        if let session, session.eraseRequested {
            session.eraseRequested = false
            Log.app.info("erase for utterance \(session.id, privacy: .public) cancelled by deactivate")
        }
        dropPendingPress(reason: "controller deactivated")
        if let session {
            terminate(session, reason: .aborted)
        }
        hotkey.stop()
        Log.app.info("controller deactivated")
    }

    /// Ends a hotkey utterance as a release (the physical release will be invisible to the
    /// new monitor), then re-arms the hotkey with the key from Settings.
    @discardableResult
    func reloadHotkey() -> Bool {
        // The new key's monitor never sees the old key's release, so a press queued under
        // the old key would start recording with nothing held, and a hotkey utterance would
        // never end. A Record-button utterance does not depend on the key: changing the key
        // in Settings while recording from the window must not cut it short.
        if pendingPress == .hotkey {
            dropPendingPress(reason: "hotkey reloaded")
        }
        if let session, session.source == .hotkey {
            terminate(session, reason: .released)
        }
        hotkey.stop()
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.eraseKey = Settings.shared.eraseKey
        let started = hotkey.start()
        Log.hotkey.info(
            "hotkey reloaded to \(self.hotkey.key.displayName, privacy: .public); running: \(started, privacy: .public)"
        )
        return started
    }

    private func dropPendingPress(reason: String) {
        guard pendingPress != nil else {
            return
        }
        pendingPress = nil
        Log.app.info("queued press dropped: \(reason, privacy: .public)")
    }

    func startButtonRecording() {
        press(source: .button)
    }

    func stopButtonRecording() {
        release()
    }

    // MARK: Press and release

    private func press(source: UtteranceSource) {
        if let session {
            if session.isTerminating {
                // The hotkey press queued by an erase restarts it; Record must not replace it.
                if session.eraseRequested, source == .button {
                    Log.app.info("Record ignored: utterance \(session.id, privacy: .public) is erasing")
                    return
                }
                // Pressing again right after a release (or after a lost release was
                // recovered) used to be dropped, so the user talked to nothing.
                pendingPress = source
                Log.app.info(
                    "press queued: utterance \(session.id, privacy: .public) is still ending"
                )
            } else {
                Log.app.debug(
                    "press ignored: utterance \(session.id, privacy: .public) still \(String(describing: self.state), privacy: .public)"
                )
            }
            return
        }
        switch state {
        case .idle, .error:
            break
        case .starting, .listening, .finishing, .erasing:
            Log.app.error("press ignored: state \(String(describing: self.state), privacy: .public) without a session")
            return
        }
        errorResetTask?.cancel()
        errorResetTask = nil
        generation += 1
        let session = Session(id: generation, source: source, pressedAt: clock.now)
        self.session = session
        state = .starting
        transcript = ""
        level = 0
        holdStartedAt = Date()
        Log.app.info("utterance \(session.id, privacy: .public) press (\(source.rawValue, privacy: .public))")
        session.setupTask = track { [weak self] in
            await self?.runSetup(session)
        }
    }

    /// `onlyFrom` limits which utterances this release may end: the hotkey's key-up must not
    /// end a Record-button utterance (the user may be using the key for Command-Tab or a
    /// special character). The Stop button passes nil and ends any utterance.
    private func release(onlyFrom source: UtteranceSource? = nil) {
        if let pending = pendingPress, source == nil || source == pending {
            pendingPress = nil
            Log.app.info("queued press released before it could start; dropped")
            return
        }
        guard let session else {
            Log.app.debug("release ignored: no utterance")
            return
        }
        if let source, session.source != source {
            Log.app.info(
                "\(source.rawValue, privacy: .public) release ignored: utterance \(session.id, privacy: .public) was started by \(session.source.rawValue, privacy: .public)"
            )
            return
        }
        guard !session.isTerminating else {
            Log.app.debug("release ignored: utterance \(session.id, privacy: .public) already ending")
            return
        }
        terminate(session, reason: .released)
    }

    // MARK: Erase

    /// The erase key went down while push to talk is held (§6.16). A live hotkey utterance
    /// is cancelled and its terminal task erases; the hotkey press queued here then restarts
    /// dictation, unless the key comes up first (release drops a queued press). An utterance
    /// already ending, with this hold's press queued behind it, erases after its delivery.
    private func erase() {
        guard let session, session.source == .hotkey, !session.eraseRequested else {
            Log.app.info("erase ignored in state \(String(describing: self.state), privacy: .public)")
            return
        }
        if session.isTerminating {
            guard pendingPress == .hotkey else {
                Log.app.info("erase ignored: utterance \(session.id, privacy: .public) is ending and no press is queued")
                return
            }
            session.eraseRequested = true
            Log.app.info("erase queued behind utterance \(session.id, privacy: .public)")
            return
        }
        session.eraseRequested = true
        pendingPress = .hotkey
        terminate(session, reason: .erased)
    }

    // MARK: Setup task

    /// True while `session` is the current generation, has no terminal event yet, and this
    /// task has not been cancelled. Checked after every suspension point.
    private func isLive(_ session: Session) -> Bool {
        session === self.session
            && session.id == generation
            && !session.isTerminating
            && !Task.isCancelled
    }

    private func runSetup(_ session: Session) async {
        let microphoneAllowed = await requestMicrophone()
        guard isLive(session) else {
            return
        }
        guard microphoneAllowed else {
            Log.audio.error("microphone access denied; utterance \(session.id, privacy: .public) failed")
            terminate(session, reason: .failed(Self.microphoneDeniedMessage))
            return
        }

        let engine = makeEngine()
        session.engine = engine
        let snapshots: AsyncThrowingStream<TranscriptSnapshot, Error>
        do {
            snapshots = try await engine.start()
        } catch {
            guard isLive(session) else {
                return
            }
            Log.speech.error(
                "engine start failed for utterance \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            terminate(session, reason: .failed(error.localizedDescription))
            return
        }
        guard isLive(session) else {
            return
        }

        guard let format = await engine.preferredInputFormat() else {
            guard isLive(session) else {
                return
            }
            let failure = TranscriptionError.noAudioFormat
            Log.speech.error("utterance \(session.id, privacy: .public): \(failure.localizedDescription, privacy: .public)")
            terminate(session, reason: .failed(failure.localizedDescription))
            return
        }
        guard isLive(session) else {
            return
        }

        // One unbounded stream drained by exactly one task keeps audio in capture order.
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        session.audioContinuation = continuation
        session.drainTask = trackDetached {
            for await chunk in audio {
                if Task.isCancelled {
                    break
                }
                await engine.feed(chunk)
            }
        }

        // The continuation is the generation carrier for buffers: once the terminal task
        // finishes it, late yields from this session's tap are dropped by the stream.
        let generation = session.id
        // Off the main actor: a start on an input that is mid-switch retries with short
        // sleeps, which would otherwise freeze the HUD and the hotkey for that long.
        let capture = self.capture
        do {
            try await Task.detached(priority: .userInitiated) {
                try capture.start(
                outputFormat: format,
                onBuffer: { chunk in
                    continuation.yield(chunk)
                },
                onLevel: { [weak self] value in
                    Task { @MainActor in
                        self?.applyLevel(value, generation: generation)
                    }
                },
                onInterruption: { [weak self] message in
                    Task { @MainActor in
                        self?.captureInterrupted(message, generation: generation)
                    }
                }
                )
            }.value
        } catch {
            Log.audio.error(
                "capture start failed for utterance \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if isLive(session) {
                terminate(session, reason: .failed(error.localizedDescription))
            }
            return
        }
        // Released during the start: the terminal task awaits this setup and then stops
        // capture, so there is nothing more to do here.
        guard isLive(session) else {
            return
        }

        state = .listening
        Log.app.info("utterance \(session.id, privacy: .public) listening")
        if Settings.shared.soundEnabled {
            playStartSound()
        }
        session.consumeTask = track { [weak self] in
            await self?.consume(snapshots, for: session)
        }
        startWatchdog(session)
        if let message = session.interruptionDuringSetup {
            captureInterrupted(message, generation: session.id)
        }
    }

    /// Caps `.listening` at `maxHold`. If a release is never delivered nothing else would end
    /// the utterance; when the cap elapses this ends it as a release, so the mic cannot stay
    /// hot indefinitely. Cancelled by `terminate` the moment any real terminal event arrives.
    private func startWatchdog(_ session: Session) {
        session.watchdogTask = track { [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(for: self.maxHold)
            } catch {
                return
            }
            guard self.isLive(session), self.state == .listening else {
                return
            }
            Log.app.error(
                "utterance \(session.id, privacy: .public) hit the \(self.maxHold, privacy: .public) max-hold cap; ending as a release so the mic does not stay hot"
            )
            self.terminate(session, reason: .released)
        }
    }

    private func consume(
        _ snapshots: AsyncThrowingStream<TranscriptSnapshot, Error>,
        for session: Session
    ) async {
        do {
            for try await snapshot in snapshots {
                guard session === self.session, !Task.isCancelled else {
                    return
                }
                transcript = snapshot.text
            }
            Log.speech.debug("snapshot stream ended for utterance \(session.id, privacy: .public)")
        } catch is CancellationError {
            Log.speech.debug("snapshot stream cancelled for utterance \(session.id, privacy: .public)")
        } catch {
            Log.speech.error(
                "snapshot stream failed for utterance \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            terminate(session, reason: .failed(error.localizedDescription))
        }
    }

    /// Capture stopped under a live utterance (the input device changed and could not be
    /// restarted). End it rather than keep "listening" to nothing: as a release, so the text
    /// so far is delivered, then show the message.
    private func captureInterrupted(_ message: String, generation: Int) {
        guard let session, session.id == generation, !session.isTerminating else {
            Log.audio.debug("capture interruption for a finished utterance ignored")
            return
        }
        guard session.consumeTask != nil else {
            session.interruptionDuringSetup = message
            Log.audio.info("utterance \(session.id, privacy: .public) capture interrupted during setup; applying once setup finishes")
            return
        }
        Log.audio.error("utterance \(session.id, privacy: .public) capture interrupted: \(message, privacy: .public)")
        // End as a release so everything said before the interruption is still delivered.
        session.interruptionNotice = message
        terminate(session, reason: .released)
    }

    private func applyLevel(_ value: Float, generation: Int) {
        guard let session, session.id == generation, !session.isTerminating else {
            return
        }
        session.peakLevel = max(session.peakLevel, value)
        level += (value - level) * Self.levelSmoothing
    }

    // MARK: Terminal task

    /// The only path out of an utterance. The first terminal event wins; a failure after a
    /// release is logged and ignored.
    private func terminate(_ session: Session, reason requestedReason: TerminalReason) {
        guard session === self.session else {
            Log.app.debug("terminal event \(requestedReason.label, privacy: .public) for stale utterance \(session.id, privacy: .public) ignored")
            return
        }
        if session.isTerminating {
            if case .failed(let message) = requestedReason {
                Log.app.error(
                    "utterance \(session.id, privacy: .public) failure after terminal event ignored: \(message, privacy: .public)"
                )
            }
            return
        }
        session.setupTask?.cancel()
        session.watchdogTask?.cancel()
        let releasedInstant = clock.now
        session.releasedAt = releasedInstant
        session.releasedDate = Date()
        session.targetProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // A release held for less than `minimumHold` is a mis-tap, not dictation: cancel the
        // engine instead of finalizing it, so the utterance never enters `.finishing` and
        // recovery is instant. `minimumHold == .zero` never triggers this (a hold is never
        // negative), so tests that release immediately keep the finalize path.
        let reason: TerminalReason
        if requestedReason.isRelease, (releasedInstant - session.pressedAt) < minimumHold {
            reason = .tapped
            Log.app.info(
                "utterance \(session.id, privacy: .public) released after \(session.heldSeconds(now: releasedInstant), privacy: .public)s; treating as a tap, cancelling"
            )
        } else {
            reason = requestedReason
        }

        capture.stop()
        level = 0
        if reason.isRelease {
            state = .finishing
        }
        Log.app.info("utterance \(session.id, privacy: .public) terminal event: \(reason.label, privacy: .public)")
        session.terminalTask = track { [weak self] in
            await self?.runTerminal(session, reason: reason)
        }
    }

    private func runTerminal(_ session: Session, reason: TerminalReason) async {
        // 1. A suspended setup must not resume into a dead utterance.
        session.setupTask?.cancel()
        await session.setupTask?.value

        // 2. Close the audio path; on release the drain still delivers everything captured.
        capture.stop()
        session.audioContinuation?.finish()
        if !reason.isRelease {
            session.drainTask?.cancel()
        }
        await session.drainTask?.value

        // 3. Finish or cancel the engine; this is the only place either happens. On a
        // release, finish is bounded so a stalled finalize (a quick tap) cannot wedge the
        // utterance in `.finishing` forever.
        var finishTimedOut = false
        if let engine = session.engine {
            if reason.isRelease {
                let timeout = Self.finishTimeout(
                    base: engineFinishTimeout, heldSeconds: session.heldSeconds(now: clock.now)
                )
                finishTimedOut = await finishBounded(engine, timeout: timeout, utterance: session.id)
            } else {
                await engine.cancel()
            }
        }

        // 4. The consume task ends when the snapshot stream finishes.
        await session.consumeTask?.value

        // 5. Hand over the final text, unless it is only a hesitation sound: Parakeet turns
        // a silent hold into "Mm-.". Loudness cannot decide this; on a laptop mic in a normal
        // room, quiet one-word answers peak no higher than a silent hold's background noise.
        var endingError: String?
        if reason.isRelease {
            let raw = transcript
            Log.app.info(
                "utterance \(session.id, privacy: .public) audio: peak level \(session.peakLevel, format: .fixed(precision: 2), privacy: .public)"
            )
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.app.info("utterance \(session.id, privacy: .public) blank transcript; no callback")
                if finishTimedOut {
                    endingError = Self.transcriptionTimedOutMessage
                }
            } else if FillerOnly.matches(raw) {
                Log.app.info(
                    "utterance \(session.id, privacy: .public) transcript is only a filler sound; discarding \(raw.count, privacy: .public) chars"
                )
            } else {
                if finishTimedOut {
                    Log.app.error(
                        "utterance \(session.id, privacy: .public) delivering a partial transcript after the finish timeout"
                    )
                    endingError = Self.transcriptionIncompleteMessage
                }
                let utterance = Utterance(
                    source: session.source,
                    heldSeconds: session.heldSeconds(now: clock.now),
                    releasedAt: session.releasedDate ?? Date(),
                    targetProcessID: session.targetProcessID
                )
                Log.app.info(
                    "utterance \(session.id, privacy: .public) final transcript ready: \(raw.count, privacy: .public) chars, held \(utterance.heldSeconds, privacy: .public)s"
                )
                if let notice = await deliverBounded(raw, utterance, id: session.id), endingError == nil {
                    endingError = notice
                }
            }
        }

        if endingError == nil, let notice = session.interruptionNotice {
            endingError = notice
        }

        // 5b. Erase (§6.16), after any delivery and before idle, so the text just delivered
        // is what gets erased and nothing else owns the target meanwhile. A refusal drops the
        // restart: typing a replacement for text that was not removed would duplicate it.
        if session.eraseRequested, session === self.session {
            state = .erasing
            let outcome = await eraseBounded(id: session.id)
            if outcome != .erased {
                dropPendingPress(reason: "erase did not complete")
                endingError = outcome.message
            }
        }

        // 6. Back to idle (or error).
        guard session === self.session else {
            Log.app.error("utterance \(session.id, privacy: .public) was replaced before its terminal task finished")
            return
        }
        self.session = nil
        holdStartedAt = nil
        switch reason {
        case .released, .tapped, .aborted, .erased:
            if let endingError {
                state = .error(endingError)
                scheduleErrorReset(endingError, generation: session.id)
            } else {
                state = .idle
            }
        case .failed(let message):
            state = .error(message)
            scheduleErrorReset(message, generation: session.id)
        }
        // This terminal task is still counted until it returns, so the number after it
        // completes is one less.
        Log.app.info(
            "utterance \(session.id, privacy: .public) ended (\(reason.label, privacy: .public)); liveTaskCount after this task: \(self.liveTaskCount - 1, privacy: .public)"
        )
        if let pending = pendingPress {
            pendingPress = nil
            Log.app.info("starting the queued press")
            press(source: pending)
        }
    }

    private func scheduleErrorReset(_ message: String, generation: Int) {
        errorResetTask?.cancel()
        errorResetTask = Task { @MainActor [weak self, errorDisplayDuration] in
            do {
                try await Task.sleep(for: errorDisplayDuration)
            } catch {
                Log.app.debug("error display timer cancelled")
                return
            }
            guard let self, self.generation == generation, self.state == .error(message) else {
                return
            }
            self.state = .idle
        }
    }

    // MARK: Task bookkeeping

    /// Delivers the final transcript but never lets a hung pipeline or injection hold the
    /// controller in `.finishing` (the one state the Stop button cannot rescue). If delivery
    /// does not finish within `deliveryTimeout`, stop waiting and let the terminal task return
    /// to idle. The in-flight delivery is left running rather than cancelled: a mid-paste
    /// cancel could corrupt the injection or leave the pasteboard unrestored.
    /// Returns the delivery's message for the user, if it finished in time and had one.
    private func deliverBounded(_ raw: String, _ utterance: Utterance, id: Int) async -> String? {
        guard onFinalTranscript != nil else {
            return nil
        }
        let latch = RaceLatch()
        let notice = NoticeBox()
        Task { @MainActor in
            notice.value = await self.onFinalTranscript?(raw, utterance) ?? nil
            latch.resolve(true)
        }
        let timer = Task { @MainActor in
            do {
                try await Task.sleep(for: deliveryTimeout)
            } catch {
                Log.app.debug("delivery timer cancelled")
                return
            }
            latch.resolve(false)
        }
        if await latch.value() {
            timer.cancel()
            return notice.value
        }
        Log.app.error(
            "utterance \(id, privacy: .public) transcript delivery did not finish within \(self.deliveryTimeout, privacy: .public); leaving .finishing to avoid a wedge"
        )
        return nil
    }

    /// Runs the eraser but never lets it hold `.erasing`. On timeout the token is revoked
    /// (the eraser stops before its next side effect) and the erase counts as failed.
    private func eraseBounded(id: Int) async -> EraseOutcome {
        let token = EraseToken()
        eraseToken = token
        defer {
            if eraseToken === token {
                eraseToken = nil
            }
        }
        let latch = RaceLatch()
        let result = OutcomeBox()
        Task { @MainActor in
            result.value = await self.eraseLast(token)
            latch.resolve(true)
        }
        let timer = Task { @MainActor in
            do {
                try await Task.sleep(for: eraseTimeout)
            } catch {
                Log.app.debug("erase timer cancelled")
                return
            }
            latch.resolve(false)
        }
        if await latch.value() {
            timer.cancel()
            // Revoked by deactivate while it ran: whatever it managed, do not restart.
            return token.isRevoked ? .failed : result.value
        }
        token.revoke()
        Log.app.error(
            "utterance \(id, privacy: .public) erase did not finish within \(self.eraseTimeout, privacy: .public); revoked"
        )
        return .failed
    }

    /// Carries the erase outcome out of its unstructured task.
    @MainActor
    private final class OutcomeBox {
        var value: EraseOutcome = .failed
    }

    /// Awaits `engine.finish()` but never lets it hang the utterance. If finish does not
    /// return within `engineFinishTimeout`, cancel the engine (its abort path ends the
    /// analyzer and unblocks the stalled finalize) and stop waiting, so the terminal task
    /// proceeds and the controller leaves `.finishing`. The finish task then completes on
    /// its own once cancel unblocks it. Returns true when finish timed out and the engine
    /// was cancelled.
    private func finishBounded(_ engine: any TranscriptionEngine, timeout: Duration, utterance: Int) async -> Bool {
        let latch = RaceLatch()
        let finish = Task { @MainActor in
            await engine.finish()
            latch.resolve(true)
        }
        let timer = Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                Log.app.debug("engine finish timer cancelled")
                return
            }
            latch.resolve(false)
        }
        if await latch.value() {
            timer.cancel()
            return false
        }
        Log.app.error(
            "utterance \(utterance, privacy: .public) engine finish timed out after \(timeout, privacy: .public); cancelling to unblock"
        )
        await engine.cancel()
        finish.cancel()
        return true
    }

    /// The finish cap for a hold of `heldSeconds`: `base`, plus time for audio the engine
    /// may not have decoded yet, never more than `finishTimeoutCap`.
    static func finishTimeout(base: Duration, heldSeconds: TimeInterval) -> Duration {
        let grown = base + .milliseconds(Int(heldSeconds * finishTimeoutPerHeldSecond * 1_000))
        return min(max(grown, base), max(base, finishTimeoutCap))
    }

    /// Carries the delivery's message out of its unstructured task.
    @MainActor
    private final class NoticeBox {
        var value: String?
    }

    /// A one-shot latch: the first `resolve` wins and wakes the single waiter; later resolves
    /// are dropped. Main-actor isolated, so it needs no lock. Used to race `engine.finish()`
    /// against a timeout without a structured task group (which would wait for the stalled
    /// finish child).
    @MainActor
    private final class RaceLatch {
        private var result: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        func resolve(_ value: Bool) {
            guard result == nil else { return }
            result = value
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: value)
            }
        }

        func value() async -> Bool {
            if let result {
                return result
            }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    private func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        liveTaskCount += 1
        return Task { @MainActor [weak self] in
            await body()
            self?.liveTaskCount -= 1
        }
    }

    private func trackDetached(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        liveTaskCount += 1
        return Task.detached(priority: .userInitiated) { [weak self] in
            await body()
            await self?.detachedTaskCompleted()
        }
    }

    private func detachedTaskCompleted() {
        liveTaskCount -= 1
    }

    private func playStartSound() {
        guard let sound = NSSound(named: NSSound.Name(Self.startSoundName)) else {
            Log.app.error("start sound \(Self.startSoundName, privacy: .public) not found")
            return
        }
        if !sound.play() {
            Log.app.error("start sound \(Self.startSoundName, privacy: .public) did not play")
        }
    }
}
