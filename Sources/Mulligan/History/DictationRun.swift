import Foundation
import MulliganDictionary

/// One completed dictation, as stored one-per-line in `history.jsonl`.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Decoded leniently: a line without an id gets a fresh one, which `HistoryLog` writes
    /// back in the same load so the id stays stable.
    var id: UUID
    /// `Utterance.releasedAt`.
    let date: Date
    let engine: String
    /// `"hotkey"` (typed into the focused app) or `"button"` (recorded to history only).
    let source: String
    /// Seconds the key was held.
    let audioSeconds: Double
    /// Seconds from release to the text being ready and, for hotkey runs, handed over.
    let processSeconds: Double
    let text: String
    var corrections: [AppliedCorrection]?

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        source: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        corrections: [AppliedCorrection]? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.source = source
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.corrections = corrections
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, engine, source, audioSeconds, processSeconds, text, corrections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        source = try container.decode(String.self, forKey: .source)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
    }
}
