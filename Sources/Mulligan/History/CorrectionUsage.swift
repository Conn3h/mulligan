import Foundation
import MulliganDictionary

/// How many times each dictionary entry has fired, counted from the corrections History
/// recorded (spec §6.14, Dictionary tab). A correction names only the text it replaced
/// (`from`) and the entry's `write` (`to`), so it is matched back to an entry by those.
enum CorrectionUsage {
    static func counts(entries: [DictionaryEntry], runs: [DictationRun]) -> [DictionaryEntry.ID: Int] {
        var counts: [DictionaryEntry.ID: Int] = [:]
        for run in runs {
            for correction in run.corrections ?? [] {
                guard let id = entry(for: correction, in: entries) else {
                    continue
                }
                counts[id, default: 0] += correction.count
            }
        }
        return counts
    }

    /// A correction whose replaced text starts with its `hear` (the replaced span can run
    /// past it: "next" in "next.js") wins; otherwise the term with the same `write`, then any
    /// entry with that `write`. Nil for an entry since deleted or rewritten.
    private static func entry(for correction: AppliedCorrection, in entries: [DictionaryEntry]) -> DictionaryEntry.ID? {
        let candidates = entries.filter { $0.write == correction.to }
        let from = correction.from.lowercased()
        if let fix = candidates.first(where: { $0.kind == .correction && !$0.hear.isEmpty && from.hasPrefix($0.hear.lowercased()) }) {
            return fix.id
        }
        if let term = candidates.first(where: { $0.kind == .term }) {
            return term.id
        }
        return candidates.first?.id
    }
}
