import Foundation

/// How close a heard word must be, in spelling, before the Parakeet vocabulary rescorer may
/// swap it for a dictionary term.
///
/// The engine-wide floor (0.75) is too loose for short terms: a short term is often one
/// letter away from an ordinary word ("code" to Codex and Xcode is 0.80, "herpes" to
/// Hermes is 0.83), and the rescorer replaced the ordinary word every time it was spoken. Short
/// single-word terms therefore get a floor above what one edit costs them, so they only
/// replace a spelling that is nearly exact. A genuine near miss this now rejects belongs in
/// the dictionary as an explicit correction (`vitess -> Vitest`).
public enum BiasStrictness {
    /// Longest single-word term, in characters, that gets the stricter floor.
    public static let shortTermMaxLength = 6
    /// Above the 0.83 that one edit costs a term of `shortTermMaxLength` characters.
    public static let shortTermMinSimilarity: Float = 0.85

    /// The per-term similarity floor for `term`, or nil to use the engine-wide floor.
    public static func minimumSimilarity(for term: String) -> Float? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0 == "-" }),
              trimmed.count <= shortTermMaxLength
        else {
            return nil
        }
        return shortTermMinSimilarity
    }
}
