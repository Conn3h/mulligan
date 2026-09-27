import Foundation
import Testing
@testable import MulliganDictionary

// `vectors.json` is the oracle for `DictionaryCorrector` matching behaviour. It is authored
// by the orchestrator and must not be edited here. If a vector appears to contradict the
// spec, the implementation follows the spec and the vector is left failing, explained in
// the milestone report -- it is not special-cased.

private struct VectorEntry: Decodable {
    let kind: String
    let write: String
    let hear: String?
    let enabled: Bool?
}

private struct VectorApplied: Decodable {
    let from: String
    let to: String
    let count: Int
}

private struct Vector: Decodable {
    let name: String
    let entries: [VectorEntry]
    let input: String
    let expected: String
    let applied: [VectorApplied]
}

@Suite("Dictionary vectors (oracle)")
struct VectorTests {
    private static func loadVectors() throws -> [Vector] {
        let url = try #require(
            Bundle.module.url(forResource: "vectors", withExtension: "json"),
            "vectors.json must be a bundled resource of MulliganDictionaryTests"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Vector].self, from: data)
    }

    @Test func allVectorsProduceExpectedOutputAndAppliedList() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.isEmpty)

        for vector in vectors {
            let entries = vector.entries.map { raw in
                DictionaryEntry(
                    kind: raw.kind == "term" ? .term : .correction,
                    write: raw.write,
                    hear: raw.hear ?? "",
                    isEnabled: raw.enabled ?? true
                )
            }
            let corrector = DictionaryCorrector(entries: entries)
            let result = corrector.apply(to: vector.input)

            #expect(result.text == vector.expected, "vector \"\(vector.name)\": unexpected output text")

            let expectedApplied = vector.applied.map {
                AppliedCorrection(from: $0.from, to: $0.to, count: $0.count)
            }
            #expect(
                result.applied == expectedApplied,
                "vector \"\(vector.name)\": unexpected applied list"
            )
        }
    }
}
