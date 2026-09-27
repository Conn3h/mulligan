import Testing
@testable import MulliganText

/// One test per row of the exact-examples table in spec 6.9, in table order.
@Suite("RuleBasedFormatter table examples")
struct RuleBasedFormatterTableTests {
    let formatter = RuleBasedFormatter()

    @Test("um, hello there -> Hello there.")
    func fillerWithTrailingCommaAtStart() async {
        #expect(await formatter.format("um, hello there") == "Hello there.")
    }

    @Test("I think, uh, it works -> I think, it works.")
    func fillerWithTrailingCommaMidSentence() async {
        #expect(await formatter.format("I think, uh, it works") == "I think, it works.")
    }

    @Test("the umbrella and the hummus -> The umbrella and the hummus.")
    func fillerSubstringsInsideOtherWordsAreUntouched() async {
        #expect(await formatter.format("the umbrella and the hummus") == "The umbrella and the hummus.")
    }

    @Test("removing all the ums -> Removing all the ums.")
    func pluralOfAFillerIsNotStripped() async {
        #expect(await formatter.format("removing all the ums") == "Removing all the ums.")
    }

    @Test("hello new paragraph world -> Hello\\n\\nWorld.")
    func newParagraphMidSentence() async {
        #expect(await formatter.format("hello new paragraph world") == "Hello\n\nWorld.")
    }

    @Test("first new line second -> First\\nSecond.")
    func newLineMidSentence() async {
        #expect(await formatter.format("first new line second") == "First\nSecond.")
    }

    @Test("new paragraph hello -> Hello.")
    func newParagraphAtStartIsTrimmedAway() async {
        #expect(await formatter.format("new paragraph hello") == "Hello.")
    }

    @Test("hello new paragraph -> Hello.")
    func newParagraphAtEndIsTrimmedAway() async {
        #expect(await formatter.format("hello new paragraph") == "Hello.")
    }

    @Test("one new paragraph new paragraph two -> One\\n\\nTwo.")
    func consecutiveNewParagraphsCollapseToTwoNewlines() async {
        #expect(await formatter.format("one new paragraph new paragraph two") == "One\n\nTwo.")
    }

    @Test("it cost 3.5 million dollars -> It cost 3.5 million dollars.")
    func decimalPointIsNotASentenceBoundary() async {
        #expect(await formatter.format("it cost 3.5 million dollars") == "It cost 3.5 million dollars.")
    }

    @Test("see www.example.com for details -> See www.example.com for details.")
    func urlPeriodsAreNotSentenceBoundaries() async {
        #expect(await formatter.format("see www.example.com for details") == "See www.example.com for details.")
    }

    @Test("e.g. this one -> E.g. This one.")
    func abbreviationPeriodFollowedByLetterIsNotABoundary() async {
        #expect(await formatter.format("e.g. this one") == "E.g. This one.")
    }

    @Test("3 apples and 2 pears -> 3 apples and 2 pears.")
    func digitAfterBoundaryCapitalizesNothing() async {
        #expect(await formatter.format("3 apples and 2 pears") == "3 apples and 2 pears.")
    }

    @Test("is it working? yes it is -> Is it working? Yes it is.")
    func questionMarkFollowedBySpaceIsABoundary() async {
        #expect(await formatter.format("is it working? yes it is") == "Is it working? Yes it is.")
    }

    @Test("wait , what ? -> Wait, what?")
    func spaceBeforePunctuationIsRemovedAndNoExtraPeriodIsAdded() async {
        #expect(await formatter.format("wait , what ?") == "Wait, what?")
    }

    @Test("already done. -> Already done.")
    func existingTerminalPeriodIsNotDuplicated() async {
        #expect(await formatter.format("already done.") == "Already done.")
    }

    @Test("whitespace-only input -> empty")
    func whitespaceOnlyInputProducesEmptyOutput() async {
        #expect(await formatter.format("   ") == "")
    }
}

/// Each rule exercised on its own, including a negative case that proves the
/// rule does not fire where it should not.
@Suite("RuleBasedFormatter rule behavior")
struct RuleBasedFormatterRuleTests {
    let formatter = RuleBasedFormatter()

    // MARK: Rule 1 - trim / empty short-circuit

    @Test("all-whitespace input, including tabs and newlines, is empty")
    func allWhitespaceVariantsProduceEmptyOutput() async {
        #expect(await formatter.format("\n\t  \n") == "")
    }

    @Test("non-empty input after trimming is processed normally")
    func nonEmptyInputIsNotShortCircuited() async {
        #expect(await formatter.format("  hello  ") == "Hello.")
    }

    // MARK: Rule 2 - standalone filler stripping

    @Test("erm is stripped as a standalone filler")
    func ermIsStripped() async {
        #expect(await formatter.format("erm this is fine") == "This is fine.")
    }

    @Test("uhm is stripped as a standalone filler")
    func uhmIsStripped() async {
        #expect(await formatter.format("uhm this is fine") == "This is fine.")
    }

    @Test("hmm is stripped as a standalone filler")
    func hmmIsStripped() async {
        #expect(await formatter.format("hmm this is fine") == "This is fine.")
    }

    @Test("mhm is stripped as a standalone filler")
    func mhmIsStripped() async {
        #expect(await formatter.format("mhm this is fine") == "This is fine.")
    }

    @Test("only one immediately following comma is absorbed, not two")
    func onlyOneTrailingCommaIsAbsorbed() async {
        #expect(await formatter.format("I said um,, that's fine") == "I said, that's fine.")
    }

    // MARK: Rule 3 - spoken punctuation

    @Test("new paragraph inside a larger word is not converted (negative case)")
    func spokenPhraseInsideAWordIsNotConverted() async {
        #expect(await formatter.format("renew paragraph is due") == "Renew paragraph is due.")
    }

    // MARK: Rule 4 - whitespace collapse

    @Test("runs of spaces collapse to one")
    func multipleSpacesCollapseToOne() async {
        #expect(await formatter.format("hello    world") == "Hello world.")
    }

    @Test("a literal newline already in the raw text is preserved, not collapsed to a space")
    func literalNewlineIsPreservedNotCollapsed() async {
        #expect(await formatter.format("hello\nworld") == "Hello\nWorld.")
    }

    // MARK: Rule 5 - capitalise sentence starts

    @Test("words with no boundary before them stay lowercase (negative case)")
    func midSentenceWordsStayLowercase() async {
        #expect(await formatter.format("i am fine today") == "I am fine today.")
    }

    // MARK: Rule 6 - terminal punctuation

    @Test("an existing exclamation mark is not followed by an extra period")
    func existingExclamationIsNotDoubled() async {
        #expect(await formatter.format("that's great") == "That's great.")
        #expect(await formatter.format("that's great!") == "That's great!")
    }
}
