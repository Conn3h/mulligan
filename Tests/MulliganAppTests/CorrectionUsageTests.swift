import Foundation
import MulliganDictionary
import Testing
@testable import Mulligan

/// How often each dictionary entry has fired, counted from the corrections History recorded.
@Suite
struct CorrectionUsageTests {
    private func run(_ corrections: [AppliedCorrection]?) -> DictationRun {
        DictationRun(
            date: Date(), engine: "Parakeet", source: "hotkey", audioSeconds: 1, processSeconds: 0.1,
            text: "text", corrections: corrections
        )
    }

    @Test func sumsEachEntrysCountsAcrossRuns() {
        let fix = DictionaryEntry.correction(hear: "pie test", write: "pytest")
        let runs = [
            run([AppliedCorrection(from: "pie test", to: "pytest", count: 2)]),
            run([AppliedCorrection(from: "Pie Test", to: "pytest", count: 1)]),
            run(nil),
        ]
        #expect(CorrectionUsage.counts(entries: [fix], runs: runs) == [fix.id: 3])
    }

    @Test func aCorrectionAndATermWithTheSameWriteAreToldApart() {
        let term = DictionaryEntry.term("Mulligan")
        let fix = DictionaryEntry.correction(hear: "mulligun", write: "Mulligan")
        let runs = [
            run([AppliedCorrection(from: "mulligun", to: "Mulligan", count: 1)]),
            run([AppliedCorrection(from: "mulligan", to: "Mulligan", count: 4)]),
        ]
        let counts = CorrectionUsage.counts(entries: [term, fix], runs: runs)
        #expect(counts[fix.id] == 1)
        #expect(counts[term.id] == 4)
    }

    @Test func aCorrectionThatAlreadyReadAsWriteStillCounts() {
        // `from` is the whole span replaced, which can run past `hear` ("next" in "Next.js").
        let fix = DictionaryEntry.correction(hear: "next", write: "Next.js")
        let runs = [run([AppliedCorrection(from: "next.js", to: "Next.js", count: 1)])]
        #expect(CorrectionUsage.counts(entries: [fix], runs: runs) == [fix.id: 1])
    }

    @Test func correctionsFromEntriesSinceDeletedAreIgnored() {
        let fix = DictionaryEntry.correction(hear: "pie test", write: "pytest")
        let runs = [run([AppliedCorrection(from: "cloud", to: "Claude", count: 5)])]
        #expect(CorrectionUsage.counts(entries: [fix], runs: runs).isEmpty)
    }
}
