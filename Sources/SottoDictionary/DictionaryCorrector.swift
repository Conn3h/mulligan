import Foundation
#if canImport(os)
import os
#endif

/// One correction that fired while applying a `DictionaryCorrector`, reported once per
/// entry (not once per occurrence).
public struct AppliedCorrection: Codable, Hashable, Sendable {
    /// The exact substring matched by the entry's *first* occurrence (original casing and
    /// spacing, as it appeared in the input).
    public let from: String
    /// The entry's `write` text.
    public let to: String
    /// How many times this entry fired.
    public let count: Int

    public init(from: String, to: String, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }
}

/// Applies personal-dictionary corrections to dictated text.
///
/// See `docs/SPEC.md` section 6.11 for the full matching contract. In short: only enabled
/// `.correction` entries participate; text and triggers are NFC-normalised before matching;
/// a trigger's parts (split on spaces, tabs and hyphens) are joined with `[\s\-]*` so glued,
/// spaced and hyphenated forms all match, case-insensitively; a match must not be fenced by
/// a letter, digit, combining mark or hyphen on either side (apostrophes are boundaries, so
/// possessives are corrected); a single left-to-right scan resolves overlaps by longest
/// match, ties going to the earlier entry, and never re-matches replacement text; when the
/// entry's `write` text is already present beyond the trigger's own span, the whole existing
/// span is replaced (so it is recased, never duplicated) and scanning resumes past it.
public struct DictionaryCorrector: Sendable {
    /// A trigger pattern paired with its replacement, in the order its owning entry
    /// appears in `entries`. Only enabled `.correction` entries with a non-empty trigger
    /// contribute one of these. Internal so a test can hand in a pattern that will not
    /// compile, which generated patterns never do.
    struct Candidate: Sendable {
        let pattern: String
        let write: String
    }

    /// A candidate whose pattern `NSRegularExpression` refused. Generated patterns are
    /// escaped part by part and should never land here; the type exists so the failure path
    /// stays reachable and tested.
    struct CompileFailure: Sendable, Equatable {
        let pattern: String
        let reason: String
    }

    /// A compiled rule, built once at init and reused by every `apply` call. Immutable
    /// `NSRegularExpression` is `Sendable` on macOS 26, so this keeps `DictionaryCorrector`
    /// a `Sendable` value type.
    struct CompiledRule: Sendable {
        let regex: NSRegularExpression
        let write: String
        /// NFC form of `write`, precomputed once for the already-written check below (the
        /// input is NFC-normalised at the top of `apply`, so comparing against a raw,
        /// possibly-decomposed `write` could silently never match).
        let normalizedWrite: String
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.conn3h.sotto", category: "dictionary")
    #endif

    private let candidates: [Candidate]
    private let rules: [CompiledRule]

    public init(entries: [DictionaryEntry]) {
        candidates = entries.compactMap { entry in
            guard entry.kind == .correction, entry.isEnabled else { return nil }
            guard let pattern = Self.triggerPattern(for: entry.hear) else { return nil }
            return Candidate(pattern: pattern, write: entry.write)
        }
        let compiled = Self.compile(candidates)
        for failure in compiled.failures {
            Self.logCompileFailure(failure)
        }
        rules = compiled.rules
    }

    /// Test seam: skips trigger-pattern generation so a compile failure can be exercised.
    init(candidates: [Candidate]) {
        self.candidates = candidates
        let compiled = Self.compile(candidates)
        for failure in compiled.failures {
            Self.logCompileFailure(failure)
        }
        rules = compiled.rules
    }

    public var isEmpty: Bool { candidates.isEmpty }

    /// Cap on how many phrases are handed to the recognizer as contextual bias. Distinct
    /// write targets fill this budget (corrections sharing a target cost one slot); the
    /// correction pass itself is uncapped. Kept generous so a real per-project vocabulary
    /// fits without silently dropping terms, while staying well within what contextual
    /// biasing handles before it dilutes.
    public static let biasLimit = 100

    /// The `write` side of every enabled entry (terms and corrections), trimmed, skipping
    /// empties, de-duplicated case-insensitively (keeping the first occurrence), in entry
    /// order, capped at `biasLimit`.
    public static func biasPhrases(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for entry in entries {
            guard entry.isEnabled else { continue }
            let trimmed = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            result.append(trimmed)
            if result.count == biasLimit { break }
        }

        return result
    }

    /// A correction that fixes a word only in the company of another: both sides have at
    /// least two words and share one ("security codex -> security code"). Its target must not
    /// feed vocabulary boosting, which would push the engine toward the phrase it exists to undo.
    public static func isContextCorrection(_ entry: DictionaryEntry) -> Bool {
        guard entry.kind == .correction else { return false }
        let hearWords = words(entry.hear)
        let writeWords = words(entry.write)
        guard hearWords.count >= 2, writeWords.count >= 2 else { return false }
        return !Set(hearWords).isDisjoint(with: writeWords)
    }

    /// `biasPhrases` over every entry that is not a context correction: Parakeet's list.
    public static func vocabularyPhrases(from entries: [DictionaryEntry]) -> [String] {
        biasPhrases(from: entries.filter { !isContextCorrection($0) })
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" })
            .map(String.init)
    }

    public func apply(to text: String) -> (text: String, applied: [AppliedCorrection]) {
        // The result is always the NFC form of the input, even when nothing matches.
        let normalized = text.precomposedStringWithCanonicalMapping
        guard !candidates.isEmpty, !normalized.isEmpty else { return (normalized, []) }

        guard !rules.isEmpty else { return (normalized, []) }

        var output = ""
        output.reserveCapacity(normalized.count)

        // Which compiled entries have fired, in the order they first fired (which, because
        // this is a single strictly left-to-right pass, is already ordered by first-match
        // position).
        var firstFireOrder: [Int] = []
        var firstFrom = [Int: String]()
        var counts = [Int: Int]()

        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let remaining = NSRange(cursor..<normalized.endIndex, in: normalized)

            var bestIndex: Int?
            var bestRange: Range<String.Index>?
            var bestLength = 0

            for (index, rule) in rules.enumerated() {
                guard let match = rule.regex.firstMatch(
                    in: normalized,
                    options: [.anchored],
                    range: remaining
                ) else { continue }
                guard let range = Range(match.range, in: normalized) else { continue }
                guard Self.fencesAllow(normalized, range) else { continue }

                let length = normalized.distance(from: range.lowerBound, to: range.upperBound)
                // Strictly greater only: ties keep the earlier entry, which is already the
                // one recorded since candidates are scanned in entry order.
                if length > bestLength {
                    bestLength = length
                    bestRange = range
                    bestIndex = index
                }
            }

            if let bestIndex, let bestRange {
                let rule = rules[bestIndex]
                // The text may already read as this entry's `write` beyond the trigger's own
                // span (e.g. `next -> Next.js` seeing "Next.js"). Replacing only the trigger
                // would duplicate the rest, so the whole existing span is replaced instead:
                // idempotent, and still fixes its casing. Scanning resumes past it, so
                // nothing -- this rule or any other -- re-matches inside it.
                let already = Self.alreadyReadsAsWrite(
                    normalized, matchEnd: bestRange.upperBound, start: bestRange.lowerBound, write: rule.normalizedWrite
                )
                let replaced = already ?? bestRange
                output += rule.write
                if firstFrom[bestIndex] == nil {
                    firstFrom[bestIndex] = String(normalized[replaced])
                    firstFireOrder.append(bestIndex)
                }
                counts[bestIndex, default: 0] += 1
                cursor = replaced.upperBound
            } else {
                output.append(normalized[cursor])
                cursor = normalized.index(after: cursor)
            }
        }

        let applied = firstFireOrder.map { index in
            AppliedCorrection(
                from: firstFrom[index] ?? "",
                to: rules[index].write,
                count: counts[index] ?? 0
            )
        }
        return (output, applied)
    }

    // MARK: - Compilation

    /// Compiles every candidate, keeping the rules that compiled (in candidate order) and
    /// reporting the ones that did not, so one bad pattern never disables the rest.
    static func compile(_ candidates: [Candidate]) -> (rules: [CompiledRule], failures: [CompileFailure]) {
        var rules: [CompiledRule] = []
        var failures: [CompileFailure] = []
        for candidate in candidates {
            do {
                let regex = try NSRegularExpression(pattern: candidate.pattern, options: [.caseInsensitive])
                let normalizedWrite = candidate.write.precomposedStringWithCanonicalMapping
                rules.append(CompiledRule(regex: regex, write: candidate.write, normalizedWrite: normalizedWrite))
            } catch {
                failures.append(CompileFailure(pattern: candidate.pattern, reason: error.localizedDescription))
            }
        }
        return (rules, failures)
    }

    /// The pattern comes from the user's dictionary, so only its length is logged.
    private static func logCompileFailure(_ failure: CompileFailure) {
        #if canImport(os)
        logger.error(
            "correction rule skipped: a trigger pattern of \(failure.pattern.count, privacy: .public) chars failed to compile: \(failure.reason, privacy: .public)"
        )
        #endif
    }

    // MARK: - Trigger patterns

    /// Builds the regex pattern for a trigger, or `nil` if it has no matchable content
    /// (empty, or entirely whitespace/hyphens).
    private static func triggerPattern(for hear: String) -> String? {
        let normalized = hear.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let parts = normalized.split { $0 == " " || $0 == "\t" || $0 == "-" }
        guard !parts.isEmpty else { return nil }

        let escapedParts = parts.map { NSRegularExpression.escapedPattern(for: String($0)) }
        return escapedParts.joined(separator: "[\\s\\-]*")
    }

    // MARK: - Already-written detection

    /// If `text` already reads as `write` (case-insensitively) starting at `start`, and that
    /// occurrence reaches past `matchEnd` (the trigger's own match end) with a proper fence
    /// on its far side, returns the occurrence's range so the caller replaces all of it
    /// rather than only the trigger's part. A `write` occurrence no longer than the trigger's own match (e.g.
    /// `codex -> Codex` matching "codex") is not an already-written span -- there is nothing
    /// beyond the match that would be duplicated, so it still recases normally.
    ///
    /// The near-side fence is not re-checked here: `start` is the trigger match's own start,
    /// already fenced by `fencesAllow` before this is called.
    private static func alreadyReadsAsWrite(
        _ text: String,
        matchEnd: String.Index,
        start: String.Index,
        write: String
    ) -> Range<String.Index>? {
        guard !write.isEmpty else { return nil }
        // Search rather than slice `write.count` characters: a case fold can change the
        // length ("Straße" matches "STRASSE").
        guard let found = text.range(of: write, options: [.caseInsensitive, .anchored], range: start..<text.endIndex),
              found.upperBound > matchEnd
        else { return nil }
        let end = found.upperBound
        if end < text.endIndex, isFenceBreaker(text[end]) { return nil }
        return start..<end
    }

    // MARK: - Fencing

    private static func fencesAllow(_ text: String, _ range: Range<String.Index>) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            guard !isFenceBreaker(before) else { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            guard !isFenceBreaker(after) else { return false }
        }
        return true
    }

    /// A letter, digit, combining mark or hyphen: characters that must not sit immediately
    /// next to a match, so a trigger never fires as a prefix, suffix or interior slice of a
    /// longer word. Apostrophes (straight or curly) are punctuation, not any of these, so
    /// they are boundaries and possessives get corrected.
    private static func isFenceBreaker(_ character: Character) -> Bool {
        if character == "-" { return true }
        for scalar in character.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                continue
            }
        }
        return false
    }
}
