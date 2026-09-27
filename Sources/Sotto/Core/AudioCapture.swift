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
    case converterUnavailable(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No microphone is available."
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
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void

        func process(_ buffer: AVAudioPCMBuffer) {
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

    /// What a running capture needs to rebuild itself on a new input device.
    private struct Running {
        /// Identifies this start. A queued notification for an earlier engine must not match
        /// a new one, which can be allocated at the same address.
        let token: UUID
        let engine: AVAudioEngine
        let outputFormat: AVAudioFormat
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void
        let onInterruption: @Sendable (String) -> Void
        let observer: NSObjectProtocol
    }

    private struct Storage {
        var running: Running?
    }

    static let microphoneChangedMessage = "The microphone changed and could not be restarted. Try again."

    private let storage = Mutex(Storage())
    /// Configuration-change notifications are delivered here, asynchronously, so a change
    /// posted while `start` or a restart holds the lock can never deadlock on it.
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
    /// until relaunch. A new engine costs a few milliseconds (logged).
    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterruption: @escaping @Sendable (String) -> Void
    ) throws {
        try storage.withLock { storage in
            if storage.running != nil {
                Log.audio.info("capture start ignored: already running")
                return
            }
            let clock = ContinuousClock()
            let started = clock.now
            let engine = AVAudioEngine()
            let native = try Self.installTap(
                on: engine, outputFormat: outputFormat, onBuffer: onBuffer, onLevel: onLevel
            )
            // The engine stops itself when its I/O configuration changes (a device connects
            // or disconnects, a Bluetooth headset switches profile). Without this the tap
            // went silent while the utterance kept "listening". Registered before the start
            // so a change during it is not missed; handled only once `running` is set,
            // because delivery waits for this lock.
            let token = UUID()
            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: notificationQueue
            ) { [weak self] _ in
                self?.handleConfigurationChange(of: token)
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                NotificationCenter.default.removeObserver(observer)
                engine.inputNode.removeTap(onBus: 0)
                Log.audio.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            storage.running = Running(
                token: token,
                engine: engine,
                outputFormat: outputFormat,
                onBuffer: onBuffer,
                onLevel: onLevel,
                onInterruption: onInterruption,
                observer: observer
            )
            Log.audio.info(
                "capture start: native \(native.sampleRate, privacy: .public) Hz x\(native.channelCount, privacy: .public) -> engine \(outputFormat.sampleRate, privacy: .public) Hz x\(outputFormat.channelCount, privacy: .public), converting: \(native != outputFormat, privacy: .public), took \(clock.now - started, privacy: .public)"
            )
        }
    }

    func stop() {
        storage.withLock { storage in
            guard let running = storage.running else {
                return
            }
            NotificationCenter.default.removeObserver(running.observer)
            running.engine.inputNode.removeTap(onBus: 0)
            running.engine.stop()
            storage.running = nil
            Log.audio.info("capture stop")
        }
    }

    /// Re-installs the tap for the new input format and restarts the engine, so a device
    /// change mid-hold costs a moment of audio rather than the rest of the utterance. If that
    /// fails, the utterance is told, so it ends with an error instead of listening to silence.
    ///
    /// The restart runs under the lock on purpose: `stop()` may arrive from the main actor at
    /// the same moment, and `AVAudioEngine` must not be stopped and restarted concurrently.
    /// A release during a device change can wait for the restart; that is rare and brief.
    private func handleConfigurationChange(of token: UUID) {
        let notify: (@Sendable (String) -> Void)? = storage.withLock { storage in
            guard let running = storage.running, running.token == token else {
                Log.audio.debug("audio configuration change for a stopped capture ignored")
                return nil
            }
            let engine = running.engine
            Log.audio.info("audio configuration changed during capture; restarting on the current input")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            do {
                let native = try Self.installTap(
                    on: engine, outputFormat: running.outputFormat,
                    onBuffer: running.onBuffer, onLevel: running.onLevel
                )
                engine.prepare()
                try engine.start()
                Log.audio.info(
                    "capture restarted: native \(native.sampleRate, privacy: .public) Hz x\(native.channelCount, privacy: .public)"
                )
                return nil
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                NotificationCenter.default.removeObserver(running.observer)
                storage.running = nil
                Log.audio.error(
                    "capture restart after a configuration change failed: \(error.localizedDescription, privacy: .public)"
                )
                return running.onInterruption
            }
        }
        notify?(Self.microphoneChangedMessage)
    }

    /// Installs the tap in the input node's current native format, converting to
    /// `outputFormat` when they differ. Returns the native format.
    private static func installTap(
        on engine: AVAudioEngine,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws -> AVAudioFormat {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            Log.audio.error("capture start failed: input node reports no usable format")
            throw AudioCaptureError.noInputDevice
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
            converter: converter, outputFormat: outputFormat, onBuffer: onBuffer, onLevel: onLevel
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
