import Accelerate
import AVFoundation
import Foundation
import Synchronization

/// Microphone capture. Buffers are delivered in the engine's preferred format, copied so
/// they can safely leave the audio thread, alongside a 0...1 meter level.
protocol AudioCapturing: AnyObject, Sendable {
    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterruption: @escaping @Sendable (String) -> Void
    ) throws
    func stop()
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case inputNotReady
    case converterUnavailable(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No microphone is available."
        case .inputNotReady:
            "The microphone is still switching. Try again."
        case .converterUnavailable(let from, let to):
            "Audio cannot be converted from \(from) to \(to)."
        }
    }
}

/// `AVAudioEngine` input tap in the node's native format, converted to the engine's format
/// when they differ. Nothing mutable is shared with the audio thread: `start()` builds one
/// immutable `Session` that the tap closure captures, and the class itself only holds the
/// running engine and its callbacks behind a lock.
final class AudioCapture: AudioCapturing {
    private static let tapFrameCount: AVAudioFrameCount = 2048
    /// Extra output frames beyond frames x rate ratio, so a resampler's rounding never
    /// truncates a buffer.
    private static let conversionHeadroomFrames: AVAudioFrameCount = 64

    /// Everything the tap closure needs, fixed at `start()`. The converter is a reference
    /// type, but after `start()` returns only the audio thread touches it.
    private struct Session {
        let converter: AVAudioConverter?
        let outputFormat: AVAudioFormat
        let clock: BufferClock
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void

        func process(_ buffer: AVAudioPCMBuffer) {
            clock.mark()
            onLevel(AudioCapture.meterLevel(of: buffer))
            let delivered: AVAudioPCMBuffer?
            if let converter {
                delivered = AudioCapture.convert(buffer, with: converter, to: outputFormat)
            } else {
                delivered = AudioCapture.deepCopy(buffer)
            }
            guard let delivered, delivered.frameLength > 0 else {
                return
            }
            onBuffer(AudioChunk(buffer: delivered))
        }
    }

    /// What a capture was started with; fixed for its whole life, across restarts.
    private struct Configuration {
        let outputFormat: AVAudioFormat
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void
        let onInterruption: @Sendable (String) -> Void
    }

    /// One started engine. Built inside the lock (an engine may only enter the lock's region
    /// as a fresh value, and SPEC allows no unchecked Sendable here), but retries wait outside
    /// it, so a `stop()` waits for at most one engine build.
    private struct LiveEngine {
        let engine: AVAudioEngine
        let observer: NSObjectProtocol
        let clock: BufferClock
        let native: AVAudioFormat
        let id: UUID
        let startedAt: UInt64
    }

    private struct Running {
        let configuration: Configuration
        /// Nil while a restart is between engines.
        var live: LiveEngine?
        /// The engine a configuration change or silence check may act on: the live engine's
        /// id, or a restart's ticket while it is between engines. A queued notification for a
        /// torn-down engine (or a new one at a reused address) never matches.
        var currentID: UUID
        /// Restarts forced by the silence check; bounded so a dead input ends the utterance
        /// instead of restarting forever.
        var silenceRestarts = 0
    }

    /// What the log needs from a newly started engine, readable outside the lock.
    private struct StartedEngine: Sendable {
        let id: UUID
        let nativeRate: Double
        let nativeChannels: UInt32
        let converting: Bool

        init(_ live: LiveEngine, outputFormat: AVAudioFormat) {
            id = live.id
            nativeRate = live.native.sampleRate
            nativeChannels = live.native.channelCount
            converting = live.native != outputFormat
        }
    }

    private enum SilenceVerdict {
        case healthy
        case restart(silentMillis: UInt64)
        case giveUp(@Sendable (String) -> Void)
        case gone
    }

    private struct Storage {
        var running: Running?
    }

    static let microphoneChangedMessage = "The microphone changed and could not be restarted. Try again."
    /// A device that is still switching (Bluetooth turning off, a headset just connected) can
    /// report a format the hardware does not have yet, or refuse to start. Starts and restarts
    /// retry on a fresh engine before giving up.
    private static let engineAttempts = 4
    private static let engineRetryDelay: TimeInterval = 0.15
    /// An engine can start "successfully" on a device mid-switch and never deliver a buffer,
    /// with no configuration change to say so. Buffers flow even in silence, so none for this
    /// long means capture is dead and is moved to a fresh engine.
    private static let firstBufferDeadline: UInt64 = 700_000_000
    private static let bufferGapDeadline: UInt64 = 1_000_000_000
    private static let silenceCheckInterval: TimeInterval = 0.35
    private static let maxSilenceRestarts = 3

    private let storage = Mutex(Storage())
    /// Configuration changes and silence checks are handled here. The observer itself runs
    /// on the posting thread (queue nil) and only enqueues: an observer registered with a
    /// queue makes the poster wait for it, and the handler takes the lock that `start` holds
    /// while the engine may be posting, which could deadlock.
    private let notificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.conn3h.sotto.audio-configuration"
        return queue
    }()

    init() {}

    /// Builds a fresh `AVAudioEngine` for every start. A cached engine kept the input device
    /// and format it first saw: after AirPods connected or the input changed between holds it
    /// could hand the tap a stale format, and one failed start poisoned every later press
    /// until relaunch. A start that fails because the input is mid-switch is retried.
    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterruption: @escaping @Sendable (String) -> Void
    ) throws {
        if storage.withLock({ $0.running != nil }) {
            Log.audio.info("capture start ignored: already running")
            return
        }
        let configuration = Configuration(
            outputFormat: outputFormat, onBuffer: onBuffer, onLevel: onLevel, onInterruption: onInterruption
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        var lastError: Error = AudioCaptureError.inputNotReady
        for attempt in 1...Self.engineAttempts {
            if attempt > 1 {
                Thread.sleep(forTimeInterval: Self.engineRetryDelay)
            }
            let result: Result<StartedEngine, Error>? = storage.withLock { storage in
                guard storage.running == nil else {
                    return nil
                }
                do {
                    let live = try makeEngine(for: configuration)
                    storage.running = Running(configuration: configuration, live: live, currentID: live.id)
                    return .success(StartedEngine(live, outputFormat: outputFormat))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case nil:
                Log.audio.info("capture start ignored: already running")
                return
            case .success(let started):
                scheduleSilenceCheck(for: started.id)
                Log.audio.info(
                    "capture start: native \(started.nativeRate, privacy: .public) Hz x\(started.nativeChannels, privacy: .public) -> engine \(outputFormat.sampleRate, privacy: .public) Hz x\(outputFormat.channelCount, privacy: .public), converting: \(started.converting, privacy: .public), attempt \(attempt, privacy: .public), took \(clock.now - startedAt, privacy: .public)"
                )
                return
            case .failure(let error):
                lastError = error
                Log.audio.error(
                    "capture start attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                guard Self.isTransient(error) else {
                    throw error
                }
            }
        }
        // Whatever CoreAudio said, the user can only wait and try again.
        throw Self.isTransient(lastError) ? AudioCaptureError.inputNotReady : lastError
    }

    func stop() {
        storage.withLock { storage in
            guard let running = storage.running else {
                return
            }
            if let live = running.live {
                Self.tearDown(live)
            }
            storage.running = nil
            Log.audio.info("capture stop")
        }
    }

    /// Starts a new engine for `configuration`: tap, configuration observer, start. Touches no
    /// shared state; on failure nothing is left behind.
    private func makeEngine(for configuration: Configuration) throws -> LiveEngine {
        let engine = AVAudioEngine()
        let clock = BufferClock()
        let native = try Self.installTap(on: engine, configuration: configuration, clock: clock)
        // The engine stops itself when its I/O configuration changes (a device connects or
        // disconnects, a Bluetooth headset switches profile). Without this the tap went
        // silent while the utterance kept "listening".
        let id = UUID()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, notificationQueue] _ in
            notificationQueue.addOperation {
                self?.handleConfigurationChange(of: id, reason: "configuration changed")
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        return LiveEngine(
            engine: engine, observer: observer, clock: clock, native: native, id: id,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
    }

    private static func tearDown(_ live: LiveEngine) {
        NotificationCenter.default.removeObserver(live.observer)
        live.engine.inputNode.removeTap(onBus: 0)
        live.engine.stop()
    }

    /// Errors a device mid-switch produces: worth a retry on a fresh engine. Our own errors
    /// other than `inputNotReady` (no microphone, no converter) will not change on a retry;
    /// CoreAudio's (-10868, 560227702 "cannot perform IO") come from a device in transition.
    private static func isTransient(_ error: Error) -> Bool {
        if let captureError = error as? AudioCaptureError {
            if case .inputNotReady = captureError {
                return true
            }
            return false
        }
        return (error as NSError).domain != NSCocoaErrorDomain
    }

    /// Moves capture to a fresh engine on the current input, so a device change mid-hold
    /// costs a moment of audio rather than the rest of the utterance. The old engine is not
    /// reused: after Bluetooth turned off it still reported the headset's format, and
    /// installing a tap in that format raised an exception Swift cannot catch. A device that
    /// is still switching is retried; if it never settles the utterance is told, so it ends
    /// (delivering what was said) instead of listening to silence.
    ///
    /// Each attempt builds its engine under the lock, but the delay between attempts is
    /// spent outside it, so a release during a restart waits for at most one engine build.
    private func handleConfigurationChange(of engineID: UUID, reason: String) {
        let ticket: UUID? = storage.withLock { storage in
            guard var running = storage.running, running.currentID == engineID else {
                Log.audio.debug("audio \(reason, privacy: .public) for a replaced or stopped engine ignored")
                return nil
            }
            Log.audio.info("audio \(reason, privacy: .public) during capture; moving to a fresh engine")
            if let old = running.live {
                Self.tearDown(old)
            }
            let ticket = UUID()
            running.live = nil
            running.currentID = ticket
            storage.running = running
            return ticket
        }
        guard let ticket else {
            return
        }
        for attempt in 1...Self.engineAttempts {
            if attempt > 1 {
                Thread.sleep(forTimeInterval: Self.engineRetryDelay)
            }
            let result: Result<StartedEngine, Error>? = storage.withLock { storage in
                guard var running = storage.running, running.currentID == ticket else {
                    return nil
                }
                do {
                    let live = try makeEngine(for: running.configuration)
                    running.live = live
                    running.currentID = live.id
                    storage.running = running
                    return .success(StartedEngine(live, outputFormat: running.configuration.outputFormat))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case nil:
                Log.audio.info("capture restart abandoned: capture stopped meanwhile")
                return
            case .success(let started):
                Log.audio.info(
                    "capture restarted on attempt \(attempt, privacy: .public): native \(started.nativeRate, privacy: .public) Hz x\(started.nativeChannels, privacy: .public)"
                )
                scheduleSilenceCheck(for: started.id)
                return
            case .failure(let error):
                Log.audio.error(
                    "capture restart attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        giveUp(ticket: ticket, after: "\(Self.engineAttempts) restart attempts")
    }

    private func giveUp(ticket: UUID, after what: String) {
        let notify: (@Sendable (String) -> Void)? = storage.withLock { storage in
            guard let running = storage.running, running.currentID == ticket else {
                return nil
            }
            storage.running = nil
            return running.configuration.onInterruption
        }
        guard let notify else {
            return
        }
        Log.audio.error("capture could not recover after \(what, privacy: .public); ending the utterance")
        notify(Self.microphoneChangedMessage)
    }

    // MARK: Silence check

    private func scheduleSilenceCheck(for engineID: UUID) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.silenceCheckInterval) {
            [weak self, notificationQueue] in
            notificationQueue.addOperation {
                self?.checkForSilence(of: engineID)
            }
        }
    }

    /// Restarts an engine that stopped delivering buffers without saying so. Runs on the
    /// notification queue, so it never overlaps a configuration-change restart.
    private func checkForSilence(of engineID: UUID) {
        let verdict: SilenceVerdict = storage.withLock { storage in
            guard var running = storage.running, running.currentID == engineID, let live = running.live else {
                return .gone
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let last = live.clock.lastBuffer
            let silent = now - max(last, live.startedAt)
            let deadline = last == 0 ? Self.firstBufferDeadline : Self.bufferGapDeadline
            guard silent > deadline else {
                return .healthy
            }
            running.silenceRestarts += 1
            storage.running = running
            if running.silenceRestarts > Self.maxSilenceRestarts {
                storage.running = nil
                return .giveUp(running.configuration.onInterruption)
            }
            return .restart(silentMillis: silent / 1_000_000)
        }
        switch verdict {
        case .gone:
            return
        case .healthy:
            scheduleSilenceCheck(for: engineID)
        case .restart(let silentMillis):
            handleConfigurationChange(of: engineID, reason: "delivered no audio for \(silentMillis) ms")
        case .giveUp(let notify):
            Log.audio.error("capture delivered no audio after \(Self.maxSilenceRestarts, privacy: .public) restarts; ending the utterance")
            notify(Self.microphoneChangedMessage)
        }
    }

    /// Installs the tap in the input node's current native format, converting to the
    /// configured output format when they differ. Returns the native format.
    private static func installTap(
        on engine: AVAudioEngine,
        configuration: Configuration,
        clock: BufferClock
    ) throws -> AVAudioFormat {
        let outputFormat = configuration.outputFormat
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            Log.audio.error("capture start failed: input node reports no usable format")
            throw AudioCaptureError.noInputDevice
        }
        // installTap raises an Objective-C exception, which Swift cannot catch and which
        // aborts the app, when the tap format's rate differs from the hardware's. That is
        // the state of a device mid-switch; report it as an error instead.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate == native.sampleRate else {
            Log.audio.error(
                "capture start failed: input still switching (hardware \(hardware.sampleRate, privacy: .public) Hz, node \(native.sampleRate, privacy: .public) Hz)"
            )
            throw AudioCaptureError.inputNotReady
        }
        var converter: AVAudioConverter?
        if native != outputFormat {
            guard let made = AVAudioConverter(from: native, to: outputFormat) else {
                Log.audio.error(
                    "capture start failed: no converter from \(native.description, privacy: .public) to \(outputFormat.description, privacy: .public)"
                )
                throw AudioCaptureError.converterUnavailable(
                    from: native.description, to: outputFormat.description
                )
            }
            converter = made
        }
        if native.commonFormat != .pcmFormatFloat32 {
            Log.audio.error(
                "native input format is not Float32 (\(native.commonFormat.rawValue, privacy: .public)); the level meter will stay at zero"
            )
        }
        let session = Session(
            converter: converter, outputFormat: outputFormat, clock: clock,
            onBuffer: configuration.onBuffer, onLevel: configuration.onLevel
        )
        input.installTap(onBus: 0, bufferSize: tapFrameCount, format: native) { buffer, _ in
            session.process(buffer)
        }
        return native
    }

    // MARK: Buffer handling (audio thread)

    /// The engine reuses the buffer it hands a tap the moment the callback returns, so a
    /// buffer that leaves the audio thread must be a private copy.
    private static func deepCopy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format, frameCapacity: max(source.frameLength, 1)
        ) else {
            Log.audio.error("buffer copy failed: allocation for \(source.frameLength, privacy: .public) frames")
            return nil
        }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let copyList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(sourceList, copyList) {
            guard let fromData = from.mData, let toData = to.mData else {
                continue
            }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Converts one native buffer into a freshly allocated buffer in the engine's format.
    /// The converter pulls input through a block that hands the buffer over exactly once
    /// and then reports that no more data is available for this call.
    private static func convert(
        _ source: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        let scaled = (Double(source.frameLength) * ratio).rounded(.up)
        let capacity = AVAudioFrameCount(scaled) + conversionHeadroomFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            Log.audio.error("conversion failed: allocation for \(capacity, privacy: .public) frames")
            return nil
        }
        let input = AudioChunk(buffer: source)
        let handoff = SingleHandoff()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if handoff.take() {
                outStatus.pointee = .haveData
                return input.buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output
        case .error:
            Log.audio.error(
                "conversion failed: \(conversionError?.localizedDescription ?? "unknown error", privacy: .public)"
            )
            return nil
        @unknown default:
            Log.audio.error("conversion returned unknown status \(status.rawValue, privacy: .public)")
            return nil
        }
    }

    /// RMS of the buffer mapped from roughly -50...0 dBFS onto 0...1, so quiet speech still
    /// moves the meter. Non-float buffers read as silence (logged once at start).
    private static func meterLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }
        let frames = Int(buffer.frameLength)
        let sampleCount = buffer.format.isInterleaved ? frames * Int(buffer.format.channelCount) : frames
        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(sampleCount))
        return meterLevel(rms: rms)
    }

    private static let meterFloorDecibels: Float = -50

    static func meterLevel(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else {
            return 0
        }
        let decibels = 20 * log10(rms)
        let normalized = (decibels - meterFloorDecibels) / -meterFloorDecibels
        return min(max(normalized, 0), 1)
    }
}

/// A one-shot flag for the converter's pull-style input block, which must be `@Sendable`
/// and so cannot capture a local `var`.
private final class SingleHandoff: Sendable {
    private let taken = Mutex(false)

    func take() -> Bool {
        taken.withLock { taken in
            if taken {
                return false
            }
            taken = true
            return true
        }
    }
}

/// When the tap last delivered a buffer, written by the audio thread and read by the silence
/// check. Zero until the first buffer.
private final class BufferClock: Sendable {
    private let last = Atomic<UInt64>(0)

    func mark() {
        last.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
    }

    var lastBuffer: UInt64 {
        last.load(ordering: .relaxed)
    }
}
