import Testing
@testable import SottoText

@Suite("FillerOnly")
struct FillerOnlyTests {
    /// What Parakeet returns for a silent hold, plus the other bare hesitation sounds.
    @Test(arguments: ["Mm-.", "Mm.", "mm", "Mmm...", "Hmm.", "Hm?", "Mhm.", "Uh.", "Um,", "Erm.", "Uhm", "Mm. Mm.", "Mm-hmm"])
    func bareFillerIsFillerOnly(text: String) {
        #expect(FillerOnly.matches(text))
    }

    /// Short real words must never be dropped.
    @Test(arguments: ["Yes.", "No.", "Okay.", "Done.", "Yeah.", "Go ahead.", "Mm, yes.", "Um, okay", "Hmmus", "Mom.", "I'm.", "Um, 42.", "10 mm", "Mm 3", "Hmm, 50%"])
    func anyRealWordIsNotFillerOnly(text: String) {
        #expect(!FillerOnly.matches(text))
    }

    @Test(arguments: ["", "   ", "...", "-"])
    func textWithoutWordsIsNotFillerOnly(text: String) {
        // Blank transcripts are handled as blank, not as filler.
        #expect(!FillerOnly.matches(text))
    }
}
