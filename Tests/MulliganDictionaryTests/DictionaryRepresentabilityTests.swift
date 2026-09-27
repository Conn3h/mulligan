import Testing
@testable import MulliganDictionary

@Suite struct DictionaryRepresentabilityTests {
    @Test func validTermAndCorrectionHaveNoIssues() {
        #expect(DictionaryFile.representabilityIssues(for: .term("Supabase")).isEmpty)
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "super base", write: "Supabase")).isEmpty)
    }

    @Test func blankWriteIsRefused() {
        #expect(DictionaryFile.representabilityIssues(for: .term("   ")) == [.blankWrite])
    }

    @Test func correctionWithBlankHearIsRefused() {
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: " ", write: "Mulligan")) == [.blankHear])
    }

    @Test func termsIgnoreHear() {
        let entry = DictionaryEntry(kind: .term, write: "Mulligan", hear: "# -> whatever")
        #expect(DictionaryFile.representabilityIssues(for: entry).isEmpty)
    }

    @Test func commentPrefixIsRefusedWhereItWouldStartTheLine() {
        #expect(DictionaryFile.representabilityIssues(for: .term("#tag")) == [.commentPrefix])
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "# off", write: "x")) == [.commentPrefix])
    }

    @Test func arrowIsRefusedBeforeTheStructuralArrow() {
        #expect(DictionaryFile.representabilityIssues(for: .term("a -> b")) == [.containsArrow])
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "a -> b", write: "c")) == [.containsArrow])
    }

    @Test func correctionWriteSideIsPlainTextAfterTheFirstArrow() {
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "x", write: "y -> z")).isEmpty)
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "tag", write: "#swift")).isEmpty)
        let parsed = DictionaryFile.parse(DictionaryFile.serialize([.correction(hear: "x", write: "y -> z")]))
        #expect(parsed.map(\.write) == ["y -> z"])
    }

    @Test func issuesAccumulate() {
        let issues = DictionaryFile.representabilityIssues(for: .correction(hear: "#a -> b", write: ""))
        #expect(issues == [.blankWrite, .commentPrefix, .containsArrow])
    }

    @Test func everyIssueHasAMessage() {
        for issue in DictionaryRepresentabilityIssue.allCases {
            #expect(!issue.message.isEmpty)
        }
    }
}
