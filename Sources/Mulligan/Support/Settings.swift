import Foundation
import Observation

/// User preferences, backed by `UserDefaults`. Every setter persists immediately, and
/// consumers read the values per utterance so a change applies to the very next hold.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let smartCleanup = "smartCleanup"
        static let soundEnabled = "soundEnabled"
        static let speechEngine = "speechEngine"
        static let eraseKey = "eraseKey"
        static let redoHintsRemaining = "redoHintsRemaining"
        static let hasSeenWelcome = "hasSeenWelcome"
    }

    /// How many holds show the HUD's redo hint before it stops (spec §6.14).
    static let redoHintBudget = 10

    @ObservationIgnored private let defaults: UserDefaults

    var pushToTalkKey: PushToTalkKey {
        didSet {
            defaults.set(pushToTalkKey.rawValue, forKey: Key.pushToTalkKey)
            // The erase key is never the push-to-talk key (§6.16).
            if eraseKey.conflicts(with: pushToTalkKey) {
                eraseKey = EraseKey.alternative(to: pushToTalkKey)
            }
        }
    }

    var eraseKey: EraseKey {
        didSet { defaults.set(eraseKey.rawValue, forKey: Key.eraseKey) }
    }

    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Key.smartCleanup) }
    }

    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) }
    }

    var speechEngine: SpeechEngineChoice {
        didSet { defaults.set(speechEngine.rawValue, forKey: Key.speechEngine) }
    }

    /// Holds left that may show the redo hint; zero once the user has erased once.
    var redoHintsRemaining: Int {
        didSet { defaults.set(redoHintsRemaining, forKey: Key.redoHintsRemaining) }
    }

    /// Set when the first-run welcome is dismissed.
    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedKey = defaults.string(forKey: Key.pushToTalkKey)
            .flatMap(PushToTalkKey.init(rawValue:)) ?? .rightOption
        pushToTalkKey = storedKey
        // Property observers do not run in an initialiser, so a conflicting stored pair is
        // repaired (and persisted) here rather than by `pushToTalkKey`'s didSet.
        let storedErase = defaults.string(forKey: Key.eraseKey)
            .flatMap(EraseKey.init(rawValue:)) ?? .rightCommand
        let erase = storedErase.conflicts(with: storedKey) ? EraseKey.alternative(to: storedKey) : storedErase
        eraseKey = erase
        if erase != storedErase {
            defaults.set(erase.rawValue, forKey: Key.eraseKey)
        }
        cleanupEnabled = Self.bool(forKey: Key.cleanupEnabled, in: defaults, default: true)
        smartCleanup = Self.bool(forKey: Key.smartCleanup, in: defaults, default: false)
        soundEnabled = Self.bool(forKey: Key.soundEnabled, in: defaults, default: true)
        speechEngine = defaults.string(forKey: Key.speechEngine)
            .flatMap(SpeechEngineChoice.init(rawValue:)) ?? .apple
        redoHintsRemaining = defaults.object(forKey: Key.redoHintsRemaining) == nil
            ? Self.redoHintBudget
            : defaults.integer(forKey: Key.redoHintsRemaining)
        hasSeenWelcome = Self.bool(forKey: Key.hasSeenWelcome, in: defaults, default: false)
    }

    /// `UserDefaults.bool(forKey:)` returns false for a missing key, which would silently
    /// flip every default-true setting off, so presence is checked first.
    private static func bool(forKey key: String, in defaults: UserDefaults, default fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return fallback
        }
        return defaults.bool(forKey: key)
    }
}
