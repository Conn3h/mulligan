import Testing
@testable import SottoDictionary

@Suite("BiasStrictness")
struct BiasStrictnessTests {
    @Test(arguments: ["Codex", "Xcode", "Expo", "repo", "Zod", "Hermes", "Vitest"])
    func shortSingleWordTermsGetTheStricterFloor(term: String) {
        #expect(BiasStrictness.minimumSimilarity(for: term) == BiasStrictness.shortTermMinSimilarity)
    }

    @Test(arguments: ["Postgres", "Playwright", "RevenueCat", "Anthropic"])
    func longerSingleWordTermsKeepTheDefault(term: String) {
        #expect(BiasStrictness.minimumSimilarity(for: term) == nil)
    }

    @Test(arguments: ["Claude Code", "React Native", "App Store Connect", "Wi-Fi", "e-mail"])
    func multiWordTermsKeepTheDefault(term: String) {
        #expect(BiasStrictness.minimumSimilarity(for: term) == nil)
    }

    @Test func surroundingWhitespaceDoesNotCount() {
        #expect(BiasStrictness.minimumSimilarity(for: "  Codex\n") == BiasStrictness.shortTermMinSimilarity)
    }

    @Test func emptyTermKeepsTheDefault() {
        #expect(BiasStrictness.minimumSimilarity(for: "   ") == nil)
    }

    /// The floor must sit above what one edit costs a term of the maximum short length
    /// (one letter off in six is 0.83), or "code" could still become "Codex" (0.80).
    @Test func floorRejectsOneEditAtTheMaximumShortLength() {
        let oneEditSimilarity = 1 - 1 / Float(BiasStrictness.shortTermMaxLength)
        #expect(oneEditSimilarity < BiasStrictness.shortTermMinSimilarity)
    }
}
