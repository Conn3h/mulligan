import CoreFoundation
import Testing
@testable import Mulligan

/// What counts as proof that an accessibility write landed. Too strict and a write that did
/// land is pasted again (the text appears twice); too loose and a change that is not ours
/// (streamed terminal output) hides a dropped write.
@Suite
struct ExpectedWriteTests {
    /// Caret at 10 with nothing selected; 20 units inserted; the field held 100 units.
    private let expected = TextInjector.ExpectedWrite(
        before: CFRange(location: 10, length: 0), insertedUnits: 20, countBefore: 100
    )

    @Test func caretAfterTheInsertedTextCounts() {
        #expect(expected.matchesSelection(CFRange(location: 30, length: 0)))
    }

    @Test func insertedTextLeftSelectedCounts() {
        #expect(expected.matchesSelection(CFRange(location: 10, length: 20)))
    }

    @Test func editorThatExpandsOnInsertStillCounts() {
        // Markdown or emoji conversion can make the landed text longer than what we wrote.
        #expect(expected.matchesSelection(CFRange(location: 45, length: 0)))
        #expect(expected.matchesCount(135))
    }

    @Test func editorThatCollapsesOnInsertStillCounts() {
        #expect(expected.matchesSelection(CFRange(location: 22, length: 0)))
        #expect(expected.matchesCount(112))
    }

    @Test func unchangedSelectionDoesNotCount() {
        #expect(!expected.matchesSelection(CFRange(location: 10, length: 0)))
    }

    @Test func caretMovingBackwardsDoesNotCount() {
        #expect(!expected.matchesSelection(CFRange(location: 4, length: 0)))
    }

    @Test func largeUnrelatedJumpDoesNotCount() {
        // A terminal printing a screenful of output moves the caret far past our text.
        #expect(!expected.matchesSelection(CFRange(location: 900, length: 0)))
        #expect(!expected.matchesCount(900))
    }

    @Test func smallUnrelatedChangesDoNotCount() {
        // 20 units were written; a one-unit change either way is someone else's edit.
        #expect(!expected.matchesCount(99))
        #expect(!expected.matchesCount(101))
        #expect(!expected.matchesSelection(CFRange(location: 11, length: 0)))
    }

    @Test func unchangedOrShrinkingLengthDoesNotCount() {
        #expect(!expected.matchesCount(100))
        #expect(!expected.matchesCount(95))
    }

    @Test func replacingASelectionAccountsForTheRemovedText() {
        let replacing = TextInjector.ExpectedWrite(
            before: CFRange(location: 10, length: 5), insertedUnits: 20, countBefore: 100
        )
        #expect(replacing.matchesCount(115))
        #expect(replacing.matchesSelection(CFRange(location: 30, length: 0)))
    }

    @Test func unknownStartingLengthNeverCountsByLength() {
        let unknown = TextInjector.ExpectedWrite(
            before: CFRange(location: 10, length: 0), insertedUnits: 20, countBefore: nil
        )
        #expect(!unknown.matchesCount(120))
    }
}
