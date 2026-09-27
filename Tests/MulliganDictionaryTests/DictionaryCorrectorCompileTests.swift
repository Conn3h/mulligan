import Testing
@testable import MulliganDictionary

/// Generated trigger patterns always compile, so the failure path is reached through the
/// internal candidate seam with a hand-written pattern `NSRegularExpression` rejects.
@Suite("DictionaryCorrector rule compilation")
struct DictionaryCorrectorCompileTests {
    private let broken = DictionaryCorrector.Candidate(pattern: "(", write: "never")
    private let cloudCode = DictionaryCorrector.Candidate(pattern: "cloud[\\s\\-]*code", write: "Claude Code")

    @Test func anUncompilablePatternIsReportedAsAFailure() {
        let outcome = DictionaryCorrector.compile([broken, cloudCode])

        #expect(outcome.rules.map(\.write) == ["Claude Code"])
        #expect(outcome.failures.map(\.pattern) == ["("])
        #expect(outcome.failures.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func anUncompilablePatternIsSkippedWithoutDisablingTheRest() {
        let corrector = DictionaryCorrector(candidates: [broken, cloudCode])

        let result = corrector.apply(to: "open cloud code")

        #expect(result.text == "open Claude Code")
        #expect(result.applied == [AppliedCorrection(from: "cloud code", to: "Claude Code", count: 1)])
    }

    @Test func generatedPatternsAllCompile() {
        let entries: [DictionaryEntry] = [
            .correction(hear: "c++ (lang)", write: "C++"),
            .correction(hear: "a.b*c?", write: "regex bait"),
            .correction(hear: "[brackets] {braces} $^|\\", write: "escaped"),
        ]
        let corrector = DictionaryCorrector(entries: entries)

        #expect(corrector.apply(to: "use c++ (lang) daily").text == "use C++ daily")
        #expect(corrector.apply(to: "a.b*c?").text == "regex bait")
        #expect(corrector.apply(to: "[brackets] {braces} $^|\\").text == "escaped")
    }

    /// Regression net for moving compilation from `apply` to `init`: a corrector built once
    /// applies the same corrections across repeated `apply` calls.
    @Test func repeatedApplyIsStableAfterCompileAtInit() {
        let corrector = DictionaryCorrector(entries: [
            .correction(hear: "cloud code", write: "Claude Code"),
        ])
        let first = corrector.apply(to: "open cloud code now")
        let second = corrector.apply(to: "open cloud code now")
        #expect(first.text == "open Claude Code now")
        #expect(second.text == first.text)
        #expect(first.applied == second.applied)
    }
}
