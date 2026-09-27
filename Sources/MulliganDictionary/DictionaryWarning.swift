import Foundation

/// A non-blocking hint shown next to a dictionary entry that is likely to misfire. Only
/// corrections can misfire; terms never produce a warning.
public struct DictionaryWarning: Identifiable, Sendable, Equatable {
    public var id: String { message }
    public let message: String

    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        guard entry.kind == .correction else { return [] }

        let trigger = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        let write = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)

        var warnings: [DictionaryWarning] = []

        if trigger.count <= 4, !trigger.contains(" "), !trigger.contains("-") {
            warnings.append(
                DictionaryWarning(
                    message: "\u{201C}\(trigger)\u{201D} is very short and will match often. "
                        + "Consider a longer phrase."
                )
            )
        }

        if write.caseInsensitiveCompare(trigger) == .orderedSame {
            warnings.append(
                DictionaryWarning(
                    message: "This rewrites \u{201C}\(trigger)\u{201D} to itself, "
                        + "so it will never change anything."
                )
            )
        }

        return warnings
    }
}
