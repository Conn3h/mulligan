import Foundation

/// `history.jsonl`: one JSON object per line, appended per run, rewritten whole on delete
/// or clear. Dates are ISO-8601 with fractional seconds.
@MainActor
enum HistoryLog {
    private static let fileName = "history.jsonl"
    private static let newline = Data([UInt8(ascii: "\n")])

    nonisolated private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    nonisolated private static let wholeSecondDate = Date.ISO8601FormatStyle()

    /// Tests point the log at a temporary directory.
    static var directoryOverride: URL?

    /// Full-file reads, for tests that assert `record` no longer re-reads.
    private(set) static var loadCount = 0

    static var directoryURL: URL {
        directoryOverride ?? AppSupportDirectory.url
    }

    /// App Support/Sotto/history.jsonl
    static var fileURL: URL {
        directoryURL.appending(path: fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalDate.format(date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            // Lines written before fractional seconds were used still decode.
            let style = string.contains(".") ? fractionalDate : wholeSecondDate
            return try style.parse(string)
        }
        return decoder
    }()

    // MARK: Writes

    /// Appends one line. On success, updates `HistoryStore` in memory instead of re-reading
    /// the file; on failure, reloads so the store reflects the file's actual contents.
    static func record(_ run: DictationRun) {
        // Resolve (and possibly lazily initialise) the store BEFORE the append, so a first
        // init reads the pre-append file and cannot double-count this run.
        let store = HistoryStore.shared
        do {
            let data = try encoder.encode(run)
            try AppSupportDirectory.ensureExists(directoryURL)
            try append(data + newline)
            Log.history.info(
                "recorded run \(run.id.uuidString, privacy: .public): \(run.text.count, privacy: .public) chars, source \(run.source, privacy: .public), \(run.corrections?.count ?? 0, privacy: .public) corrections"
            )
            store.prepend(run)
        } catch {
            Log.history.error(
                "record failed for run \(run.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            store.reload()
        }
    }

    /// Rewrites the file without the given runs, then reloads `HistoryStore`. Aborts, with
    /// nothing rewritten, when the file cannot be read: rewriting what an unreadable file
    /// looked like (nothing) would erase every run.
    static func delete(ids: Set<UUID>) {
        let report: LoadReport
        switch loadReport() {
        case .success(let loaded):
            report = loaded
        case .failure(let error):
            Log.history.error(
                "delete of \(ids.count, privacy: .public) runs aborted, nothing rewritten: the log could not be read (\(error.localizedDescription, privacy: .public))"
            )
            return
        }
        let remaining = report.runs.filter { !ids.contains($0.id) }
        rewriteAndRefresh(remaining, reason: "deleted \(report.runs.count - remaining.count) of \(report.runs.count)")
    }

    /// Rewrites the file empty, then reloads `HistoryStore`. Needs no read, so it proceeds
    /// even when the file cannot be read.
    static func clear() {
        rewriteAndRefresh([], reason: "cleared")
    }

    /// After a successful rewrite the file's contents are known exactly, so the store takes
    /// them directly (an atomic rewrite keeps the file's permissions, so an unreadable file
    /// stays unreadable). After a failed one the file is untouched and is read back.
    private static func rewriteAndRefresh(_ runs: [DictationRun], reason: String) {
        if rewrite(runs, reason: reason) {
            HistoryStore.shared.replace(withFileOrder: runs)
        } else {
            HistoryStore.shared.reload()
        }
    }

    // MARK: Reads

    /// The runs in file order. Undecodable lines are skipped and counted in the log; an
    /// unreadable file (already logged by `loadReport`) reads as empty here, so callers
    /// that must tell the two apart use `loadReport` directly.
    static func load() -> [DictationRun] {
        switch loadReport() {
        case .success(let report):
            return report.runs
        case .failure:
            return []
        }
    }

    /// What one read of the file produced: the runs in file order plus how many lines
    /// could not be decoded. Blank lines are neither runs nor skips.
    struct LoadReport: Sendable {
        let runs: [DictationRun]
        let skipped: Int
    }

    /// A decoded line plus whether it carried an id. A run without one gets a fresh id, and
    /// the file is rewritten right away so the id stays stable across loads (otherwise a
    /// later `delete(ids:)`, which re-reads the file, could never match it).
    private struct StoredRun: Decodable {
        private enum IDKey: String, CodingKey {
            case id
        }

        let run: DictationRun
        let hadID: Bool

        init(from decoder: any Decoder) throws {
            run = try DictationRun(from: decoder)
            hadID = try decoder.container(keyedBy: IDKey.self).contains(.id)
        }
    }

    /// `.failure` only when the file exists but could not be read (logged here); a missing
    /// file is an empty success, and undecodable lines are counted, not failures.
    static func loadReport() -> Result<LoadReport, any Error> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .success(LoadReport(runs: [], skipped: 0))
        }
        loadCount += 1
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.history.error("history read failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }

        var runs: [DictationRun] = []
        var skipped = 0
        var minted = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !isBlank(line) {
            do {
                let stored = try decoder.decode(StoredRun.self, from: Data(line))
                runs.append(stored.run)
                if !stored.hadID {
                    minted += 1
                }
            } catch {
                skipped += 1
                Log.history.debug("history line skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        if skipped > 0 {
            Log.history.error(
                "history load skipped \(skipped, privacy: .public) undecodable lines; \(runs.count, privacy: .public) runs loaded"
            )
        }
        if minted > 0 {
            // A failed write here is logged; the runs still load, with ids that will not
            // survive to the next load.
            _ = rewrite(runs, reason: "assigned \(minted) missing ids")
        }
        return .success(LoadReport(runs: runs, skipped: skipped))
    }

    private static func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
    }

    // MARK: File access

    private static func append(_ data: Data) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    /// True when the file now holds exactly `runs`; false (logged) leaves it untouched.
    private static func rewrite(_ runs: [DictationRun], reason: String) -> Bool {
        do {
            var data = Data()
            for run in runs {
                data.append(try encoder.encode(run))
                data.append(newline)
            }
            try AppSupportDirectory.ensureExists(directoryURL)
            try data.write(to: fileURL, options: .atomic)
            Log.history.info("history rewritten (\(reason, privacy: .public)): \(runs.count, privacy: .public) runs kept")
            return true
        } catch {
            Log.history.error(
                "history rewrite failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
