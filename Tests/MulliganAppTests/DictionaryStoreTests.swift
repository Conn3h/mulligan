import Foundation
import MulliganDictionary
import Testing
@testable import Mulligan

@MainActor
@Suite(.serialized)
struct DictionaryStoreTests {
    private struct Sandbox {
        let directory: URL
        var fileURL: URL { directory.appending(path: "dictionary.txt") }

        func read() throws -> String {
            try String(contentsOf: fileURL, encoding: .utf8)
        }

        func write(_ contents: String) throws {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        func modificationDate() throws -> Date {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return try #require(attributes[.modificationDate] as? Date)
        }

        func setModificationDate(_ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        }
    }

    private func withSandbox(_ body: (Sandbox) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MulliganDictionaryStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove \(directory.path): \(error)")
            }
        }
        try body(Sandbox(directory: directory))
    }

    /// The persisted shape of an entry: everything but the id.
    private func shape(_ entries: [DictionaryEntry]) -> [String] {
        entries.map { "\($0.kind.rawValue)|\($0.hear)|\($0.write)|\($0.isEnabled)" }
    }

    @Test func initWithoutAFileStartsEmptyAndCreatesTheFile() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            #expect(store.entries.isEmpty)
            #expect(store.revision == 0)
            #expect(FileManager.default.fileExists(atPath: sandbox.fileURL.path))
            let contents = try sandbox.read()
            #expect(DictionaryFile.parse(contents).isEmpty)
        }
    }

    @Test func addPersistsAndReloads() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("Mulligan"))
            store.add(.correction(hear: "cloud code", write: "Claude Code"))
            #expect(store.revision == 2)
            #expect(shape(store.entries) == ["term||Mulligan|true", "correction|cloud code|Claude Code|true"])

            let again = DictionaryStore(fileURL: sandbox.fileURL)
            #expect(shape(again.entries) == shape(store.entries))
        }
    }

    @Test func updatePersists() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.correction(hear: "cloud code", write: "cloud code"))
            var entry = try #require(store.entries.first)
            entry.write = "Claude Code"
            entry.isEnabled = false

            store.update(entry)
            #expect(store.revision == 2)
            #expect(store.entries.first?.id == entry.id)
            #expect(shape(store.entries) == ["correction|cloud code|Claude Code|false"])

            let again = DictionaryStore(fileURL: sandbox.fileURL)
            #expect(shape(again.entries) == ["correction|cloud code|Claude Code|false"])
        }
    }

    @Test func deleteByIdAndByIdsPersist() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("one"))
            store.add(.term("two"))
            store.add(.term("three"))
            store.add(.term("four"))
            let ids = store.entries.map(\.id)

            store.delete(id: ids[0])
            #expect(store.entries.map(\.write) == ["two", "three", "four"])
            #expect(store.revision == 5)

            store.delete(ids: [ids[1], ids[3]])
            #expect(store.entries.map(\.write) == ["three"])
            #expect(store.revision == 6)

            let again = DictionaryStore(fileURL: sandbox.fileURL)
            #expect(again.entries.map(\.write) == ["three"])
        }
    }

    /// Only the observable state is asserted here; the store logs each ignored call, but
    /// that log line is not captured.
    @Test func unknownIdsLeaveEntriesAndRevisionUntouched() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("one"))
            let revision = store.revision
            let fileBefore = try sandbox.read()

            store.update(.term("stranger"))
            store.delete(id: UUID())
            store.delete(ids: [UUID(), UUID()])

            #expect(store.revision == revision)
            #expect(store.entries.map(\.write) == ["one"])
            #expect(try sandbox.read() == fileBefore)
        }
    }

    @Test func unrepresentableEntriesAreRefused() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            let revision = store.revision
            let fileBefore = try sandbox.read()

            store.add(.term("#tag"))
            store.add(.term("a -> b"))
            store.add(.term("   "))
            store.add(.correction(hear: " ", write: "Mulligan"))
            var broken = try #require(store.entries.first)
            broken.write = "# not a comment"
            store.update(broken)

            #expect(store.entries.map(\.write) == ["alpha"])
            #expect(store.revision == revision)
            #expect(try sandbox.read() == fileBefore)
        }
    }

    // MARK: Read failures

    /// Bytes `String(contentsOf:encoding: .utf8)` refuses, so a read fails deterministically.
    private static let unreadableBytes = Data([0xFF, 0xFE, 0x80, 0x81])

    @Test func initialReadFailureRefusesEditsUntilAReloadSucceeds() throws {
        try withSandbox { sandbox in
            try Self.unreadableBytes.write(to: sandbox.fileURL)
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            #expect(store.loadFailed)
            #expect(store.entries.isEmpty)

            store.add(.term("newcomer"))
            #expect(store.entries.isEmpty)
            #expect(store.revision == 0)
            #expect(try Data(contentsOf: sandbox.fileURL) == Self.unreadableBytes)

            try sandbox.write("alpha\n")
            store.reloadFromDisk()
            #expect(!store.loadFailed)
            #expect(store.entries.map(\.write) == ["alpha"])
            #expect(store.revision == 1)

            store.add(.term("newcomer"))
            #expect(store.entries.map(\.write) == ["alpha", "newcomer"])
            #expect(store.revision == 2)
            #expect(DictionaryFile.parse(try sandbox.read()).map(\.write) == ["alpha", "newcomer"])
        }
    }

    @Test func reloadReadFailureRefusesEditsUntilAReloadSucceeds() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            store.add(.term("beta"))
            let ids = store.entries.map(\.id)

            // A different size, so the stamp moves and the reload has to read.
            try Self.unreadableBytes.write(to: sandbox.fileURL)
            store.reloadFromDisk()
            #expect(store.loadFailed)
            #expect(store.entries.map(\.write) == ["alpha", "beta"])
            let revision = store.revision

            store.add(.term("gamma"))
            var edited = store.entries[0]
            edited.write = "ALPHA"
            store.update(edited)
            store.delete(id: ids[0])
            store.delete(ids: Set(ids))
            #expect(store.entries.map(\.write) == ["alpha", "beta"])
            #expect(store.revision == revision)
            #expect(try Data(contentsOf: sandbox.fileURL) == Self.unreadableBytes)

            try sandbox.write("alpha\nbeta\ngamma\n")
            store.reloadFromDisk()
            #expect(!store.loadFailed)
            #expect(store.entries.map(\.write) == ["alpha", "beta", "gamma"])
            #expect(store.entries[0].id == ids[0])

            store.delete(id: ids[0])
            #expect(DictionaryFile.parse(try sandbox.read()).map(\.write) == ["beta", "gamma"])
        }
    }

    @Test func reloadPreservesIdsForUnchangedTriplesAndMintsFreshOnesForNewLines() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            store.add(.correction(hear: "bee", write: "Bee"))
            let alphaID = store.entries[0].id
            let beeID = store.entries[1].id
            let revision = store.revision

            try sandbox.write("alpha\nbee -> Bee\ngamma\n")
            store.reloadFromDisk()

            #expect(store.revision == revision + 1)
            #expect(shape(store.entries) == ["term||alpha|true", "correction|bee|Bee|true", "term||gamma|true"])
            #expect(store.entries[0].id == alphaID)
            #expect(store.entries[1].id == beeID)
            #expect(store.entries[2].id != alphaID)
            #expect(store.entries[2].id != beeID)
        }
    }

    @Test func reloadOfAReorderedFileKeepsIds() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            store.add(.term("beta"))
            let alphaID = store.entries[0].id
            let betaID = store.entries[1].id
            let revision = store.revision

            try sandbox.write("beta\nalpha\n")
            store.reloadFromDisk()

            #expect(store.revision == revision + 1)
            #expect(store.entries.map(\.write) == ["beta", "alpha"])
            #expect(store.entries.map(\.id) == [betaID, alphaID])
        }
    }

    @Test func duplicateLinesGetDistinctIds() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            let alphaID = store.entries[0].id

            try sandbox.write("alpha\nalpha\n")
            store.reloadFromDisk()

            #expect(store.entries.count == 2)
            #expect(store.entries[0].id == alphaID)
            #expect(store.entries[1].id != alphaID)
        }
    }

    @Test func disablingALineInTheFilePreservesTheId() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.correction(hear: "cloud code", write: "Claude Code"))
            let id = store.entries[0].id
            let revision = store.revision

            try sandbox.write("# off: cloud code -> Claude Code\n")
            store.reloadFromDisk()

            #expect(store.revision == revision + 1)
            #expect(store.entries.map(\.id) == [id])
            #expect(store.entries[0].isEnabled == false)
        }
    }

    @Test func reloadWithIdenticalEntriesDoesNotBumpRevision() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            let revision = store.revision
            let ids = store.entries.map(\.id)
            let reads = store.diskReadCount

            // Same entries, different bytes: the file is re-read but nothing changes.
            let contents = try sandbox.read()
            try sandbox.write(contents + "# just a comment\n")
            store.reloadFromDisk()

            #expect(store.diskReadCount == reads + 1)
            #expect(store.revision == revision)
            #expect(store.entries.map(\.id) == ids)
        }
    }

    @Test func reloadSkipsWhenSizeAndModificationDateAreUnchanged() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            let revision = store.revision
            let reads = store.diskReadCount

            // Nothing touched the file since the save: no read at all.
            store.reloadFromDisk()
            store.reloadFromDisk()
            #expect(store.diskReadCount == reads)
            #expect(store.revision == revision)

            // Same size and the same modification date look untouched, so the edit is
            // not picked up until the date moves.
            let savedDate = try sandbox.modificationDate()
            let edited = try sandbox.read().replacingOccurrences(of: "alpha", with: "gamma")
            try sandbox.write(edited)
            try sandbox.setModificationDate(savedDate)
            store.reloadFromDisk()
            #expect(store.diskReadCount == reads)
            #expect(store.entries.map(\.write) == ["alpha"])

            try sandbox.setModificationDate(savedDate.addingTimeInterval(2))
            store.reloadFromDisk()
            #expect(store.diskReadCount == reads + 1)
            #expect(store.entries.map(\.write) == ["gamma"])
            #expect(store.revision == revision + 1)
        }
    }

    @Test func reloadWhenTheFileIsMissingKeepsEntries() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("alpha"))
            let revision = store.revision

            try FileManager.default.removeItem(at: sandbox.fileURL)
            store.reloadFromDisk()

            #expect(store.entries.map(\.write) == ["alpha"])
            #expect(store.revision == revision)
        }
    }

    @Test func filteredMatchesEitherSideCaseInsensitively() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.term("Mulligan"))
            store.add(.correction(hear: "cloud code", write: "Claude Code"))

            #expect(store.filtered(by: "").map(\.write) == ["Mulligan", "Claude Code"])
            #expect(store.filtered(by: "   ").map(\.write) == ["Mulligan", "Claude Code"])
            #expect(store.filtered(by: "CLOUD").map(\.write) == ["Claude Code"])
            #expect(store.filtered(by: "claude").map(\.write) == ["Claude Code"])
            #expect(store.filtered(by: "mull").map(\.write) == ["Mulligan"])
            #expect(store.filtered(by: "zzz").isEmpty)
        }
    }

    @Test func correctorAndBiasPhrasesFollowEntries() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            #expect(store.corrector.isEmpty)
            #expect(store.biasPhrases.isEmpty)

            store.add(.term("Mulligan"))
            store.add(.correction(hear: "cloud code", write: "Claude Code"))
            store.add(.correction(hear: "old", write: "new", isEnabledForTest: false))

            #expect(store.corrector.apply(to: "open cloud code").text == "open Claude Code")
            #expect(store.corrector.apply(to: "old").text == "old")
            #expect(store.biasPhrases == ["Mulligan", "Claude Code"])
        }
    }

    @Test func correctorIsRebuiltOnlyWhenEntriesChange() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.correction(hear: "cloud code", write: "Claude Code"))
            let baseline = store.correctorBuildCount
            _ = store.corrector
            _ = store.corrector
            #expect(store.correctorBuildCount == baseline + 1)

            store.add(.correction(hear: "vs code", write: "VS Code"))
            _ = store.corrector
            #expect(store.correctorBuildCount == baseline + 2)
        }
    }
}

private extension DictionaryEntry {
    static func correction(hear: String, write: String, isEnabledForTest: Bool) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabledForTest)
    }
}
