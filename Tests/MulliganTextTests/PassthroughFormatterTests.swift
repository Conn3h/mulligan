import Testing
@testable import MulliganText

/// PassthroughFormatter trims only: no filler stripping, no spoken
/// punctuation, no capitalisation, no terminal punctuation.
@Suite("PassthroughFormatter")
struct PassthroughFormatterTests {
    let formatter = PassthroughFormatter()

    @Test("leading and trailing whitespace is trimmed")
    func trimsLeadingAndTrailingWhitespace() async {
        #expect(await formatter.format("  hello world  ") == "hello world")
    }

    @Test("leading and trailing tabs and newlines are trimmed")
    func trimsTabsAndNewlines() async {
        #expect(await formatter.format("\n\t hello \t\n") == "hello")
    }

    @Test("fillers are left untouched")
    func doesNotStripFillers() async {
        #expect(await formatter.format("um, hello there") == "um, hello there")
    }

    @Test("spoken punctuation phrases are left untouched")
    func doesNotConvertSpokenPunctuation() async {
        #expect(await formatter.format("hello new paragraph world") == "hello new paragraph world")
    }

    @Test("no capitalisation is applied")
    func doesNotCapitalize() async {
        #expect(await formatter.format("hello there") == "hello there")
    }

    @Test("no terminal punctuation is added")
    func doesNotAddTerminalPunctuation() async {
        #expect(await formatter.format("hello there") == "hello there")
    }

    @Test("internal whitespace runs are left untouched")
    func doesNotCollapseInternalWhitespace() async {
        #expect(await formatter.format("hello    world") == "hello    world")
    }

    @Test("whitespace-only input becomes empty")
    func whitespaceOnlyInputProducesEmptyOutput() async {
        #expect(await formatter.format("   ") == "")
    }
}
