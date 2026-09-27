import Foundation

/// Converts a raw dictated transcript into text ready for insertion or
/// history. Implementations are `async` so a formatter can call out to an
/// on-device model (see `FoundationModelFormatter` in the app target)
/// without forcing every caller onto a synchronous path.
public protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// The cleanup-disabled formatter. Trims leading and trailing whitespace and
/// does nothing else: no filler stripping, no spoken punctuation, no
/// capitalisation, no terminal punctuation.
public struct PassthroughFormatter: TextFormatter {
    public init() {}

    public func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
