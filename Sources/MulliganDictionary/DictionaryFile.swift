import Foundation

/// Reads and writes the plain-text dictionary file a person can hand-edit.
///
/// Format, one entry per line:
/// - A bare line is a term.
/// - A line containing `->` is a correction: the text before the *first* `->` is what the
///   engine tends to hear, everything after it (including any further `->`) is what gets
///   written. There is no escaping.
/// - A line starting with `#` is an ordinary comment and is discarded, except a line of the
///   form `# off: <entry>` (case-insensitive `off:`), which parses `<entry>` exactly like a
///   normal line but produces a **disabled** entry.
/// - Blank lines are ignored.
/// - Each side of a correction is trimmed; a correction with an empty side is ignored.
///
/// Round-tripping through `parse` → `serialize` → `parse` is semantic, not literal: kind,
/// write, hear and enabled survive; ordinary comments are discarded by design; ids are not
/// persisted (each parse mints fresh ones).
public enum DictionaryFile {
    private static let arrow = "->"
    private static let offMarker = "off:"

    public static func parse(_ text: String) -> [DictionaryEntry] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parseLine(String($0)) }
    }

    public static func serialize(_ entries: [DictionaryEntry]) -> String {
        var lines = header
        for entry in entries {
            let content = contentLine(for: entry)
            lines.append(entry.isEnabled ? content : "# \(offMarker) \(content)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Parsing

    private static func parseLine(_ rawLine: String) -> DictionaryEntry? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard trimmed.hasPrefix("#") else {
            return entry(fromContent: trimmed, isEnabled: true)
        }

        let afterHash = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let disabledContent = stripOffMarker(afterHash) else {
            // An ordinary comment. Discarded by design.
            return nil
        }
        return entry(fromContent: disabledContent, isEnabled: false)
    }

    /// If `text` begins with the case-insensitive `off:` marker, returns the trimmed
    /// remainder after it. Otherwise `nil`, meaning this `#` line is an ordinary comment.
    private static func stripOffMarker(_ text: String) -> String? {
        guard text.lowercased().hasPrefix(offMarker) else { return nil }
        return String(text.dropFirst(offMarker.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func entry(fromContent content: String, isEnabled: Bool) -> DictionaryEntry? {
        guard !content.isEmpty else { return nil }

        guard let arrowRange = content.range(of: arrow) else {
            return DictionaryEntry(kind: .term, write: content, isEnabled: isEnabled)
        }

        let hear = String(content[content.startIndex..<arrowRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let write = String(content[arrowRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !hear.isEmpty, !write.isEmpty else { return nil }

        return DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabled)
    }

    // MARK: - Serializing

    private static func contentLine(for entry: DictionaryEntry) -> String {
        switch entry.kind {
        case .term:
            return entry.write
        case .correction:
            return "\(entry.hear) \(arrow) \(entry.write)"
        }
    }

    private static let header: [String] = [
        "# Mulligan dictionary",
        "#",
        "# One entry per line.",
        "#   word              a term the dictation engine should recognise",
        "#   hear -> write     a correction: rewrite \"hear\" into \"write\"",
        "#",
        "# Prefix a line with \"# off:\" to disable it without deleting it, e.g.",
        "#   # off: cloud code -> Claude Code",
        "#",
    ]
}
