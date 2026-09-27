import Foundation

/// Which recogniser a press uses. Read per press by the composition root so a change in
/// Settings applies to the very next hold.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    /// The label in Settings.
    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        }
    }

    /// The name recorded on every `DictationRun`, so History shows which engine produced
    /// a transcript.
    var engineName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        }
    }
}
