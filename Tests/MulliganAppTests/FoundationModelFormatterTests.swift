import Foundation
import MulliganText
import Synchronization
import Testing
@testable import Mulligan

/// A `CleanupModel` the test controls: available or not, and on each call either replies,
/// throws, or stalls on a gate until the test opens it.
final class FakeCleanupModel: CleanupModel, Sendable {
    enum Behavior: Sendable {
        case reply(String)
        case fail(String)
        case stall
    }

    private struct Record: Sendable {
        var calls = 0
        var completedLate = false
        var wasCancelledWhenReleased = false
    }

    static let lateAnswer = "The capital of France is Paris."

    let isAvailable: Bool
    let unavailableReason: String?
    let gate = Gate(open: false)
    private let behavior: Behavior
    private let record = Mutex(Record())

    init(_ behavior: Behavior, isAvailable: Bool = true, unavailableReason: String? = nil) {
        self.behavior = behavior
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
    }

    var calls: Int { record.withLock { $0.calls } }
    var completedLate: Bool { record.withLock { $0.completedLate } }
    var wasCancelledWhenReleased: Bool { record.withLock { $0.wasCancelledWhenReleased } }

    func cleanup(_ transcript: String) async throws -> String {
        record.withLock { $0.calls += 1 }
        switch behavior {
        case .reply(let text):
            return text
        case .fail(let message):
            throw TestError(message)
        case .stall:
            await gate.pass()
            let cancelled = Task.isCancelled
            record.withLock { state in
                state.wasCancelledWhenReleased = cancelled
                state.completedLate = true
            }
            return Self.lateAnswer
        }
    }
}

@Suite
struct FoundationModelFormatterTests {
    private let generousTimeout: Duration = .seconds(2)

    @Test func emptyInputReturnsEmptyWithoutCallingTheModel() async {
        let model = FakeCleanupModel(.reply("Should not be used."))
        let formatter = FoundationModelFormatter(model: model, timeout: generousTimeout)
        #expect(await formatter.format("   \n ") == "")
        #expect(model.calls == 0)
    }

    @Test func unavailableModelFallsBackToRules() async {
        let model = FakeCleanupModel(
            .reply("Should not be used."),
            isAvailable: false,
            unavailableReason: "Apple Intelligence is turned off."
        )
        let formatter = FoundationModelFormatter(model: model, timeout: generousTimeout)
        #expect(await formatter.format("um, hello there") == "Hello there.")
        #expect(model.calls == 0)
    }

    @Test func throwingModelFallsBackToRules() async {
        let model = FakeCleanupModel(.fail("model exploded"))
        let formatter = FoundationModelFormatter(model: model, timeout: generousTimeout)
        #expect(await formatter.format("I think, uh, it works") == "I think, it works.")
        #expect(model.calls == 1)
    }

    @Test func answeredQuestionIsRejectedByTheGuardAndFallsBackToRules() async {
        let raw = "what is the capital of France"
        let answer = "The capital of France is Paris."
        let verdict = CleanupGuard.evaluate(original: raw, cleaned: answer)
        guard case .rejected(let reason) = verdict else {
            Issue.record("expected the guard to reject an answer, got \(verdict)")
            return
        }
        #expect(reason.hasPrefix("invented:"))

        let model = FakeCleanupModel(.reply(answer))
        let formatter = FoundationModelFormatter(model: model, timeout: generousTimeout)
        #expect(await formatter.format(raw) == "What is the capital of France.")
        #expect(model.calls == 1)
    }

    @Test func goodCleanupIsAccepted() async {
        let raw = "um so like I think we should uh ship it"
        let cleaned = "I think we should ship it."
        #expect(CleanupGuard.evaluate(original: raw, cleaned: cleaned) == .accepted)

        let model = FakeCleanupModel(.reply(cleaned))
        let formatter = FoundationModelFormatter(model: model, timeout: generousTimeout)
        #expect(await formatter.format(raw) == cleaned)
        #expect(model.calls == 1)
    }

    @Test func modelOutputIsTrimmed() async {
        let model = FakeCleanupModel(.reply("\n  I think we should ship it.  \n"))
        let formatter = FoundationModelFormatter(model: model, timeout: generousTimeout)
        #expect(await formatter.format("um so like I think we should uh ship it") == "I think we should ship it.")
    }

    @Test func stalledModelReturnsRulesWithinTheTimeout() async {
        let model = FakeCleanupModel(.stall)
        let timeout: Duration = .milliseconds(200)
        let formatter = FoundationModelFormatter(model: model, timeout: timeout)
        let clock = ContinuousClock()

        let started = clock.now
        let result = await formatter.format("hello new paragraph world")
        let elapsed = clock.now - started

        #expect(result == "Hello\n\nWorld.")
        #expect(elapsed >= timeout)
        #expect(elapsed < timeout + .milliseconds(250))
        #expect(model.calls == 1)
        #expect(!model.completedLate)

        // Release the stalled call so the abandoned task can finish.
        await model.gate.open()
    }

    @Test func lateResultOfATimedOutCallDoesNotSurface() async throws {
        let raw = "send it Tuesday actually Wednesday"
        let model = FakeCleanupModel(.stall)
        let formatter = FoundationModelFormatter(model: model, timeout: .milliseconds(200))

        let result = await formatter.format(raw)
        #expect(result == "Send it Tuesday actually Wednesday.")
        #expect(model.calls == 1)
        #expect(!model.completedLate)

        // The model answers after the formatter has already returned.
        await model.gate.open()
        try await settle("late model completion") { model.completedLate }
        #expect(model.wasCancelledWhenReleased)
        #expect(result != FakeCleanupModel.lateAnswer)

        // A later call with a fresh model is untouched by the abandoned one.
        let fresh = FakeCleanupModel(.reply("Send it Wednesday."))
        let second = FoundationModelFormatter(model: fresh, timeout: .milliseconds(200))
        #expect(await second.format(raw) == "Send it Wednesday.")
        #expect(fresh.calls == 1)
    }
}
