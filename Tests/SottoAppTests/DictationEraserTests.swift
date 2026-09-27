import ApplicationServices
import Testing
@testable import Sotto

// MARK: - Fakes

/// A target field with a selection and a character count that an AX delete or a backspace
/// changes the way a real text field would, when told to.
@MainActor
final class FakeEraseTarget: EraseTarget {
    var frontmost: pid_t? = 42
    var read: ReadBack = .unreadable(window: nil)
    var selectSucceeds = true
    /// Whether the field says its selection can be set at all (AXUIElementIsAttributeSettable).
    var selectSettable = true
    /// The select call reports failure but the app applies it anyway, a moment later (the
    /// ChatGPT app, 2026-09-27): the selection shows up on the next `selection(in:)` query.
    var selectLandsLate = false
    private var lateSelection: CFRange?
    /// Each backspace deletes back to the previous space, as Option-Delete would.
    var backspaceDeletesWord = false
    /// Whether an AX write of "" deletes the selection (Chrome and Electron often ignore it).
    var deleteApplies = true
    var currentSelection: CFRange?
    var count: Int? = 100
    /// The erase modifier reads as physically down until this instant.
    var eraseKeyDownUntil: ContinuousClock.Instant?
    var onDelete: (() -> Void)?
    /// Called after each `postBackspaces`, with how many calls have happened.
    var onPost: ((Int) -> Void)?
    /// When set, `postBackspaces` manages at most this many per call (event creation failed).
    var postLimit: Int?
    /// When set, the fake is a real text field (ASCII only): reads, AX deletes and backspaces
    /// all act on this text and `currentSelection`.
    var field: String?
    var fieldElement: AXElementID?
    var fieldWindow: AXElementID?

    private(set) var selects: [CFRange] = []
    private(set) var deletes = 0
    private(set) var posted: [Int] = []
    private(set) var postedAt: [ContinuousClock.Instant] = []

    func frontmostProcessID() -> pid_t? { frontmost }

    /// Called on each `readBack`, with how many reads have happened.
    var onReadBack: ((Int) -> Void)?
    private var reads = 0

    /// The configured read, with the live selection when the field is readable.
    func readBack(utf16Length: Int) -> ReadBack {
        reads += 1
        onReadBack?(reads)
        if let field, let fieldElement, let selection = currentSelection {
            let text = field as NSString
            let end = selection.location + selection.length
            let preceding = end >= utf16Length && end <= text.length
                ? text.substring(with: NSRange(location: end - utf16Length, length: utf16Length)) : nil
            return .readable(element: fieldElement, window: fieldWindow, selection: selection, preceding: preceding)
        }
        if case let .readable(element, window, _, preceding) = read, let currentSelection {
            return .readable(element: element, window: window, selection: currentSelection, preceding: preceding)
        }
        return read
    }

    func canSelect(in element: AXElementID) -> Bool { selectSettable }

    func select(_ range: CFRange, in element: AXElementID) -> Bool {
        selects.append(range)
        if selectSucceeds {
            currentSelection = range
        } else if selectLandsLate {
            lateSelection = range
        }
        return selectSucceeds
    }

    func deleteSelection(in element: AXElementID) -> Bool {
        deletes += 1
        if deleteApplies {
            if field != nil, let selection = currentSelection, selection.length > 0 {
                backspaceInField()
            } else {
                collapseSelection()
            }
        }
        onDelete?()
        return true
    }

    func selection(in element: AXElementID) -> CFRange? {
        if let lateSelection {
            currentSelection = lateSelection
            self.lateSelection = nil
        }
        return currentSelection
    }

    func characterCount(in element: AXElementID) -> Int? {
        if let field {
            return (field as NSString).length
        }
        return count
    }

    func postBackspaces(_ count: Int) -> Int {
        let managed = min(count, postLimit ?? count)
        posted.append(managed)
        postedAt.append(ContinuousClock().now)
        if field != nil {
            for _ in 0..<managed {
                backspaceInField()
            }
        } else if managed > 0 {
            collapseSelection()
        }
        onPost?(posted.count)
        return managed
    }

    /// One backspace in the modelled field: deletes the selection, or the character before
    /// the caret.
    private func backspaceInField() {
        guard let text = field.map({ $0 as NSString }), let selection = currentSelection else {
            return
        }
        var range = selection.length > 0
            ? NSRange(location: selection.location, length: selection.length)
            : NSRange(location: selection.location - 1, length: selection.location > 0 ? 1 : 0)
        if selection.length == 0, backspaceDeletesWord {
            let before = text.substring(to: selection.location).trimmingCharacters(in: .init(charactersIn: " "))
            let start = (before as NSString).range(of: " ", options: .backwards).location
            let wordStart = start == NSNotFound ? 0 : start
            range = NSRange(location: wordStart, length: selection.location - wordStart)
        }
        field = text.replacingCharacters(in: range, with: "")
        currentSelection = CFRange(location: range.location, length: 0)
    }

    func isKeyDown(_ keyCode: Int64) -> Bool {
        guard let until = eraseKeyDownUntil else {
            return false
        }
        return ContinuousClock().now < until
    }

    private func collapseSelection() {
        guard let selection = currentSelection, selection.length > 0 else {
            return
        }
        currentSelection = CFRange(location: selection.location, length: 0)
        count = count.map { $0 - selection.length }
    }
}

@MainActor
final class FakeInputMonitor: InputMonitoring {
    var startResult = true
    private var onInput: (@MainActor () -> Void)?

    func start(onInput: @escaping @MainActor () -> Void) -> Bool {
        self.onInput = onInput
        return startResult
    }

    func fire() {
        onInput?()
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct DictationEraserTests {
    private let field = AXElementID(element: AXUIElementCreateApplication(101))
    private let window = AXElementID(element: AXUIElementCreateApplication(201))
    private let spoken = " Hello there."

    private final class Spy {
        var restored: [LastInjectionSnapshot?] = []
    }

    private func makeEraser(
        _ target: FakeEraseTarget = FakeEraseTarget(), monitor: FakeInputMonitor = FakeInputMonitor()
    ) -> (DictationEraser, FakeEraseTarget, FakeInputMonitor, Spy) {
        let spy = Spy()
        // An unreadable target still names the recorded window, as terminals do.
        if case .unreadable(window: nil) = target.read {
            target.read = .unreadable(window: window)
        }
        let eraser = DictationEraser(
            target: target, monitor: monitor,
            eraseKey: { .rightCommand },
            restoreInjection: { spy.restored.append($0) }
        )
        eraser.start()
        return (eraser, target, monitor, spy)
    }

    private func typed(
        _ text: String? = nil, readable: Bool, eraser: DictationEraser, previous: LastInjectionSnapshot? = nil
    ) -> TypedDictation {
        let typed = TypedDictation(
            text: text ?? spoken, processID: 42, element: readable ? field : nil, window: window,
            caretEnd: readable ? 40 : nil, landedAt: ContinuousClock().now,
            previousInjection: previous, inputEpoch: eraser.inputEpoch, generation: eraser.deliveryGeneration
        )
        eraser.recordTyped(typed)
        return typed
    }

    /// Sets the fake target up to read back exactly what was typed, caret at the end.
    private func readsBack(_ target: FakeEraseTarget, _ text: String? = nil) {
        target.read = .readable(
            element: field, window: window, selection: CFRange(location: 40, length: 0), preceding: text ?? spoken
        )
        target.currentSelection = CFRange(location: 40, length: 0)
    }

    private func pause(_ duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            Issue.record("pause cancelled")
        }
    }

    // MARK: Record

    @Test func aLandingRecordsAndAnAttemptClearsIt() async {
        let (eraser, target, _, _) = makeEraser()
        _ = typed(readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(target.posted.reduce(0, +) == spoken.count)
        #expect(await eraser.eraseLast(token: EraseToken()) == .nothingToErase)
    }

    @Test func aRefusalClearsTheRecordToo() async {
        let (eraser, target, _, _) = makeEraser()
        _ = typed(readable: false, eraser: eraser)
        target.frontmost = 9
        #expect(await eraser.eraseLast(token: EraseToken()) == .inputSince)
        target.frontmost = 42
        #expect(await eraser.eraseLast(token: EraseToken()) == .nothingToErase)
    }

    @Test func inputBumpsTheEpoch() {
        let (eraser, _, monitor, _) = makeEraser()
        let before = eraser.inputEpoch
        monitor.fire()
        #expect(eraser.inputEpoch == before + 1)
    }

    @Test func supersedeRefusesWithNotTyped() async {
        let (eraser, target, _, _) = makeEraser()
        _ = typed(readable: false, eraser: eraser)
        eraser.supersede()
        #expect(await eraser.eraseLast(token: EraseToken()) == .notTyped)
        #expect(target.posted.isEmpty)
    }

    @Test func aNewRecordAfterSupersedeIsErasable() async {
        let (eraser, _, _, _) = makeEraser()
        eraser.supersede()
        _ = typed(readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
    }

    @Test func withoutAMonitorTheUnreadablePathFailsClosed() async {
        let monitor = FakeInputMonitor()
        monitor.startResult = false
        let (eraser, target, _, _) = makeEraser(monitor: monitor)
        _ = typed(readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .inputSince)
        #expect(target.posted.isEmpty)
    }

    @Test func withoutAMonitorAReadableTargetStillErases() async {
        let monitor = FakeInputMonitor()
        monitor.startResult = false
        let (eraser, target, _, _) = makeEraser(monitor: monitor)
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
    }

    // MARK: Readable

    @Test func deleteRangeUsesAccessibilityFirst() async {
        let (eraser, target, _, _) = makeEraser()
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        let units = spoken.utf16.count
        #expect(target.selects.map(\.location) == [40 - units])
        #expect(target.selects.map(\.length) == [units])
        #expect(target.deletes == 1)
        #expect(target.posted.isEmpty)
        #expect(target.count == 100 - units)
    }

    @Test func deleteRangeFallsBackToOneBackspaceOnlyWhileTheSelectionIsExact() async {
        let (eraser, target, _, _) = makeEraser()
        target.deleteApplies = false
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(target.posted == [1])
    }

    /// A field that says it can select but never applies the selection may still apply it
    /// later, mid-run, where a backspace would delete it and more: refuse (Codex, round 4).
    @Test func aSelectableFieldThatNeverTakesTheSelectionRefuses() async {
        let (eraser, target, _, _) = makeEraser()
        target.selectSucceeds = false
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.deletes == 0)
        #expect(target.posted.isEmpty)
    }

    /// A field that cannot select falls back to checked backspaces; one that does not show
    /// them landing (this static fake) stops after the first.
    @Test func checkedBackspacesThatDoNotShowUpStopAfterOne() async {
        let (eraser, target, _, _) = makeEraser()
        target.selectSettable = false
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.deletes == 0)
        #expect(target.posted == [1])
    }

    /// Text shifts during the late-selection wait: the landed range now covers other text.
    @Test func aLateSelectionOverShiftedTextIsNotDeleted() async {
        let (eraser, target, _, _) = makeEraser()
        unselectableField(eraser, target)
        target.selectSettable = true
        target.selectLandsLate = true
        // Reads: plan, re-plan, then the check right before the delete.
        target.onReadBack = { reads in
            if reads == 3, let text = target.field {
                target.field = "X" + text
            }
        }
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.deletes == 0)
        #expect(target.field == "X" + older + latest)
    }

    @Test func deleteRangeNeverFallsBackToCountedBackspaces() async {
        let (eraser, target, _, _) = makeEraser()
        target.deleteApplies = false
        target.onDelete = { target.currentSelection = CFRange(location: 3, length: 0) }
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func aReadableMismatchTouchesNothing() async {
        let (eraser, target, _, spy) = makeEraser()
        readsBack(target, " Hello thera.")
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .textChanged)
        #expect(target.selects.isEmpty)
        #expect(target.posted.isEmpty)
        #expect(spy.restored.isEmpty)
    }

    // MARK: Unreadable

    @Test func backspacesArePostedInChunks() async {
        let (eraser, target, _, _) = makeEraser()
        _ = typed(String(repeating: "a", count: 25), readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(target.posted == [10, 10, 5])
    }

    @Test func backspacesStopWhenInputArrivesMidRun() async {
        let (eraser, target, monitor, _) = makeEraser()
        target.onPost = { calls in
            if calls == 2 {
                monitor.fire()
            }
        }
        _ = typed(String(repeating: "a", count: 35), readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [10, 10])
    }

    @Test func backspacesStopWhenTheAppChangesMidRun() async {
        let (eraser, target, _, _) = makeEraser()
        target.onPost = { _ in target.frontmost = 9 }
        _ = typed(String(repeating: "a", count: 35), readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [10])
    }

    // MARK: Token, timing and restore

    @Test func aRevokedTokenStopsBeforeTheNextSideEffect() async {
        let (eraser, target, _, _) = makeEraser()
        target.eraseKeyDownUntil = ContinuousClock().now + .seconds(10)
        _ = typed(readable: false, eraser: eraser)
        let token = EraseToken()
        let erase = Task { @MainActor in await eraser.eraseLast(token: token) }
        await pause(.milliseconds(40))
        token.revoke()
        #expect(await erase.value == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func keysWaitForTheEraseModifierToComeUp() async {
        let (eraser, target, _, _) = makeEraser()
        let up = ContinuousClock().now + .milliseconds(60)
        target.eraseKeyDownUntil = up
        _ = typed(readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(target.postedAt.first.map { $0 >= up } == true)
    }

    @Test func erasedRestoresTheRunOnState() async {
        let (eraser, _, _, spy) = makeEraser()
        let previous = LastInjectionSnapshot(bundleID: "com.example", at: ContinuousClock().now, endedInWhitespace: true)
        _ = typed(readable: false, eraser: eraser, previous: previous)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(spy.restored == [previous])
    }

    @Test func anEraseQueuedBehindAPasteWaitsForItsSettle() async {
        let (eraser, target, _, _) = makeEraser()
        _ = typed(readable: false, eraser: eraser)
        let settleGate = Gate(open: false)
        _ = await MutationLane.run { () -> (Int, Task<Void, Never>?) in
            (0, Task { @MainActor in await settleGate.pass() })
        }
        let erase = Task { @MainActor in await eraser.eraseLast(token: EraseToken()) }
        await settleGate.waitForArrival()
        await pause(.milliseconds(30))
        #expect(target.posted.isEmpty)
        await settleGate.open()
        #expect(await erase.value == .erased)
    }

    // MARK: Review fixes (Codex, 2026-09-27)

    @Test func theTargetIsReadAgainAfterWaitingForTheModifier() async {
        let (eraser, target, _, _) = makeEraser()
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        target.eraseKeyDownUntil = ContinuousClock().now + .milliseconds(80)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            target.currentSelection = CFRange(location: 12, length: 0)  // the user clicked elsewhere
        }
        #expect(await eraser.eraseLast(token: EraseToken()) == .textChanged)
        #expect(target.selects.isEmpty)
        #expect(target.posted.isEmpty)
    }

    @Test func inputDuringTheModifierWaitRefusesTheUnreadablePath() async {
        let (eraser, target, monitor, _) = makeEraser()
        _ = typed(readable: false, eraser: eraser)
        target.eraseKeyDownUntil = ContinuousClock().now + .milliseconds(80)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            monitor.fire()
        }
        #expect(await eraser.eraseLast(token: EraseToken()) == .inputSince)
        #expect(target.posted.isEmpty)
    }

    @Test func aModifierThatStaysDownFailsWithoutPosting() async {
        let (eraser, target, _, _) = makeEraser()
        target.eraseKeyDownUntil = ContinuousClock().now + .seconds(30)
        _ = typed(readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func theFallbackBackspaceRefusesWhenFocusMoved() async {
        let (eraser, target, _, _) = makeEraser()
        let other = AXElementID(element: AXUIElementCreateApplication(103))
        target.deleteApplies = false
        readsBack(target)
        target.onDelete = {
            target.read = .readable(
                element: other, window: nil, selection: CFRange(location: 5, length: 0), preceding: nil
            )
        }
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func theFallbackBackspaceRefusesAfterInput() async {
        let (eraser, target, monitor, _) = makeEraser()
        target.deleteApplies = false
        readsBack(target)
        target.onDelete = { monitor.fire() }
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func theFallbackBackspaceRefusesWhenAnotherAppIsInFront() async {
        let (eraser, target, _, _) = makeEraser()
        target.deleteApplies = false
        readsBack(target)
        target.onDelete = { target.frontmost = 9 }
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func backspacesThatCouldNotBePostedAreNotReportedAsErased() async {
        let (eraser, target, _, _) = makeEraser()
        target.postLimit = 4
        _ = typed(String(repeating: "a", count: 25), readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [4])
    }

    @Test func noBackspacePostedAtAllIsAFailure() async {
        let (eraser, target, _, _) = makeEraser()
        target.postLimit = 0
        _ = typed(readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
    }

    @Test func anOlderLandingAfterANewDeliveryStaysSuperseded() async {
        let (eraser, target, _, _) = makeEraser()
        let olderGeneration = eraser.deliveryGeneration
        eraser.supersede()  // the newer delivery starts
        eraser.recordTyped(TypedDictation(
            text: spoken, processID: 42, element: nil, window: window, caretEnd: nil,
            landedAt: ContinuousClock().now, previousInjection: nil, inputEpoch: eraser.inputEpoch,
            generation: olderGeneration
        ))  // the older paste's settle lands late
        #expect(await eraser.eraseLast(token: EraseToken()) == .notTyped)
        #expect(target.posted.isEmpty)
    }

    // MARK: Review fixes, round two

    @Test func theFallbackBackspaceWaitsForNoModifier() async {
        let (eraser, target, _, _) = makeEraser()
        target.deleteApplies = false
        readsBack(target)
        // The erase key goes down again while the AX delete is being verified.
        target.onDelete = { target.eraseKeyDownUntil = ContinuousClock().now + .seconds(30) }
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    @Test func backspacesStopWhenTheModifierGoesDownMidRun() async {
        let (eraser, target, _, _) = makeEraser()
        target.onPost = { _ in target.eraseKeyDownUntil = ContinuousClock().now + .seconds(30) }
        _ = typed(String(repeating: "a", count: 35), readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [10])
    }

    @Test func aLandingIsTrustedOnlyWhenMonitoredAndUntouched() {
        #expect(TypedDictation.landingIsTrusted(monitoring: true, epochBefore: 3, epochNow: 3))
        #expect(!TypedDictation.landingIsTrusted(monitoring: true, epochBefore: 3, epochNow: 4))
        #expect(!TypedDictation.landingIsTrusted(monitoring: false, epochBefore: 3, epochNow: 3))
    }

    @Test func supersedeReturnsTheNewDeliveryGeneration() {
        let (eraser, _, _, _) = makeEraser()
        let first = eraser.supersede()
        let second = eraser.supersede()
        #expect(second == first + 1)
        #expect(eraser.deliveryGeneration == second)
    }

    @Test func theModifierIsCheckedAfterTheLastReadBeforeTheFallbackBackspace() async {
        let (eraser, target, _, _) = makeEraser()
        target.deleteApplies = false
        readsBack(target)
        // Reads: the plan, the re-plan after the modifier wait, then the check right before
        // the fallback backspace. The key goes down again during that last read.
        target.onReadBack = { reads in
            if reads == 3 {
                target.eraseKeyDownUntil = ContinuousClock().now + .seconds(30)
            }
        }
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
    }

    // MARK: Fields that read but will not take a selection (the ChatGPT app, 2026-09-27)

    private let older = "Older text."
    private let latest = " Hello there, friend."

    /// A readable field holding older text and then the dictation, caret at the end, whose
    /// selection cannot be set.
    private func unselectableField(_ eraser: DictationEraser, _ target: FakeEraseTarget) {
        target.field = older + latest
        target.fieldElement = field
        target.fieldWindow = window
        target.selectSettable = false
        target.selectSucceeds = false
        let end = (older + latest).utf16.count
        target.currentSelection = CFRange(location: end, length: 0)
        eraser.recordTyped(TypedDictation(
            text: latest, processID: 42, element: field, window: window, caretEnd: end,
            landedAt: ContinuousClock().now, previousInjection: nil, inputEpoch: eraser.inputEpoch,
            generation: eraser.deliveryGeneration
        ))
    }

    @Test func anUnselectableFieldIsErasedWithCheckedBackspaces() async {
        let (eraser, target, _, _) = makeEraser()
        unselectableField(eraser, target)
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(target.field == older)
        // One key at a time, each proven before and verified after; no selection requested.
        #expect(target.posted == Array(repeating: 1, count: latest.count))
        #expect(target.selects.isEmpty)
    }

    @Test func aSelectionThatLandsAfterTheCallIsUsedAsASelection() async {
        let (eraser, target, _, _) = makeEraser()
        unselectableField(eraser, target)
        target.selectSettable = true
        target.selectLandsLate = true
        #expect(await eraser.eraseLast(token: EraseToken()) == .erased)
        #expect(target.field == older)
        #expect(target.posted.isEmpty)
        #expect(target.deletes == 1)
    }

    @Test func aBackspaceThatDeletesMoreThanOneCharacterStopsAtOnce() async {
        let (eraser, target, _, _) = makeEraser()
        unselectableField(eraser, target)
        target.backspaceDeletesWord = true
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [1])
        #expect(target.field?.hasPrefix(older + " Hello there,") == true)
    }

    @Test func checkedBackspacesStopWhenTheFieldChangesMidRun() async {
        let (eraser, target, _, _) = makeEraser()
        unselectableField(eraser, target)
        target.onPost = { calls in
            if calls == 1, let text = target.field, let caret = target.currentSelection {
                // The app inserts a character at the caret (autocomplete, another writer).
                target.field = (text as NSString).replacingCharacters(in: NSRange(location: caret.location, length: 0), with: "X")
                target.currentSelection = CFRange(location: caret.location + 1, length: 0)
            }
        }
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [1])
        #expect(target.field?.hasPrefix(older) == true)
    }

    @Test func checkedBackspacesStopOnInput() async {
        let (eraser, target, monitor, _) = makeEraser()
        unselectableField(eraser, target)
        target.onPost = { _ in monitor.fire() }
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [1])
    }

    @Test func aSelectionThatLandsLateStopsBeforeAnyBackspace() async {
        let (eraser, target, _, _) = makeEraser()
        unselectableField(eraser, target)
        // The select call reports failure but the app applies it a moment later.
        target.onReadBack = { reads in
            if reads == 3 {
                let length = self.latest.utf16.count
                target.currentSelection = CFRange(location: self.older.utf16.count, length: length)
            }
        }
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.posted.isEmpty)
        #expect(target.field == older + latest)
    }

    // MARK: Identity during a run (Codex, round 4)

    @Test func backspacesStopWhenTheWindowChangesMidRun() async {
        let (eraser, target, _, _) = makeEraser()
        let otherWindow = AXElementID(element: AXUIElementCreateApplication(202))
        target.onPost = { _ in target.read = .unreadable(window: otherWindow) }
        _ = typed(String(repeating: "a", count: 35), readable: false, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [10])
    }

    @Test func aTerminalRunStopsWhenAnotherPaneTakesFocus() async {
        let (eraser, target, _, _) = makeEraser()
        let otherPane = AXElementID(element: AXUIElementCreateApplication(104))
        target.read = .screen(element: field, window: window, selection: nil)
        target.onPost = { _ in target.read = .screen(element: otherPane, window: self.window, selection: nil) }
        var typed = TypedDictation(
            text: String(repeating: "a", count: 35), processID: 42, element: field, window: window, caretEnd: nil,
            landedAt: ContinuousClock().now, previousInjection: nil, inputEpoch: eraser.inputEpoch,
            generation: eraser.deliveryGeneration
        )
        typed.textProvable = false
        eraser.recordTyped(typed)
        #expect(await eraser.eraseLast(token: EraseToken()) == .interrupted)
        #expect(target.posted == [10])
    }
}
