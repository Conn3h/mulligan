import Foundation
import Testing
@testable import Sotto

/// `Settings` against a throwaway `UserDefaults` suite, so nothing here touches the
/// user's real preferences.
@MainActor
struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "com.conn3h.sotto.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func speechEngineDefaultsToApple() {
        let settings = Settings(defaults: makeDefaults())
        #expect(settings.speechEngine == .apple)
    }

    @Test func speechEnginePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        first.speechEngine = .parakeet
        let second = Settings(defaults: defaults)
        #expect(second.speechEngine == .parakeet)
    }

    @Test func unknownStoredEngineFallsBackToApple() {
        let defaults = makeDefaults()
        defaults.set("whisper", forKey: "speechEngine")
        let settings = Settings(defaults: defaults)
        #expect(settings.speechEngine == .apple)
    }

    @Test func engineChoiceNamesAreDistinct() {
        let names = Set(SpeechEngineChoice.allCases.map(\.engineName))
        #expect(names.count == SpeechEngineChoice.allCases.count)
        #expect(SpeechEngineChoice.apple.engineName == "Apple")
        #expect(SpeechEngineChoice.parakeet.engineName == "Parakeet")
    }
    @Test func erasePairDefaultsToRightOptionAndRightCommand() {
        let settings = Settings(defaults: makeDefaults())
        #expect(settings.pushToTalkKey == .rightOption)
        #expect(settings.eraseKey == .rightCommand)
    }

    @Test func switchingPushToTalkOntoTheEraseKeyMovesTheEraseKey() {
        let settings = Settings(defaults: makeDefaults())
        settings.pushToTalkKey = .rightCommand
        #expect(settings.eraseKey == .rightOption)
        // Back to Right Option: the erase key (now Right Option) conflicts again and moves back.
        settings.pushToTalkKey = .rightOption
        #expect(settings.eraseKey == .rightCommand)
    }

    @Test func fnKeepsTheEraseKey() {
        let settings = Settings(defaults: makeDefaults())
        settings.eraseKey = .off
        settings.pushToTalkKey = .fn
        #expect(settings.eraseKey == .off)
    }

    @Test func eraseKeyPersistsAcrossInstances() {
        let defaults = makeDefaults()
        Settings(defaults: defaults).eraseKey = .off
        #expect(Settings(defaults: defaults).eraseKey == .off)
    }

    @Test func aConflictingStoredPairIsRepairedAndPersistedOnLoad() {
        let defaults = makeDefaults()
        defaults.set("rightCommand", forKey: "pushToTalkKey")
        defaults.set("rightCommand", forKey: "eraseKey")
        let settings = Settings(defaults: defaults)
        #expect(settings.eraseKey == .rightOption)
        #expect(defaults.string(forKey: "eraseKey") == "rightOption")
    }
}
