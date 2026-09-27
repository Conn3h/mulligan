import Foundation
import MulliganDictionary
import Testing
@testable import Mulligan

@MainActor
@Suite(.serialized)
struct HistoryLogTests {
    private static let fileName = "history.jsonl"

    /// Points the log at a fresh temporary directory for the duration of `body`.
    private func withTemporaryLog(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MulliganHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HistoryLog.directoryOverride = directory
        // `HistoryStore.shared` is a real singleton shared by the whole test process. Now
        // that a successful `record` updates it in memory instead of re-reading the file,
        // it no longer self-heals against another test's leftovers when the override
        // directory changes, so reset it to match this fresh, empty directory explicitly.
        HistoryStore.shared.replace(withFileOrder: [])
        defer {
            HistoryLog.directoryOverride = nil
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove \(directory.path): \(error)")
            }
        }
        try await body(directory)
    }

    private func makeRun(
        text: String,
        source: String = "hotkey",
        corrections: [AppliedCorrection]? = nil
    ) -> DictationRun {
        DictationRun(
            date: Date(),
            engine: "Apple",
            source: source,
            audioSeconds: 1.25,
            processSeconds: 0.05,
            text: text,
            corrections: corrections
        )
    }

    private func fileContents(in directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: Self.fileName), encoding: .utf8)
    }

    private func writeFile(_ contents: String, in directory: URL) throws {
        try contents.write(to: directory.appending(path: Self.fileName), atomically: true, encoding: .utf8)
    }

    @Test func appendThenLoadRoundTrips() async throws {
        try await withTemporaryLog { directory in
            let corrections = [AppliedCorrection(from: "cloud code", to: "Claude Code", count: 2)]
            let run = makeRun(text: "hello world", corrections: corrections)
            HistoryLog.record(run)

            let loaded = HistoryLog.load()
            #expect(loaded.count == 1)
            let first = try #require(loaded.first)
            #expect(first.id == run.id)
            #expect(abs(first.date.timeIntervalSince(run.date)) < 0.001)
            #expect(first.engine == "Apple")
            #expect(first.source == "hotkey")
            #expect(first.audioSeconds == 1.25)
            #expect(first.processSeconds == 0.05)
            #expect(first.text == "hello world")
            #expect(first.corrections == corrections)

            let contents = try fileContents(in: directory)
            #expect(contents.split(separator: "\n").count == 1)
            #expect(contents.hasSuffix("\n"))
        }
    }

    @Test func multilineTextStaysOnOneLine() async throws {
        try await withTemporaryLog { directory in
            HistoryLog.record(makeRun(text: "first line\n\nthird line"))
            HistoryLog.record(makeRun(text: "second run", source: "button"))

            let contents = try fileContents(in: directory)
            #expect(contents.filter { $0 == "\n" }.count == 2)

            let loaded = HistoryLog.load()
            #expect(loaded.map(\.text) == ["first line\n\nthird line", "second run"])
            #expect(loaded.map(\.source) == ["hotkey", "button"])
            #expect(loaded.first?.corrections == nil)
        }
    }

    @Test func missingIdIsDecodedLenientlyAndPersisted() async throws {
        try await withTemporaryLog { directory in
            let line = """
            {"date":"2026-09-01T10:00:00Z","engine":"Apple","source":"hotkey","audioSeconds":1,"processSeconds":0.1,"text":"no id here"}
            """
            try writeFile(line + "\n", in: directory)

            let loaded = HistoryLog.load()
            #expect(loaded.count == 1)
            let id = try #require(loaded.first?.id)
            #expect(loaded.first?.text == "no id here")
            #expect(loaded.first?.date == Date(timeIntervalSince1970: 1_788_256_800))

            // The minted id is written back, so it is stable across loads and rewrites.
            let afterLoad = try fileContents(in: directory)
            #expect(afterLoad.contains(id.uuidString))
            #expect(afterLoad.split(separator: "\n").count == 1)
            #expect(HistoryLog.load().map(\.id) == [id])

            HistoryLog.delete(ids: [UUID()])
            #expect(HistoryLog.load().map(\.id) == [id])
        }
    }

    @Test func undecodableLinesAreSkippedAndCounted() async throws {
        try await withTemporaryLog { directory in
            let good = makeRun(text: "kept")
            HistoryLog.record(good)
            var contents = try fileContents(in: directory)
            contents += "this is not json\n"
            contents += "{\"id\": 5}\n"
            contents += "\n"
            try writeFile(contents, in: directory)

            let report = try HistoryLog.loadReport().get()
            #expect(report.runs.map(\.id) == [good.id])
            #expect(report.skipped == 2)
            #expect(HistoryLog.load().map(\.id) == [good.id])
        }
    }

    // MARK: Read failures

    /// Takes every permission bit off the file; reads fail, but an atomic rewrite would
    /// still replace it, so a delete that did not abort leaves a visible trace.
    private func setReadable(_ readable: Bool, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: readable ? 0o644 : 0o000],
            ofItemAtPath: url.path
        )
    }

    /// For `defer`: puts the permissions back so the sandbox can be removed, recording
    /// rather than throwing if that fails.
    private func restoreReadable(at url: URL) {
        do {
            try setReadable(true, at: url)
        } catch {
            Issue.record("could not restore permissions on \(url.path): \(error)")
        }
    }

    @Test func loadReportDistinguishesAReadFailureFromAnEmptyLog() async throws {
        try await withTemporaryLog { directory in
            let fileURL = directory.appending(path: Self.fileName)
            try writeFile("", in: directory)
            #expect(try HistoryLog.loadReport().get().runs.isEmpty)

            try setReadable(false, at: fileURL)
            defer { restoreReadable(at: fileURL) }
            guard case .failure = HistoryLog.loadReport() else {
                Issue.record("an unreadable log reported success")
                return
            }
            #expect(HistoryLog.load().isEmpty)
        }
    }

    @Test func deleteAbortsWhenTheLogCannotBeRead() async throws {
        try await withTemporaryLog { directory in
            let runs = [makeRun(text: "one"), makeRun(text: "two")]
            for run in runs {
                HistoryLog.record(run)
            }
            let fileURL = directory.appending(path: Self.fileName)
            let before = try Data(contentsOf: fileURL)

            try setReadable(false, at: fileURL)
            defer { restoreReadable(at: fileURL) }
            HistoryLog.delete(ids: [runs[0].id])
            try setReadable(true, at: fileURL)

            #expect(try Data(contentsOf: fileURL) == before)
            #expect(HistoryLog.load().map(\.id) == runs.map(\.id))
            #expect(HistoryStore.shared.runs.map(\.id) == [runs[1].id, runs[0].id])
        }
    }

    @Test func clearProceedsWhenTheLogCannotBeRead() async throws {
        try await withTemporaryLog { directory in
            HistoryLog.record(makeRun(text: "one"))
            HistoryLog.record(makeRun(text: "two"))
            let fileURL = directory.appending(path: Self.fileName)

            try setReadable(false, at: fileURL)
            defer { restoreReadable(at: fileURL) }
            HistoryLog.clear()
            try setReadable(true, at: fileURL)

            #expect(try fileContents(in: directory).isEmpty)
            #expect(HistoryLog.load().isEmpty)
            #expect(HistoryStore.shared.runs.isEmpty)
        }
    }

    @Test func storeKeepsItsRunsWhenTheLogCannotBeRead() async throws {
        try await withTemporaryLog { directory in
            let first = makeRun(text: "first")
            let second = makeRun(text: "second")
            HistoryLog.record(first)
            HistoryLog.record(second)
            let fileURL = directory.appending(path: Self.fileName)

            try setReadable(false, at: fileURL)
            defer { restoreReadable(at: fileURL) }
            HistoryStore.shared.reload()

            #expect(HistoryStore.shared.runs.map(\.id) == [second.id, first.id])
        }
    }

    @Test func deleteRemovesOnlyTheGivenIds() async throws {
        try await withTemporaryLog { directory in
            let runs = [makeRun(text: "one"), makeRun(text: "two"), makeRun(text: "three")]
            for run in runs {
                HistoryLog.record(run)
            }

            HistoryLog.delete(ids: [runs[0].id, runs[2].id])

            #expect(HistoryLog.load().map(\.id) == [runs[1].id])
            let contents = try fileContents(in: directory)
            #expect(contents.split(separator: "\n").count == 1)
            #expect(HistoryStore.shared.runs.map(\.id) == [runs[1].id])
        }
    }

    @Test func clearEmptiesTheLog() async throws {
        try await withTemporaryLog { directory in
            HistoryLog.record(makeRun(text: "one"))
            HistoryLog.record(makeRun(text: "two"))

            HistoryLog.clear()

            #expect(HistoryLog.load().isEmpty)
            let contents = try fileContents(in: directory)
            #expect(contents.isEmpty)
            #expect(HistoryStore.shared.runs.isEmpty)
        }
    }

    @Test func recordReloadsTheStoreNewestFirst() async throws {
        try await withTemporaryLog { _ in
            let first = makeRun(text: "first")
            let second = makeRun(text: "second")
            HistoryLog.record(first)
            #expect(HistoryStore.shared.runs.map(\.id) == [first.id])

            HistoryLog.record(second)
            #expect(HistoryStore.shared.runs.map(\.id) == [second.id, first.id])

            HistoryStore.shared.reload()
            #expect(HistoryStore.shared.runs.map(\.id) == [second.id, first.id])
        }
    }

    @Test func loadWithoutAFileIsEmpty() async throws {
        try await withTemporaryLog { _ in
            #expect(HistoryLog.load().isEmpty)
            let report = try HistoryLog.loadReport().get()
            #expect(report.skipped == 0)
        }
    }

    @Test func recordDoesNotReReadTheWholeFile() async throws {
        try await withTemporaryLog { _ in
            _ = HistoryStore.shared          // force lazy init before measuring reads
            let before = HistoryLog.loadCount
            HistoryLog.record(makeRun(text: "first"))
            HistoryLog.record(makeRun(text: "second"))
            #expect(HistoryLog.loadCount == before)   // record no longer re-reads the file

            // load() itself reads (bumping loadCount, which is fine) and round-trips both
            // runs in append order.
            let loaded = HistoryLog.load()
            #expect(loaded.map(\.text) == ["first", "second"])
        }
    }
}
