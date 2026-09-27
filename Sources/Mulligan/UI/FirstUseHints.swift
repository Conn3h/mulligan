import Foundation

/// The HUD's one-line lesson in the redo gesture (spec §6.14). It shows while the key is held
/// and nothing has been heard yet, which is exactly when the erase key works, and only while
/// there is a dictation to erase. `Settings.redoHintsRemaining` counts it down per hold and
/// drops to zero once the user has erased once.
enum RedoHint {
    static func shows(
        state: DictationController.State,
        transcript: String,
        hasErasable: Bool,
        remaining: Int,
        eraseKey: EraseKey
    ) -> Bool {
        guard state == .listening, transcript.isEmpty, hasErasable, remaining > 0 else {
            return false
        }
        return eraseKey != .off
    }

    static func text(erase: EraseKey) -> String {
        "Tap \(erase.displayName) to redo the last one"
    }
}

/// The first-run welcome in the main window (spec §6.14): once, and never to someone who has
/// already dictated (an existing install updating to this version).
enum WelcomeGate {
    static func shows(hasSeenWelcome: Bool, historyCount: Int) -> Bool {
        !hasSeenWelcome && historyCount == 0
    }
}
