import ApplicationServices
import Foundation

/// Revoked by the controller on `eraseTimeout`, `deactivate()` or quit. The eraser checks it
/// before every side effect, so an abandoned erase stops instead of running on behind a new
/// dictation.
@MainActor
final class EraseToken {
    private(set) var isRevoked = false

    func revoke() {
        isRevoked = true
    }
}

/// The target app, as the eraser sees it. The real one is `SystemEraseTarget`.
@MainActor
protocol EraseTarget: AnyObject {
    func frontmostProcessID() -> pid_t?
    /// The focused field now, reading `utf16Length` units of text before the selection's end.
    func readBack(utf16Length: Int) -> ReadBack
    /// Whether the field says its selection can be set at all.
    func canSelect(in element: AXElementID) -> Bool
    /// Sets the selection; true only when it reads back exactly as set.
    func select(_ range: CFRange, in element: AXElementID) -> Bool
    /// Writes "" over the selection. The caller verifies whether it took.
    func deleteSelection(in element: AXElementID) -> Bool
    func selection(in element: AXElementID) -> CFRange?
    func characterCount(in element: AXElementID) -> Int?
    /// Marked kVK_Delete presses with empty flags from a private event source. Returns how
    /// many were actually posted (event creation can fail).
    @discardableResult
    func postBackspaces(_ count: Int) -> Int
    func isKeyDown(_ keyCode: Int64) -> Bool
}

/// Reports user input: keys, clicks, scrolls, app and Space switches. The real one is
/// `SystemInputMonitor`.
@MainActor
protocol InputMonitoring: AnyObject {
    /// False when the monitor could not be installed.
    func start(onInput: @escaping @MainActor () -> Void) -> Bool
}

/// Erases exactly what Sotto last typed, or refuses and says why (§6.16). One level: the
/// record is the last landing, and any attempt that gets past "nothing to erase" clears it.
@MainActor
final class DictationEraser: TypingObserver {
    static let shared = DictationEraser(
        target: SystemEraseTarget(),
        monitor: SystemInputMonitor(),
        eraseKey: { Settings.shared.eraseKey },
        restoreInjection: { TextInjector.restoreLastInjection($0) }
    )

    /// Backspaces per burst, with a pause between bursts so the target's queue keeps up and
    /// the run can stop between them.
    private static let chunkSize = 10
    private static let chunkPause: Duration = .milliseconds(2)
    private static let modifierPoll: Duration = .milliseconds(10)
    private static let modifierWaitCap: Duration = .seconds(1)
    private static let verifyTimeout: Duration = .milliseconds(150)
    /// How long a refused selection may take to land anyway: the ChatGPT app reports failure,
    /// then applies it (2026-09-27).
    private static let selectionSettle: Duration = .milliseconds(200)
    /// Checked backspaces wait longer for the field to show them: an app that reads back
    /// lazily must not stop a correct erase half-way.
    private static let checkedVerifyTimeout: Duration = .milliseconds(500)
    private static let verifyPoll: Duration = .milliseconds(10)

    private let target: any EraseTarget
    private let monitor: any InputMonitoring
    private let eraseKey: @MainActor () -> EraseKey
    private let restoreInjection: @MainActor (LastInjectionSnapshot?) -> Void
    private let clock = ContinuousClock()
    private var record: TypedDictation?
    private var superseded = false
    private var monitoring = false
    private(set) var inputEpoch: UInt64 = 0
    private(set) var deliveryGeneration: UInt64 = 0

    init(
        target: any EraseTarget,
        monitor: any InputMonitoring,
        eraseKey: @escaping @MainActor () -> EraseKey,
        restoreInjection: @escaping @MainActor (LastInjectionSnapshot?) -> Void
    ) {
        self.target = target
        self.monitor = monitor
        self.eraseKey = eraseKey
        self.restoreInjection = restoreInjection
    }

    /// Installs the input monitor. Safe to call again: it retries until one installs (it
    /// can fail before Accessibility is granted).
    func start() {
        guard !monitoring else {
            return
        }
        monitoring = monitor.start { [weak self] in
            self?.inputEpoch &+= 1
        }
        if monitoring {
            Log.inject.info("erase input monitor running")
        } else {
            Log.inject.error("erase input monitor unavailable; erase will refuse in apps it cannot read")
        }
    }

    func recordTyped(_ typed: TypedDictation) {
        record = typed
        // An older delivery's paste settling after a newer delivery began is still not the
        // last dictation: only the current delivery's landing clears the mark.
        superseded = typed.generation != deliveryGeneration
        Log.inject.debug("erase record: \(typed.text.count, privacy: .public) chars, readable \(typed.element != nil, privacy: .public)")
    }

    @discardableResult
    func supersede() -> UInt64 {
        deliveryGeneration &+= 1
        superseded = true
        return deliveryGeneration
    }

    var isMonitoring: Bool { monitoring }

    func eraseLast(token: EraseToken) async -> EraseOutcome {
        await MutationLane.run {
            (await self.eraseExclusive(token: token), nil)
        }
    }

    // MARK: Plan and execute

    private func eraseExclusive(token: EraseToken) async -> EraseOutcome {
        guard let record else {
            Log.inject.info("erase: nothing recorded")
            return .nothingToErase
        }
        self.record = nil
        let wasSuperseded = superseded
        let started = clock.now
        // Plan once to refuse at once when it can, then wait for the erase key to come up and
        // plan again from a fresh read: the user may have moved the caret meanwhile, and the
        // mutation must act on what is true now, not a moment ago.
        var plan = currentPlan(for: record, superseded: wasSuperseded)
        if case .refuse = plan {
        } else if await waitForModifierUp(token: token) {
            plan = currentPlan(for: record, superseded: wasSuperseded)
        } else {
            plan = .refuse(.failed)
        }
        let outcome: EraseOutcome
        switch plan {
        case .refuse(let reason):
            outcome = reason
        case let .deleteRange(location, length):
            outcome = await deleteRange(CFRange(location: location, length: length), record: record, token: token)
        case .backspaces(let count):
            outcome = await backspaces(count, record: record, token: token)
        }
        Log.inject.info(
            "erase: \(Self.describe(plan), privacy: .public) -> \(String(describing: outcome), privacy: .public); \(record.text.utf16.count, privacy: .public) units, \(record.text.count, privacy: .public) chars, \(self.clock.now - started, privacy: .public)"
        )
        if outcome == .erased {
            restoreInjection(record.previousInjection)
        }
        return outcome
    }

    private func currentPlan(for record: TypedDictation, superseded: Bool) -> ErasePlan {
        // Without a monitor the epoch cannot vouch for anything, so it is made to differ:
        // an unreadable target then always refuses (fail closed).
        let epoch = monitoring ? inputEpoch : record.inputEpoch &+ 1
        return ErasePlan.decide(
            record: record,
            superseded: superseded,
            epoch: epoch,
            frontmostPID: target.frontmostProcessID(),
            readBack: target.readBack(utf16Length: record.text.utf16.count)
        )
    }

    /// Readable and proven: select exactly the range, delete it through AX, and verify. If
    /// the AX write did not take, one backspace deletes the selection, but only after checking
    /// again that the same app and field are in front, nothing was touched, and the selection
    /// is still exactly our text: the backspace goes to whatever has focus, not to the element.
    /// Never counted backspaces here.
    private func deleteRange(_ range: CFRange, record: TypedDictation, token: EraseToken) async -> EraseOutcome {
        guard let element = record.element else {
            Log.inject.error("erase: a range plan without a recorded element")
            return .failed
        }
        let epoch = inputEpoch
        // A field that cannot select at all gets checked backspaces, with no selection request
        // left pending that could land in the middle of them.
        guard target.canSelect(in: element) else {
            Log.inject.info("erase: the field's selection cannot be set; using checked backspaces")
            return await checkedBackspaces(from: range.location, element: element, record: record, token: token, epoch: epoch)
        }
        // One that can but does not apply it, even late, may apply it at any later moment,
        // where a backspace would delete it and more: refuse.
        guard await selectAllowingLateLanding(range, in: element) else {
            Log.inject.info(
                "erase: selection \(range.location, privacy: .public)+\(range.length, privacy: .public) did not take; refusing"
            )
            return .failed
        }
        // The selection may have landed late, after text moved: it must still cover exactly
        // Sotto's text, in the same field, with nothing touched, before anything is deleted.
        guard !token.isRevoked, isStillOurSelection(range, element: element, record: record, epoch: epoch) else {
            Log.inject.info("erase: the selection no longer covers exactly the dictation; refusing")
            return .failed
        }
        let countBefore = target.characterCount(in: element)
        if !target.deleteSelection(in: element) {
            Log.inject.info("erase: AX delete reported an error; checking whether it took")
        }
        if await verifyDeleted(range, countBefore: countBefore, in: element) {
            return .erased
        }
        guard !token.isRevoked, isStillOurSelection(range, element: element, record: record, epoch: epoch) else {
            Log.inject.error(
                "erase: AX delete unverified and the field, focus or input changed (range \(range.location, privacy: .public)+\(range.length, privacy: .public)); stopping"
            )
            return .failed
        }
        guard target.postBackspaces(1) == 1 else {
            return .failed
        }
        if await verifyDeleted(range, countBefore: countBefore, in: element) {
            return .erased
        }
        Log.inject.error("erase: the selection-delete backspace did not verify")
        return .failed
    }

    /// Right before a key that goes to whatever has focus: same app in front, no user input,
    /// the focused element is ours, its selection is exactly our range, and the text in it is
    /// still exactly what Sotto typed.
    private func isStillOurSelection(_ range: CFRange, element: AXElementID, record: TypedDictation, epoch: UInt64) -> Bool {
        guard inputEpoch == epoch, target.frontmostProcessID() == record.processID else {
            return false
        }
        guard case let .readable(focused, _, selection, preceding) = target.readBack(utf16Length: range.length),
              focused == element,
              selection.location == range.location, selection.length == range.length,
              let preceding, preceding.utf16.elementsEqual(record.text.utf16)
        else {
            return false
        }
        // Last, after the AX reads (each can take a moment): the erase key pressed again
        // meanwhile would turn the backspace into Command-Delete.
        return !eraseModifierIsDown()
    }

    /// Some apps refuse the selection and then apply it a moment later. A selection that lands
    /// late is the one path where a backspace would delete more than one character, so it is
    /// waited for and then used as a selection.
    private func selectAllowingLateLanding(_ range: CFRange, in element: AXElementID) async -> Bool {
        if target.select(range, in: element) {
            return true
        }
        await pause(Self.selectionSettle)
        guard let now = target.selection(in: element), now.location == range.location, now.length == range.length else {
            return false
        }
        Log.inject.info("erase: the selection landed after the app reported failure; using it")
        return true
    }

    /// A field that reads but cannot select: backspaces one at a time, each proven first. Before every burst the focused element must be ours,
    /// the caret collapsed exactly where the remaining dictation ends, the text before it
    /// exactly that remainder, with no input, no app change and no erase modifier; after each
    /// burst the field must show it landed. Anything else stops the run.
    private func checkedBackspaces(
        from start: Int, element: AXElementID, record: TypedDictation, token: EraseToken, epoch: UInt64
    ) async -> EraseOutcome {
        var remaining = record.text
        var posted = 0
        // One backspace at a time, each proven before and verified after: if the app ever
        // deletes more than one character for one (a word delete, a selection from elsewhere),
        // the check after it stops the run with only the dictation's own last characters gone.
        while !remaining.isEmpty {
            guard !token.isRevoked, inputEpoch == epoch, target.frontmostProcessID() == record.processID,
                  caretFollows(remaining, from: start, in: element), !eraseModifierIsDown()
            else {
                Log.inject.info(
                    "erase: checked backspaces stopped after \(posted, privacy: .public) of \(record.text.count, privacy: .public)"
                )
                return posted == 0 ? .failed : .interrupted
            }
            let burst = 1
            let managed = target.postBackspaces(burst)
            posted += managed
            remaining = String(remaining.dropLast(managed))
            guard managed == burst else {
                Log.inject.error("erase: only \(managed, privacy: .public) of \(burst, privacy: .public) backspaces could be posted")
                return posted == 0 ? .failed : .interrupted
            }
            guard await awaitCaret(following: remaining, from: start, in: element) else {
                Log.inject.info("erase: the field did not show the backspaces landing; stopping after \(posted, privacy: .public)")
                return .interrupted
            }
        }
        return .erased
    }

    /// The focused element is ours and its caret sits, collapsed, right after `remaining`,
    /// which is exactly the text before it.
    private func caretFollows(_ remaining: String, from start: Int, in element: AXElementID) -> Bool {
        let units = remaining.utf16.count
        guard case let .readable(focused, _, selection, preceding) = target.readBack(utf16Length: units),
              focused == element, selection.length == 0, selection.location == start + units
        else {
            return false
        }
        return units == 0 || preceding.map { $0.utf16.elementsEqual(remaining.utf16) } == true
    }

    private func awaitCaret(following remaining: String, from start: Int, in element: AXElementID) async -> Bool {
        let deadline = clock.now + Self.checkedVerifyTimeout
        while !caretFollows(remaining, from: start, in: element) {
            guard clock.now < deadline else {
                return false
            }
            await pause(Self.verifyPoll)
        }
        return true
    }

    /// The caret sits at the range's start and, when the field reports a length, it shrank by
    /// the range's length. Polled, because some apps report the change a moment late.
    private func verifyDeleted(_ range: CFRange, countBefore: Int?, in element: AXElementID) async -> Bool {
        let deadline = clock.now + Self.verifyTimeout
        while true {
            if let selection = target.selection(in: element),
               selection.location == range.location, selection.length == 0 {
                guard let countBefore, let countAfter = target.characterCount(in: element) else {
                    return true
                }
                if countBefore - countAfter == range.length {
                    return true
                }
            }
            guard clock.now < deadline else {
                return false
            }
            await pause(Self.verifyPoll)
        }
    }

    /// Unreadable and inferred untouched: backspaces in bursts, stopping the moment the user
    /// does anything or another app comes to the front.
    private func backspaces(_ count: Int, record: TypedDictation, token: EraseToken) async -> EraseOutcome {
        // The plan held with the record's epoch, so any input since it landed stops the run.
        let epoch = record.inputEpoch
        var remaining = count
        var posted = 0
        while remaining > 0 {
            // The erase key pressed again is a modifier change the input monitor does not see.
            let changed = inputEpoch != epoch || target.frontmostProcessID() != record.processID
                || eraseModifierIsDown()
            if token.isRevoked || changed {
                Log.inject.info(
                    "erase: stopped after \(posted, privacy: .public) of \(count, privacy: .public) backspaces (revoked \(token.isRevoked, privacy: .public), input or app changed \(changed, privacy: .public))"
                )
                return posted == 0 ? .failed : .interrupted
            }
            let burst = min(Self.chunkSize, remaining)
            let managed = target.postBackspaces(burst)
            posted += managed
            remaining -= managed
            if managed < burst {
                Log.inject.error("erase: only \(managed, privacy: .public) of \(burst, privacy: .public) backspaces could be posted")
                return posted == 0 ? .failed : .interrupted
            }
            await pause(Self.chunkPause)
        }
        return .erased
    }

    private func eraseModifierIsDown() -> Bool {
        guard let keyCode = eraseKey().keyCode else {
            return false
        }
        return target.isKeyDown(keyCode)
    }

    /// No key may be posted while the erase modifier is still down, or an app reading live
    /// modifier state could see Command-Delete. Bounded; keys carry empty flags regardless.
    private func waitForModifierUp(token: EraseToken) async -> Bool {
        guard let keyCode = eraseKey().keyCode else {
            return !token.isRevoked
        }
        let deadline = clock.now + Self.modifierWaitCap
        while target.isKeyDown(keyCode) {
            guard !token.isRevoked else {
                return false
            }
            guard clock.now < deadline else {
                Log.inject.info("erase: the erase key is still down after \(Self.modifierWaitCap, privacy: .public); not erasing")
                return false
            }
            await pause(Self.modifierPoll)
        }
        return !token.isRevoked
    }

    private func pause(_ duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            Log.inject.debug("erase pause cancelled")
        }
    }

    private static func describe(_ plan: ErasePlan) -> String {
        switch plan {
        case .refuse: "refuse"
        case let .deleteRange(location, length): "delete range \(location)+\(length)"
        case .backspaces(let count): "\(count) backspaces"
        }
    }
}
