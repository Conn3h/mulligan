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

    private(set) var selects: [CFRange] = []
    private(set) var deletes = 0
    private(set) var posted: [Int] = []
    private(set) var postedAt: [ContinuousClock.Instant] = []

    func frontmostProcessID() -> pid_t? { frontmost }

    /// The configured read, with the live selection when the field is readable.
    func readBack(utf16Length: Int) -> ReadBack {
        if case let .readable(element, window, _, preceding) = read, let currentSelection {
            return .readable(element: element, window: window, selection: currentSelection, preceding: preceding)
        }
        return read
    }

    func select(_ range: CFRange, in element: AXElementID) -> Bool {
        selects.append(range)
        if selectSucceeds {
            currentSelection = range
        }
        return selectSucceeds
    }

    func deleteSelection(in element: AXElementID) -> Bool {
        deletes += 1
        if deleteApplies {
            collapseSelection()
        }
        onDelete?()
        return true
    }

    func selection(in element: AXElementID) -> CFRange? { currentSelection }

    func characterCount(in element: AXElementID) -> Int? { count }

    func postBackspaces(_ count: Int) -> Int {
        let managed = min(count, postLimit ?? count)
        posted.append(managed)
        postedAt.append(ContinuousClock().now)
        if managed > 0 {
            collapseSelection()
        }
        onPost?(posted.count)
        return managed
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

    @Test func deleteRangeStopsWhenTheSelectionCannotBeSet() async {
        let (eraser, target, _, _) = makeEraser()
        target.selectSucceeds = false
        readsBack(target)
        _ = typed(readable: true, eraser: eraser)
        #expect(await eraser.eraseLast(token: EraseToken()) == .failed)
        #expect(target.deletes == 0)
        #expect(target.posted.isEmpty)
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
}
