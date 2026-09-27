import Testing
@testable import MulliganText

/// The four rejection paths from spec 6.9, in check order, each asserting the
/// exact reason prefix, plus the accepted cases named in the spec.
@Suite("CleanupGuard")
struct CleanupGuardTests {

    // MARK: Check 1 - empty

    @Test("rejects when the original has no content words")
    func rejectsWhenOriginalHasNoContentWords() {
        let verdict = CleanupGuard.evaluate(original: "the a an", cleaned: "hello world")
        #expect(verdict == .rejected(reason: "empty"))
    }

    @Test("rejects when the cleaned text has no content words")
    func rejectsWhenCleanedHasNoContentWords() {
        let verdict = CleanupGuard.evaluate(original: "please help me now", cleaned: "the")
        #expect(verdict == .rejected(reason: "empty"))
    }

    // MARK: Check 2 - no invented content words

    @Test("rejects a single invented content word")
    func rejectsSingleInventedWord() {
        let verdict = CleanupGuard.evaluate(original: "I need coffee", cleaned: "I need coffee and tea")
        #expect(verdict == .rejected(reason: "invented: tea"))
    }

    @Test("joins multiple invented words in order of first appearance")
    func rejectsMultipleInventedWordsJoinedInOrder() {
        let verdict = CleanupGuard.evaluate(original: "I like cats", cleaned: "I like cats and dogs are cute")
        #expect(verdict == .rejected(reason: "invented: dogs, are, cute"))
    }

    @Test("an answer to the dictated question is rejected as invented")
    func rejectsAnsweredQuestionAsInvented() {
        let verdict = CleanupGuard.evaluate(
            original: "what is the capital of France",
            cleaned: "The capital of France is Paris."
        )
        #expect(verdict == .rejected(reason: "invented: paris"))
    }

    // MARK: Check 3 - length ratio

    @Test("rejects a cleanup that is far too short")
    func rejectsWhenCleanedIsTooShort() {
        let verdict = CleanupGuard.evaluate(original: "we should go to the store now", cleaned: "Go.")
        #expect(verdict == .rejected(reason: "length ratio 0.17"))
    }

    @Test("rejects a cleanup that is far too long")
    func rejectsWhenCleanedIsTooLong() {
        let verdict = CleanupGuard.evaluate(original: "go", cleaned: "go go go go go go go")
        #expect(verdict == .rejected(reason: "length ratio 7.00"))
    }

    // MARK: Check 4 - assistant tells

    @Test("rejects an assistant preamble even when content words match exactly")
    func rejectsAssistantPreamble() {
        let verdict = CleanupGuard.evaluate(
            original: "sure that works for me",
            cleaned: "Sure, that works for me."
        )
        #expect(verdict == .rejected(reason: "assistant preamble"))
    }

    // MARK: Accepted cases

    @Test("an accepted filler-heavy cleanup")
    func acceptsFillerHeavyCleanup() {
        let verdict = CleanupGuard.evaluate(
            original: "um so like I think we should uh ship it",
            cleaned: "I think we should ship it."
        )
        #expect(verdict == .accepted)
    }

    @Test("I know -> I know. is accepted via the zero-denominator fallback")
    func acceptsZeroDenominatorFallback() {
        let verdict = CleanupGuard.evaluate(original: "I know", cleaned: "I know.")
        #expect(verdict == .accepted)
    }
}
