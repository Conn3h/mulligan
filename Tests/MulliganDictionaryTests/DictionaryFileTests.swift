import Testing
@testable import MulliganDictionary

@Suite("DictionaryFile parsing and serializing")
struct DictionaryFileTests {
    @Test func bareLineIsATerm() {
        let entries = DictionaryFile.parse("hello world")
        #expect(entries.count == 1)
        #expect(entries[0].kind == .term)
        #expect(entries[0].write == "hello world")
        #expect(entries[0].hear == "")
        #expect(entries[0].isEnabled == true)
    }

    @Test func arrowLineIsACorrection() {
        let entries = DictionaryFile.parse("cloud code -> Claude Code")
        #expect(entries.count == 1)
        #expect(entries[0].kind == .correction)
        #expect(entries[0].hear == "cloud code")
        #expect(entries[0].write == "Claude Code")
        #expect(entries[0].isEnabled == true)
    }

    @Test func arrowSidesAreTrimmed() {
        let entries = DictionaryFile.parse("  cloud code   ->   Claude Code  ")
        #expect(entries.count == 1)
        #expect(entries[0].hear == "cloud code")
        #expect(entries[0].write == "Claude Code")
    }

    @Test func ordinaryCommentIsDiscarded() {
        let entries = DictionaryFile.parse("# just a note about the file")
        #expect(entries.isEmpty)
    }

    @Test func ordinaryCommentAmongOtherLinesIsDropped() {
        let entries = DictionaryFile.parse(
            """
            # this is a note
            hello
            # another note
            """
        )
        #expect(entries.count == 1)
        #expect(entries[0].write == "hello")
    }

    @Test func offMarkerDisablesACorrection() {
        let entries = DictionaryFile.parse("# off: cloud code -> Claude Code")
        #expect(entries.count == 1)
        #expect(entries[0].kind == .correction)
        #expect(entries[0].hear == "cloud code")
        #expect(entries[0].write == "Claude Code")
        #expect(entries[0].isEnabled == false)
    }

    @Test func offMarkerDisablesATerm() {
        let entries = DictionaryFile.parse("# off: somebody")
        #expect(entries.count == 1)
        #expect(entries[0].kind == .term)
        #expect(entries[0].write == "somebody")
        #expect(entries[0].isEnabled == false)
    }

    @Test func offMarkerIsCaseInsensitive() {
        let entries = DictionaryFile.parse("# OFF: somebody")
        #expect(entries.count == 1)
        #expect(entries[0].isEnabled == false)
        #expect(entries[0].write == "somebody")
    }

    @Test func blankLinesAreIgnored() {
        let entries = DictionaryFile.parse("\n\n   \n\thello\n\n   \n")
        #expect(entries.count == 1)
        #expect(entries[0].write == "hello")
    }

    @Test func firstArrowRuleKeepsLaterArrowsInWrite() {
        let entries = DictionaryFile.parse("x -> y -> z")
        #expect(entries.count == 1)
        #expect(entries[0].hear == "x")
        #expect(entries[0].write == "y -> z")
    }

    @Test func emptyHearSideIsIgnored() {
        let entries = DictionaryFile.parse(" -> write")
        #expect(entries.isEmpty)
    }

    @Test func emptyWriteSideIsIgnored() {
        let entries = DictionaryFile.parse("hear -> ")
        #expect(entries.isEmpty)
    }

    @Test func bothSidesEmptyIsIgnored() {
        let entries = DictionaryFile.parse("->")
        #expect(entries.isEmpty)
    }

    @Test func emptySideIsIgnoredEvenWhenDisabled() {
        let entries = DictionaryFile.parse("# off: -> write")
        #expect(entries.isEmpty)
    }

    @Test func semanticRoundTrip() {
        let original: [DictionaryEntry] = [
            .term("Lindqvist"),
            .correction(hear: "cloud code", write: "Claude Code"),
            DictionaryEntry(kind: .term, write: "disabled term", isEnabled: false),
            DictionaryEntry(
                kind: .correction,
                write: "Claude Code",
                hear: "cloud coding",
                isEnabled: false
            ),
        ]

        let serialized = DictionaryFile.serialize(original)
        let roundTripped = DictionaryFile.parse(serialized)

        #expect(roundTripped.count == original.count)
        for (before, after) in zip(original, roundTripped) {
            #expect(after.kind == before.kind)
            #expect(after.write == before.write)
            #expect(after.hear == before.hear)
            #expect(after.isEnabled == before.isEnabled)
        }
    }

    @Test func serializeDiscardsOrdinaryCommentsOnReparse() {
        // The header written by `serialize` is itself an ordinary comment block, so
        // parsing serialized output back never resurrects it as entries.
        let serialized = DictionaryFile.serialize([.term("hello")])
        let roundTripped = DictionaryFile.parse(serialized)
        #expect(roundTripped.count == 1)
        #expect(roundTripped[0].write == "hello")
    }
}
