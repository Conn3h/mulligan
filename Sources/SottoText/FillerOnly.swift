import Foundation

/// Recognises a transcript made only of hesitation sounds. Parakeet turns a silent hold into
/// "Mm-." or "Hmm."; nobody dictates that on purpose, so such a transcript is dropped rather
/// than typed. Any real word, however short or quiet, keeps the whole transcript.
public enum FillerOnly {
    private static let fillers: Set<String> = ["hmm", "hm", "mhm", "uh", "um", "erm", "uhm", "er", "ah", "eh"]

    /// True when `text` has at least one word and every word is a filler. Words are split on
    /// whitespace and hyphens ("Mm-hmm") with surrounding punctuation trimmed; a word that
    /// still holds a digit or symbol ("42", "50%") is content, never filler.
    public static func matches(_ text: String) -> Bool {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return false
        }
        return words.allSatisfy(isFiller)
    }

    /// "m", "mm", "mmm" and the fixed set; "hmmm" and "uhhh" style stretches count too.
    private static func isFiller(_ word: String) -> Bool {
        guard word.allSatisfy(\.isLetter) else {
            return false
        }
        if word.allSatisfy({ $0 == "m" }) {
            return true
        }
        return fillers.contains(collapsingRepeats(word))
    }

    private static func collapsingRepeats(_ word: String) -> String {
        var result = ""
        for character in word where character != result.last {
            result.append(character)
        }
        return result
    }
}
