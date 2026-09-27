import Foundation

/// Deterministic, dependency-free transcript cleanup. Always available as the
/// fallback under `FoundationModelFormatter`, and the only formatter when
/// Smart cleanup is off. See spec 6.9 for the exact rule order and the
/// worked examples every rule is tested against.
public struct RuleBasedFormatter: TextFormatter {
    public init() {}

    public func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var text = trimmed
        text = Self.stripFillers(text)
        text = Self.convertSpokenPunctuation(text)
        text = Self.collapseWhitespace(text)
        text = Self.capitalizeSentenceStarts(text)
        text = Self.appendTerminalPunctuationIfNeeded(text)
        return text
    }
}

// MARK: - Shared word/phrase boundary rules

extension RuleBasedFormatter {
    /// A character that "attaches" to a word on its left: a following letter,
    /// digit or apostrophe means the position is not a standalone-word start.
    fileprivate static func blocksBoundaryOnLeft(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    /// A character that attaches to a word on its right: a letter or digit
    /// immediately after a candidate match means it is not standalone.
    /// Apostrophes are not fences on this side (spec 6.9 only names letters
    /// and digits for "followed by").
    fileprivate static func blocksBoundaryOnRight(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

// MARK: - Step 2: strip standalone fillers

extension RuleBasedFormatter {
    private static let fillerWords: Set<String> = ["um", "uh", "erm", "uhm", "hmm", "mhm"]

    fileprivate static func stripFillers(_ text: String) -> String {
        let chars = Array(text)
        var result = [Character]()
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if let end = fillerMatchEnd(chars, at: i) {
                i = end
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return String(result)
    }

    /// If a standalone filler word, optionally followed by one comma, starts
    /// at `index`, returns the index immediately after everything consumed.
    /// Otherwise nil.
    private static func fillerMatchEnd(_ chars: [Character], at index: Int) -> Int? {
        if index > 0, blocksBoundaryOnLeft(chars[index - 1]) { return nil }
        guard chars[index].isLetter else { return nil }

        var end = index
        while end < chars.count, chars[end].isLetter {
            end += 1
        }
        // The maximal letter run is the whole candidate word, so it already
        // cannot be followed by another letter; only a following digit still
        // needs to be rejected ("um2" is not standalone).
        guard end >= chars.count || !chars[end].isNumber else { return nil }

        let word = String(chars[index..<end]).lowercased()
        guard fillerWords.contains(word) else { return nil }

        if end < chars.count, chars[end] == "," {
            return end + 1
        }
        return end
    }
}

// MARK: - Step 3: spoken punctuation

extension RuleBasedFormatter {
    private static let spokenPhrases: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
    ]

    fileprivate static func convertSpokenPunctuation(_ text: String) -> String {
        let chars = Array(text)
        var result = [Character]()
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if let match = spokenPhraseMatch(chars, at: i) {
                result.append(contentsOf: match.replacement)
                i = match.end
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return String(result)
    }

    private static func spokenPhraseMatch(
        _ chars: [Character],
        at index: Int
    ) -> (replacement: String, end: Int)? {
        if index > 0, blocksBoundaryOnLeft(chars[index - 1]) { return nil }
        for entry in spokenPhrases {
            let end = index + entry.phrase.count
            guard end <= chars.count else { continue }
            guard String(chars[index..<end]).lowercased() == entry.phrase else { continue }
            if end < chars.count, blocksBoundaryOnRight(chars[end]) { continue }
            return (entry.replacement, end)
        }
        return nil
    }
}

// MARK: - Step 4: collapse whitespace

extension RuleBasedFormatter {
    private static let punctuationBeforeWhichSpaceIsRemoved: Set<Character> = [",", ".", "!", "?", ";", ":"]

    fileprivate static func collapseWhitespace(_ text: String) -> String {
        var result = text
        result = collapseSpaceAndTabRuns(result)
        result = removeSpaceOrTabAroundNewlines(result)
        result = removeSpaceBeforePunctuation(result)
        result = collapseExcessNewlines(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Runs of spaces and tabs collapse to a single space.
    private static func collapseSpaceAndTabRuns(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var inRun = false
        for char in text {
            if char == " " || char == "\t" {
                if !inRun {
                    result.append(" ")
                }
                inRun = true
            } else {
                result.append(char)
                inRun = false
            }
        }
        return result
    }

    /// A space or tab immediately before or after a newline is removed.
    private static func removeSpaceOrTabAroundNewlines(_ text: String) -> String {
        let chars = Array(text)
        var result = [Character]()
        result.reserveCapacity(chars.count)
        for (index, char) in chars.enumerated() {
            guard char == " " || char == "\t" else {
                result.append(char)
                continue
            }
            let precededByNewline = index > 0 && chars[index - 1] == "\n"
            let followedByNewline = index + 1 < chars.count && chars[index + 1] == "\n"
            if precededByNewline || followedByNewline { continue }
            result.append(char)
        }
        return String(result)
    }

    /// A space immediately before `, . ! ? ; :` is removed.
    private static func removeSpaceBeforePunctuation(_ text: String) -> String {
        let chars = Array(text)
        var result = [Character]()
        result.reserveCapacity(chars.count)
        for (index, char) in chars.enumerated() {
            if char == " ",
               index + 1 < chars.count,
               punctuationBeforeWhichSpaceIsRemoved.contains(chars[index + 1]) {
                continue
            }
            result.append(char)
        }
        return String(result)
    }

    /// Three or more consecutive newlines collapse to two.
    private static func collapseExcessNewlines(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var run = 0
        for char in text {
            if char == "\n" {
                run += 1
                if run <= 2 { result.append(char) }
            } else {
                run = 0
                result.append(char)
            }
        }
        return result
    }
}

// MARK: - Step 5: capitalise sentence starts

extension RuleBasedFormatter {
    private static let terminators: Set<Character> = [".", "!", "?"]

    /// The first letter of the text, the first letter after a newline, and
    /// the first letter after a terminator immediately followed by
    /// whitespace or end of text are capitalised. Only the very next letter
    /// after such a boundary is affected, and a digit encountered before any
    /// letter consumes the boundary without capitalising anything.
    fileprivate static func capitalizeSentenceStarts(_ text: String) -> String {
        let chars = Array(text)
        var result = [Character]()
        result.reserveCapacity(chars.count)
        var awaitingCapital = true

        for (index, char) in chars.enumerated() {
            if char == "\n" {
                awaitingCapital = true
                result.append(char)
                continue
            }
            if char.isLetter {
                if awaitingCapital {
                    result.append(contentsOf: char.uppercased())
                    awaitingCapital = false
                } else {
                    result.append(char)
                }
                continue
            }
            if char.isNumber {
                // A boundary followed by digits then letters capitalises
                // nothing: the digit spends the boundary.
                awaitingCapital = false
                result.append(char)
                continue
            }
            if terminators.contains(char) {
                let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                if next == nil || next!.isWhitespace {
                    awaitingCapital = true
                }
                result.append(char)
                continue
            }
            result.append(char)
        }
        return String(result)
    }
}

// MARK: - Step 6: terminal punctuation

extension RuleBasedFormatter {
    fileprivate static func appendTerminalPunctuationIfNeeded(_ text: String) -> String {
        guard let last = text.last else { return text }
        if last.isLetter || last.isNumber {
            return text + "."
        }
        return text
    }
}
