import Testing
@testable import Mulligan

/// When the HUD teaches the redo gesture, and when the main window opens on the welcome.
@Suite
struct FirstUseHintsTests {
    @Test func redoHintShowsWhileListeningBeforeAnyWords() {
        #expect(RedoHint.shows(state: .listening, transcript: "", hasErasable: true, remaining: 3, eraseKey: .rightCommand))
    }

    @Test func redoHintGivesWayToTheTranscript() {
        #expect(!RedoHint.shows(state: .listening, transcript: "Hello", hasErasable: true, remaining: 3, eraseKey: .rightCommand))
    }

    @Test func redoHintNeedsSomethingToErase() {
        #expect(!RedoHint.shows(state: .listening, transcript: "", hasErasable: false, remaining: 3, eraseKey: .rightCommand))
    }

    @Test func redoHintStopsWhenUsedUpOrOff() {
        #expect(!RedoHint.shows(state: .listening, transcript: "", hasErasable: true, remaining: 0, eraseKey: .rightCommand))
        #expect(!RedoHint.shows(state: .listening, transcript: "", hasErasable: true, remaining: 3, eraseKey: .off))
    }

    @Test func redoHintOnlyWhileListening() {
        for state: DictationController.State in [.starting, .finishing, .erasing, .idle, .error("x")] {
            #expect(!RedoHint.shows(state: state, transcript: "", hasErasable: true, remaining: 3, eraseKey: .rightCommand))
        }
    }

    @Test func redoHintNamesTheEraseKey() {
        #expect(RedoHint.text(erase: .rightCommand) == "Tap Right ⌘ to redo the last one")
    }

    @Test func welcomeShowsOnceAndNeverToExistingUsers() {
        #expect(WelcomeGate.shows(hasSeenWelcome: false, historyCount: 0))
        #expect(!WelcomeGate.shows(hasSeenWelcome: true, historyCount: 0))
        #expect(!WelcomeGate.shows(hasSeenWelcome: false, historyCount: 12))
    }
}
