import Testing
@testable import MulliganDictionary

@Suite("DictionaryWarning.check")
struct DictionaryWarningTests {
    @Test func termsNeverWarn() {
        let warnings = DictionaryWarning.check(.term("cc"))
        #expect(warnings.isEmpty)
    }

    @Test func shortTriggerWithoutSpaceOrHyphenWarns() {
        let entry = DictionaryEntry.correction(hear: "abcd", write: "something else")
        let warnings = DictionaryWarning.check(entry)
        #expect(
            warnings.map(\.message) == [
                "\u{201C}abcd\u{201D} is very short and will match often. Consider a longer phrase."
            ]
        )
    }

    @Test func fourCharactersIsTheWarningBoundary() {
        let fourChars = DictionaryWarning.check(.correction(hear: "abcd", write: "other"))
        #expect(fourChars.contains { $0.message.contains("is very short") })

        let fiveChars = DictionaryWarning.check(.correction(hear: "abcde", write: "other"))
        #expect(!fiveChars.contains { $0.message.contains("is very short") })
    }

    @Test func shortTriggerWithASpaceDoesNotWarn() {
        let entry = DictionaryEntry.correction(hear: "a b", write: "other")
        let warnings = DictionaryWarning.check(entry)
        #expect(!warnings.contains { $0.message.contains("is very short") })
    }

    @Test func shortTriggerWithAHyphenDoesNotWarn() {
        let entry = DictionaryEntry.correction(hear: "a-b", write: "other")
        let warnings = DictionaryWarning.check(entry)
        #expect(!warnings.contains { $0.message.contains("is very short") })
    }

    @Test func selfRewriteWarnsCaseInsensitively() {
        let entry = DictionaryEntry.correction(hear: "hello", write: "Hello")
        let warnings = DictionaryWarning.check(entry)
        #expect(
            warnings.map(\.message) == [
                "This rewrites \u{201C}hello\u{201D} to itself, so it will never change anything."
            ]
        )
    }

    @Test func selfRewriteIgnoresSurroundingWhitespace() {
        let entry = DictionaryEntry.correction(hear: "  hello  ", write: "hello")
        let warnings = DictionaryWarning.check(entry)
        #expect(warnings.contains { $0.message.contains("rewrites") })
    }

    @Test func bothWarningsCanFireTogetherInOrder() {
        let entry = DictionaryEntry.correction(hear: "abcd", write: "ABCD")
        let warnings = DictionaryWarning.check(entry)
        #expect(
            warnings.map(\.message) == [
                "\u{201C}abcd\u{201D} is very short and will match often. Consider a longer phrase.",
                "This rewrites \u{201C}abcd\u{201D} to itself, so it will never change anything.",
            ]
        )
    }

    @Test func normalCorrectionHasNoWarnings() {
        let entry = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")
        #expect(DictionaryWarning.check(entry).isEmpty)
    }
}
