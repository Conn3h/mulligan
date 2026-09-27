import ApplicationServices
import Testing
@testable import Sotto

/// Every safety rule of §6.16's plan as its own case. Elements are application elements for
/// made-up pids: creating one needs no permission, and `CFEqual` tells them apart.
struct ErasePlanTests {
    private let field = AXElementID(element: AXUIElementCreateApplication(101))
    private let otherField = AXElementID(element: AXUIElementCreateApplication(102))
    private let window = AXElementID(element: AXUIElementCreateApplication(201))
    private let otherWindow = AXElementID(element: AXUIElementCreateApplication(202))
    private let spoken = " Hello there."

    private func record(
        _ text: String? = nil, element: Bool = true, caretEnd: Int? = 40, epoch: UInt64 = 7
    ) -> TypedDictation {
        TypedDictation(
            text: text ?? spoken, processID: 42, element: element ? field : nil, window: window,
            caretEnd: element ? caretEnd : nil, landedAt: ContinuousClock().now,
            previousInjection: nil, inputEpoch: epoch
        )
    }

    private func caret(
        _ location: Int, preceding: String?, element: AXElementID? = nil, window: AXElementID? = nil
    ) -> ReadBack {
        .readable(
            element: element ?? field, window: window ?? self.window,
            selection: CFRange(location: location, length: 0), preceding: preceding
        )
    }

    private func decide(
        _ record: TypedDictation?, superseded: Bool = false, epoch: UInt64 = 7, pid: pid_t? = 42, _ readBack: ReadBack
    ) -> ErasePlan {
        ErasePlan.decide(record: record, superseded: superseded, epoch: epoch, frontmostPID: pid, readBack: readBack)
    }

    private var units: Int { spoken.utf16.count }

    @Test func noRecord() {
        #expect(decide(nil, .unreadable(window: nil)) == .refuse(.nothingToErase))
    }

    @Test func superseded() {
        #expect(decide(record(), superseded: true, caret(40, preceding: spoken)) == .refuse(.notTyped))
    }

    @Test func otherApp() {
        #expect(decide(record(), pid: 9, caret(40, preceding: spoken)) == .refuse(.inputSince))
    }

    @Test func unknownFrontmostApp() {
        #expect(decide(record(), pid: nil, caret(40, preceding: spoken)) == .refuse(.inputSince))
    }

    @Test func readableCaretMatch() {
        #expect(decide(record(), caret(40, preceding: spoken)) == .deleteRange(location: 40 - units, length: units))
    }

    @Test func readableSelectionOfTheInsertMatches() {
        let readBack = ReadBack.readable(
            element: field, window: window, selection: CFRange(location: 40 - units, length: units), preceding: spoken
        )
        #expect(decide(record(), readBack) == .deleteRange(location: 40 - units, length: units))
    }

    @Test func readableIgnoresTheEpoch() {
        #expect(decide(record(epoch: 1), epoch: 99, caret(40, preceding: spoken))
            == .deleteRange(location: 40 - units, length: units))
    }

    @Test func differentText() {
        #expect(decide(record(), caret(40, preceding: " Hello thera.")) == .refuse(.textChanged))
    }

    @Test func normalisationCountsAsChanged() {
        let decomposed = "Cafe\u{301}."
        let composed = "Caf\u{E9}."
        #expect(decide(record(decomposed), caret(40, preceding: composed)) == .refuse(.textChanged))
    }

    @Test func identicalTextInAnotherFieldIsNotOurs() {
        #expect(decide(record("Yes."), caret(40, preceding: "Yes.", element: otherField)) == .refuse(.inputSince))
    }

    @Test func anotherWindow() {
        #expect(decide(record(), caret(40, preceding: spoken, window: otherWindow)) == .refuse(.inputSince))
    }

    @Test func caretMoved() {
        #expect(decide(record(), caret(41, preceding: "Hello there. ")) == .refuse(.textChanged))
    }

    @Test func arbitrarySelection() {
        let readBack = ReadBack.readable(
            element: field, window: window, selection: CFRange(location: 10, length: 3), preceding: "abc"
        )
        #expect(decide(record(), readBack) == .refuse(.textChanged))
    }

    @Test func precedingOutOfBounds() {
        #expect(decide(record(), caret(40, preceding: nil)) == .refuse(.textChanged))
    }

    @Test func caretEndBeforeTheRecordLength() {
        #expect(decide(record(caretEnd: 3), caret(3, preceding: spoken)) == .refuse(.textChanged))
    }

    @Test func unreadableUntouched() {
        #expect(decide(record(element: false), .unreadable(window: window)) == .backspaces(count: spoken.count))
    }

    @Test func unreadableAfterInput() {
        #expect(decide(record(element: false), epoch: 8, .unreadable(window: window)) == .refuse(.inputSince))
    }

    @Test func unreadableOtherWindow() {
        #expect(decide(record(element: false), .unreadable(window: otherWindow)) == .refuse(.inputSince))
    }

    @Test func unreadableUnknownWindowStillErases() {
        #expect(decide(record(element: false), .unreadable(window: nil)) == .backspaces(count: spoken.count))
    }

    @Test func unreadableNewline() {
        #expect(decide(record("one\ntwo", element: false), .unreadable(window: window)) == .refuse(.tooLongToVerify))
    }

    @Test func unreadableAtAndOverTheLimit() {
        let atLimit = String(repeating: "a", count: ErasePlan.unverifiedLimit)
        #expect(decide(record(atLimit, element: false), .unreadable(window: window))
            == .backspaces(count: ErasePlan.unverifiedLimit))
        #expect(decide(record(atLimit + "a", element: false), .unreadable(window: window))
            == .refuse(.tooLongToVerify))
    }

    @Test func recordWithoutElementButReadableNowMustStillMatch() {
        #expect(decide(record(element: false), caret(40, preceding: spoken)) == .backspaces(count: spoken.count))
        #expect(decide(record(element: false), caret(40, preceding: " Goodbye now.")) == .refuse(.textChanged))
    }

    @Test func recordWithoutElementReadableNowStillNeedsAnUnchangedEpoch() {
        #expect(decide(record(element: false), epoch: 8, caret(40, preceding: spoken)) == .refuse(.inputSince))
    }

    @Test func emojiCountsCharactersForBackspacesAndUnitsForRanges() {
        let text = " ok \u{1F44D}"
        #expect(decide(record(text, element: false), .unreadable(window: window)) == .backspaces(count: 5))
        #expect(decide(record(text), caret(40, preceding: text)) == .deleteRange(location: 34, length: 6))
    }

    @Test func everyRefusalHasAMessageAndErasedHasNone() {
        #expect(EraseOutcome.erased.message == nil)
        let refusals: [EraseOutcome] = [
            .nothingToErase, .notTyped, .inputSince, .textChanged, .tooLongToVerify, .interrupted, .failed,
        ]
        for outcome in refusals {
            #expect(outcome.message?.isEmpty == false)
        }
    }
}
