import AVFoundation
import Foundation

/// One captured audio buffer on its way to the engine. The buffer is a private copy made by
/// capture (invariant 3), owned by exactly one chunk, and never touched again by the audio
/// thread, which is what makes handing it across threads sound.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// The full transcript so far. Consumers replace their text with `text`; they never append.
struct TranscriptSnapshot: Sendable {
    let text: String
    /// True means no further snapshots will follow for this session.
    let isFinal: Bool
}

/// The engine seam. One implementation ships (`AppleSpeechEngine`); the seam exists so the
/// controller is testable and a second engine can land later.
protocol TranscriptionEngine: Actor {
    /// The sample format capture must deliver. Apple's analyzer terminates the process on a
    /// format mismatch instead of throwing, so this is not advisory.
    func preferredInputFormat() async -> AVAudioFormat?
    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error>
    func feed(_ chunk: AudioChunk) async
    /// Close input, wait for every result already published, emit the final snapshot,
    /// finish the stream. Idempotent.
    func finish() async
    /// Abort now: close input, discard pending results, finish the stream (throwing
    /// CancellationError if it has not finished), release everything. Idempotent, and safe
    /// to call at any point including before or during start().
    func cancel() async
}

enum TranscriptionError: LocalizedError {
    case localeUnsupported(Locale)
    case modelInstallFailed(String)
    case noAudioFormat
    case notRunning

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale):
            "Speech recognition is not available for \(locale.identifier)."
        case .modelInstallFailed(let detail):
            "The speech model could not be installed: \(detail)"
        case .noAudioFormat:
            "The speech engine did not report an audio format."
        case .notRunning:
            "The speech engine is not running."
        }
    }
}
