import Testing
@testable import SottoDictionary

@Suite("DictionaryCorrector.biasPhrases")
struct DictionaryCorrectorBiasTests {
    @Test func biasLimitIsOneHundred() {
        #expect(DictionaryCorrector.biasLimit == 100)
    }

    @Test func phrasesAreWriteSideInEntryOrder() {
        let entries: [DictionaryEntry] = [
            .term("Alpha"),
            .correction(hear: "beeta", write: "Beta"),
            .term("Gamma"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Alpha", "Beta", "Gamma"])
    }

    @Test func termsAndCorrectionsBothContribute() {
        let entries: [DictionaryEntry] = [
            .correction(hear: "cloud code", write: "Claude Code"),
            .term("Lindqvist"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Claude Code", "Lindqvist"])
    }

    @Test func deduplicatesCaseInsensitivelyKeepingFirstOccurrence() {
        let entries: [DictionaryEntry] = [
            .term("Claude"),
            .correction(hear: "x", write: "CLAUDE"),
            .correction(hear: "y", write: "claude"),
            .term("Code"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Claude", "Code"])
    }

    @Test func trimsWhitespaceBeforeComparingAndReturning() {
        let entries: [DictionaryEntry] = [
            .term("  Claude  "),
            .correction(hear: "x", write: "claude"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Claude"])
    }

    @Test func excludesDisabledEntries() {
        let entries: [DictionaryEntry] = [
            DictionaryEntry(kind: .term, write: "Visible", isEnabled: true),
            DictionaryEntry(kind: .term, write: "Hidden", isEnabled: false),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Visible"])
    }

    @Test func excludesEmptyWriteAfterTrimming() {
        let entries: [DictionaryEntry] = [
            DictionaryEntry(kind: .term, write: "   "),
            DictionaryEntry(kind: .term, write: ""),
            .term("Real"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Real"])
    }

    @Test func capsAtBiasLimitKeepingEarliestEntries() {
        let entries = (1...(DictionaryCorrector.biasLimit + 5)).map {
            DictionaryEntry.term("Word\($0)")
        }
        let phrases = DictionaryCorrector.biasPhrases(from: entries)
        #expect(phrases.count == DictionaryCorrector.biasLimit)
        #expect(phrases.first == "Word1")
        #expect(phrases.last == "Word\(DictionaryCorrector.biasLimit)")
    }
}

@Suite("DictionaryCorrector.vocabularyPhrases")
struct DictionaryCorrectorVocabularyTests {
    @Test(arguments: [
        ("security codex", "security code"),
        ("cloud session", "Claude session"),
        ("hard codex", "hard-coded"),
        ("cloud code", "Claude Code"),
    ])
    func sharedWordMultiWordCorrectionsAreContext(_ hear: String, _ write: String) {
        #expect(DictionaryCorrector.isContextCorrection(.correction(hear: hear, write: write)))
    }

    @Test(arguments: [
        ("clawed", "Claude"),
        ("codex", "Codex"),
        ("burr cell", "Vercel"),
        ("versal app", "Vercel dashboard"),
    ])
    func otherCorrectionsAreNotContext(_ hear: String, _ write: String) {
        #expect(!DictionaryCorrector.isContextCorrection(.correction(hear: hear, write: write)))
    }

    @Test func termsAreNeverContext() {
        #expect(!DictionaryCorrector.isContextCorrection(.term("Claude Code")))
    }

    @Test func contextTargetsAreDropped() {
        let entries: [DictionaryEntry] = [
            .term("Codex"),
            .correction(hear: "security codex", write: "security code"),
            .correction(hear: "clawed", write: "Claude"),
        ]
        #expect(DictionaryCorrector.vocabularyPhrases(from: entries) == ["Codex", "Claude"])
    }

    @Test func aContextTargetNamedElsewhereStillBoosts() {
        let entries: [DictionaryEntry] = [
            .correction(hear: "cloud code", write: "Claude Code"),
            .term("Claude Code"),
        ]
        #expect(DictionaryCorrector.vocabularyPhrases(from: entries) == ["Claude Code"])
    }

    @Test func matchesBiasPhrasesWhenThereAreNoContextCorrections() {
        let entries: [DictionaryEntry] = [
            .term("Alpha"), .correction(hear: "beeta", write: "Beta"), .term("alpha"),
            DictionaryEntry(kind: .term, write: "Off", isEnabled: false),
        ] + (0..<120).map { .term("T\($0)") }
        #expect(DictionaryCorrector.vocabularyPhrases(from: entries) == DictionaryCorrector.biasPhrases(from: entries))
    }
}
