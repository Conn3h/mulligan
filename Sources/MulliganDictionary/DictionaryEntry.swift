import Foundation

/// One row of the user's personal dictionary: either a bare term the engine should
/// recognise, or a correction that rewrites what it heard into what it should have
/// written. See `docs/SPEC.md` section 6.11 for the full contract.
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case term
        case correction
    }

    public var id: UUID
    public var kind: Kind

    /// The correct text. For `.term` this is the term itself; for `.correction` this is
    /// what gets written when `hear` is matched.
    public var write: String

    /// `.correction` only: the phrase the engine tends to mishear.
    public var hear: String

    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        write: String,
        hear: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    public static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    public static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }
}
