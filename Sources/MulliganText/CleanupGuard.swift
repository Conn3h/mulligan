import Foundation

/// Whether a model-produced cleanup was accepted, or the reason it was not.
public enum CleanupVerdict: Sendable, Equatable {
    case accepted
    case rejected(reason: String)
}

/// Decides whether a model-produced cleanup is recognisably a cleanup of the
/// input rather than an answer to it. See spec 6.9 for the four checks, run
/// in order, and their exact reason strings.
public enum CleanupGuard {
    public static func evaluate(original: String, cleaned: String) -> CleanupVerdict {
        let originalContentWords = contentWords(in: original)
        let cleanedContentWords = contentWords(in: cleaned)

        if cleanedContentWords.isEmpty || originalContentWords.isEmpty {
            return .rejected(reason: "empty")
        }

        if let inventedReason = inventedWordsReason(original: originalContentWords, cleaned: cleanedContentWords) {
            return .rejected(reason: inventedReason)
        }

        if let ratioReason = lengthRatioReason(original: originalContentWords, cleaned: cleanedContentWords) {
            return .rejected(reason: ratioReason)
        }

        let cleanedLowercased = cleaned.lowercased()
        if assistantPreambles.contains(where: cleanedLowercased.hasPrefix) {
            return .rejected(reason: "assistant preamble")
        }

        return .accepted
    }

    // MARK: Word sets from spec 6.9

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then",
        "s", "t", "re", "ll", "ve", "d", "m",
    ]

    /// The single-token filler set used only to discount the denominator of
    /// the length-ratio check.
    private static let ratioFillerTokens: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm",
        "like", "basically", "actually", "literally", "just", "really",
        "okay", "ok", "well", "right", "anyway",
        "i", "mean", "you", "know", "kind", "sort", "of",
        "stuff", "thing", "things",
    ]

    private static let assistantPreambles: [String] = [
        "here's the cleaned", "here is the cleaned", "cleaned transcript",
        "sure,", "certainly,", "i cannot", "i can't", "as an ai",
    ]

    // MARK: Checks

    /// Reject if any content word of `cleaned` does not occur among the
    /// content words of `original`. Up to five invented words, in order of
    /// first appearance in `cleaned`, deduplicated.
    private static func inventedWordsReason(original: [String], cleaned: [String]) -> String? {
        let originalSet = Set(original)
        var invented: [String] = []
        var seen: Set<String> = []
        for word in cleaned where !originalSet.contains(word) {
            if seen.insert(word).inserted {
                invented.append(word)
            }
        }
        guard !invented.isEmpty else { return nil }
        return "invented: " + invented.prefix(5).joined(separator: ", ")
    }

    /// `ratio = cleanedContentCount / denominator`, where `denominator` is
    /// the count of original content words that are not filler tokens, or
    /// the undiscounted content count when that would be zero. Reject unless
    /// `0.35 <= ratio <= 1.5`.
    private static func lengthRatioReason(original: [String], cleaned: [String]) -> String? {
        let discountedCount = original.filter { !ratioFillerTokens.contains($0) }.count
        let denominator = discountedCount == 0 ? original.count : discountedCount
        let ratio = Double(cleaned.count) / Double(denominator)
        guard ratio >= 0.35, ratio <= 1.5 else {
            return "length ratio " + String(format: "%.2f", ratio)
        }
        return nil
    }

    // MARK: Tokenisation

    /// Lowercase, then split on any character that is not a letter or digit;
    /// content words are the tokens not in the stop set.
    private static func contentWords(in text: String) -> [String] {
        tokens(in: text).filter { !stopWords.contains($0) }
    }

    private static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text.lowercased() {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
