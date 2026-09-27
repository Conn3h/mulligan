import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Puts text into whatever has keyboard focus. Two strategies, in order: an Accessibility
/// write that is trusted only when the caret verifiably moved, then the pasteboard plus a
/// synthesized Command-V with the previous pasteboard contents restored afterwards.
///
/// The restore runs `pasteCompletionDelay` after the paste, on a task the injector keeps:
/// the next paste awaits it before taking its own snapshot (so it can never capture our
/// text as the "original" and restore it for good), and `flushPendingRestore()` performs
/// it at once when the app quits.
@MainActor
enum TextInjector {
    private typealias SavedItem = [NSPasteboard.PasteboardType: Data]

    /// What a paste still owes the pasteboard.
    private struct PendingRestore {
        let saved: [SavedItem]
        let changeCount: Int
    }

    /// Virtual key code of V on an ANSI keyboard (kVK_ANSI_V).
    private static let vKeyCode: CGKeyCode = 9
    /// Long enough for the target to observe the new pasteboard generation before ⌘V.
    private static let pasteboardSettleDelay: Duration = .milliseconds(40)
    /// The paste is asynchronous in the target; restoring earlier would hand it our old
    /// contents instead of the text.
    private static let pasteCompletionDelay: Duration = .milliseconds(500)

    /// How long an accessibility write may take to show up in the selection or length before
    /// it counts as not landed. Firefox needs a few milliseconds; the paste fallback that
    /// follows a false "not landed" duplicates the text.
    private static let accessibilityVerifyTimeout: Duration = .milliseconds(150)
    private static let accessibilityVerifyPollInterval: Duration = .milliseconds(10)

    private static var pendingRestore: PendingRestore?
    private static var restoreTask: Task<Void, Never>?

    /// Only treat back-to-back dictations into the same app as a run-on. Beyond this the
    /// user has almost certainly moved on, and a leading space would be wrong.
    private static let pasteRunOnWindow: Duration = .seconds(8)

    private struct LastInjection {
        let bundleID: String?
        let at: ContinuousClock.Instant
        let endedInWhitespace: Bool
    }
    private static var lastInjection: LastInjection?
    private static let injectionClock = ContinuousClock()

    /// Returns once the text has been handed to the focused app. On the paste path the
    /// pasteboard is restored `pasteCompletionDelay` later, so the caller (and the user)
    /// does not wait on it; see the type comment for how that restore is kept in line.
    /// `targetProcessID` is the app the text is meant for: the paste is abandoned if another
    /// app comes to the front while the accessibility write is being verified.
    @discardableResult
    static func insert(_ text: String, targetProcessID: pid_t? = nil) async -> Outcome {
        guard !text.isEmpty else {
            Log.inject.info("nothing to insert")
            return .landed
        }
        guard let reason = await insertViaAccessibility(text) else {
            return .landed
        }
        Log.inject.info(
            "accessibility path not trusted (\(reason, privacy: .public)); pasting \(text.count, privacy: .public) chars"
        )
        return await insertViaPasteboard(text, targetProcessID: targetProcessID)
    }

    enum Outcome: Sendable, Equatable {
        case landed
        case failed
        /// Another app came to the front before the paste; nothing was typed.
        case focusMoved
    }

    /// Performs a pending pasteboard restore now instead of `pasteCompletionDelay` after
    /// the paste. Synchronous, for `applicationWillTerminate`: a quit inside that window
    /// must not leave dictated text on the clipboard.
    static func flushPendingRestore() {
        restoreTask?.cancel()
        restoreTask = nil
        performPendingRestore(reason: "flushed")
    }

    // MARK: Accessibility

    /// Nil when the write was verified by caret movement or a changed character count;
    /// otherwise the reason to fall back. "Moved" rather than "moved by exactly the text
    /// length": autocorrect and newline normalisation shift the caret by other amounts, and
    /// falling back after a write that did land would paste the text twice. Some apps
    /// (Firefox) apply the write at once but report the new selection only a moment later,
    /// so the check polls for `accessibilityVerifyTimeout` before giving up.
    private static func insertViaAccessibility(_ text: String) async -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusedError == .success, let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return "no focused element (AXError \(focusedError.rawValue))"
        }
        let focused = focusedValue as! AXUIElement

        var settable: DarwinBoolean = false
        let settableError = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
        guard settableError == .success else {
            return "selected text settability unknown (AXError \(settableError.rawValue))"
        }
        guard settable.boolValue else {
            return "selected text is not settable"
        }

        guard let before = selectedRange(of: focused) else {
            return "selection range unreadable before the write"
        }
        let countBefore = characterCount(of: focused)
        let leadingSpace = needsLeadingSpace(in: focused, before: before)
        let inserted = leadingSpace ? " " + text : text
        let writeError = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, inserted as CFString)
        guard writeError == .success else {
            return "write failed (AXError \(writeError.rawValue))"
        }
        let started = injectionClock.now
        let expected = ExpectedWrite(before: before, insertedUnits: (inserted as NSString).length, countBefore: countBefore)
        guard let evidence = await awaitWriteEvidence(on: focused, expecting: expected) else {
            return "write reported success but neither the selection nor the length changed within \(accessibilityVerifyTimeout)"
        }
        Log.inject.info(
            "inserted \(inserted.count, privacy: .public) chars via accessibility (leading space: \(leadingSpace, privacy: .public)); verified by \(evidence, privacy: .public) after \(injectionClock.now - started, privacy: .public)"
        )
        lastInjection = LastInjection(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            at: injectionClock.now,
            endedInWhitespace: inserted.last?.isWhitespace ?? false
        )
        return nil
    }

    /// What a landed write looks like: the caret (or a selection of the new text) now ends
    /// between half and double the inserted length past where the write started, or the
    /// length grew by between half and double the inserted text less what it replaced. The
    /// band is wide because editors that convert on insert (markdown, emoji shortcodes,
    /// autocorrect) change the landed length, and treating their write as failed pastes the
    /// text a second time. Backwards moves, small changes and far jumps (a terminal printing
    /// a screenful) are someone else's and do not count.
    struct ExpectedWrite {
        let before: CFRange
        let insertedUnits: Int
        let countBefore: Int?

        func matchesSelection(_ after: CFRange) -> Bool {
            guard after.location != before.location || after.length != before.length else {
                return false
            }
            let end = after.location + after.length
            let nearest = before.location + max(1, insertedUnits / 2)
            return end >= nearest && end <= before.location + 2 * insertedUnits + tolerance
        }

        /// A growing field must grow by at least half the expected amount and at most double
        /// it; a field the write should shrink (it replaced a longer selection) must land
        /// within the tolerance. A small change either way is someone else's edit.
        func matchesCount(_ countAfter: Int) -> Bool {
            guard let countBefore, countAfter != countBefore else {
                return false
            }
            let delta = countAfter - countBefore
            let expectedDelta = insertedUnits - before.length
            guard expectedDelta > 0 else {
                return abs(delta - expectedDelta) <= tolerance
            }
            return delta >= max(1, (expectedDelta + 1) / 2) && delta <= 2 * expectedDelta + tolerance
        }

        /// Minimum slack, in UTF-16 units, growing to a tenth of a long insertion.
        private static let minimumTolerance = 2
        private var tolerance: Int { max(Self.minimumTolerance, insertedUnits / 10) }
    }

    /// Polls for proof that an accessibility write landed (see `ExpectedWrite`). Returns a
    /// description of the evidence, or nil when none appeared before
    /// `accessibilityVerifyTimeout`.
    private static func awaitWriteEvidence(on element: AXUIElement, expecting expected: ExpectedWrite) async -> String? {
        let before = expected.before
        let deadline = injectionClock.now + accessibilityVerifyTimeout
        var loggedMismatch = false
        while true {
            let after = selectedRange(of: element)
            if let after, expected.matchesSelection(after) {
                return "selection \(before.location)+\(before.length) -> \(after.location)+\(after.length)"
            }
            let countAfter = characterCount(of: element)
            if let countAfter, expected.matchesCount(countAfter) {
                return "length \(expected.countBefore ?? -1) -> \(countAfter)"
            }
            if !loggedMismatch, let after, after.location != before.location || after.length != before.length {
                loggedMismatch = true
                Log.inject.info(
                    "selection moved by an unexpected amount (\(before.location, privacy: .public)+\(before.length, privacy: .public) -> \(after.location, privacy: .public)+\(after.length, privacy: .public), inserted \(expected.insertedUnits, privacy: .public) units); still waiting"
                )
            }
            guard injectionClock.now < deadline else {
                return nil
            }
            await wait(accessibilityVerifyPollInterval)
        }
    }

    private static func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value)
        guard error == .success, let count = value as? Int else {
            Log.inject.debug("character count unavailable (AXError \(error.rawValue, privacy: .public))")
            return nil
        }
        return count
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            Log.inject.debug("selected text range unavailable (AXError \(error.rawValue, privacy: .public))")
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            Log.inject.debug("selected text range has unexpected value type \(AXValueGetType(axValue).rawValue, privacy: .public)")
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            Log.inject.debug("selected text range could not be unpacked")
            return nil
        }
        return range
    }

    /// Consecutive dictations would otherwise run together ("working?5.one"): when the
    /// selection starts right after a character that is not whitespace, the text gets one
    /// leading space. Reads only the character immediately before the caret via the
    /// range-parameterized attribute, falling back to the whole-value read when that is
    /// unavailable, fails, or returns empty (each logged). The paste path cannot read the
    /// target at all, so it applies a narrower rule instead: `pasteRunOnLeadingSpaceNeeded`
    /// adds a leading space only when this paste immediately follows our own injection into
    /// the same frontmost app, recently, and that text did not already end in whitespace.
    private static func needsLeadingSpace(in element: AXUIElement, before range: CFRange) -> Bool {
        guard range.location > 0 else {
            return false
        }
        switch character(before: range.location, in: element) {
        case .some(.some(let precedingChar)):
            return !precedingChar.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
        case .some(.none):
            return false
        case .none:
            break  // attribute unsupported, failed, or empty; fall back to the full-value read
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard error == .success, let value else {
            Log.inject.info("focused value unreadable (AXError \(error.rawValue, privacy: .public)); inserting without a leading space")
            return false
        }
        guard let text = value as? String else {
            Log.inject.info("focused value is not text (type \(CFGetTypeID(value), privacy: .public)); inserting without a leading space")
            return false
        }
        let units = text as NSString
        let index = range.location - 1
        guard index < units.length else {
            Log.inject.info(
                "selection starts at \(range.location, privacy: .public) but the value has \(units.length, privacy: .public) units; inserting without a leading space"
            )
            return false
        }
        guard let scalar = Unicode.Scalar(units.character(at: index)) else {
            // Half of a surrogate pair: an emoji or similar, which is not whitespace.
            return true
        }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The single character immediately before `location`, read with the range-parameterized
    /// attribute so the whole document is never copied.
    /// - Returns `nil` (outer) when the read cannot be trusted (value-creation failure, AX
    ///   error, unexpected type, or empty result): the caller falls back to the full-value read.
    /// - Returns `.some(nil)` only when there is genuinely no preceding character.
    /// - Returns `.some(char)` with the character otherwise.
    private static func character(before location: Int, in element: AXUIElement) -> Character?? {
        guard location > 0 else { return .some(nil) }  // genuine: at the start of the field
        var range = CFRange(location: location - 1, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &range) else {
            Log.inject.debug("could not create an AXValue range for the preceding character; falling back")
            return nil
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &value
        )
        guard error == .success, let string = value as? String else {
            Log.inject.debug("string-for-range unavailable (AXError \(error.rawValue, privacy: .public)); falling back")
            return nil
        }
        guard let first = string.first else {
            // A successful but empty read is not proof of a field start; fall back.
            Log.inject.debug("string-for-range returned empty for a nonzero range; falling back")
            return nil
        }
        return .some(first)
    }

    // MARK: Pasteboard

    private static func insertViaPasteboard(_ text: String, targetProcessID: pid_t?) async -> Outcome {
        await awaitPendingRestore()
        let outgoing = Self.pasteRunOnLeadingSpaceNeeded() ? " " + text : text
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(outgoing, forType: .string) else {
            Log.inject.error("pasteboard write failed; nothing inserted")
            restore(saved, to: pasteboard)
            return .failed
        }
        let ourChangeCount = pasteboard.changeCount
        // Registered before the first suspension: a quit during the settle wait must still
        // give the pasteboard back, and the flush can only restore what is registered.
        pendingRestore = PendingRestore(saved: saved, changeCount: ourChangeCount)

        await wait(pasteboardSettleDelay)
        guard pendingRestore?.changeCount == ourChangeCount else {
            Log.inject.info("pasteboard was restored during the settle wait; not pasting")
            return .failed
        }
        // The accessibility verification and the settle wait both suspend; Command-V goes
        // to whatever app is in front now, which must still be the one the text is for.
        if let targetProcessID, let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmost != targetProcessID {
            Log.inject.info(
                "frontmost app changed before Command-V (pid \(targetProcessID, privacy: .public) -> \(frontmost, privacy: .public)); not pasting"
            )
            performPendingRestore(reason: "focus moved")
            return .focusMoved
        }
        guard postCommandV() else {
            Log.inject.error("could not synthesize Command-V; nothing inserted")
            performPendingRestore(reason: "Command-V failed")
            return .failed
        }
        Log.inject.info("pasted \(outgoing.count, privacy: .public) chars via Command-V")
        lastInjection = LastInjection(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            at: injectionClock.now,
            endedInWhitespace: outgoing.last?.isWhitespace ?? false
        )
        scheduleRestoreTask()
        return .landed
    }

    /// True when this paste immediately follows our own injection into the same frontmost
    /// app, recently, and that text did not already end in whitespace. Conservative on
    /// purpose: it never fires across apps or after a pause, so a moved caret in a different
    /// context cannot trigger a spurious space.
    private static func pasteRunOnLeadingSpaceNeeded() -> Bool {
        guard let last = lastInjection, !last.endedInWhitespace else { return false }
        let now = injectionClock.now
        guard now - last.at <= pasteRunOnWindow else { return false }
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return current != nil && current == last.bundleID
    }

    /// The previous paste's restore must land before this paste snapshots the pasteboard,
    /// or the snapshot would hold that paste's text and restore it permanently.
    private static func awaitPendingRestore() async {
        guard let restoreTask else {
            return
        }
        Log.inject.info("waiting for the previous pasteboard restore before pasting")
        await restoreTask.value
    }

    private static func scheduleRestoreTask() {
        restoreTask = Task { @MainActor in
            await wait(pasteCompletionDelay)
            performPendingRestore(reason: "paste completed")
        }
    }

    /// Restores whatever is pending, once: the scheduled task and an early flush both come
    /// through here, and whichever runs second finds nothing left to do.
    private static func performPendingRestore(reason: String) {
        guard let pending = pendingRestore else {
            Log.inject.debug("no pasteboard restore pending (\(reason, privacy: .public))")
            return
        }
        pendingRestore = nil
        restoreTask = nil
        Log.inject.info("restoring the pasteboard (\(reason, privacy: .public))")
        restoreIfUnchanged(pending.saved, since: pending.changeCount)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let pairs = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else {
                    Log.inject.debug("pasteboard type \(type.rawValue, privacy: .public) had no data to save")
                    return nil
                }
                return (type, data)
            }
            return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Restores the saved items only if nobody else has written to the pasteboard since
    /// our write; otherwise the user's newer copy wins and the skip is logged.
    private static func restoreIfUnchanged(_ saved: [SavedItem], since changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else {
            Log.inject.info(
                "pasteboard restore skipped: it changed underneath us (changeCount \(changeCount, privacy: .public) -> \(pasteboard.changeCount, privacy: .public))"
            )
            return
        }
        restore(saved, to: pasteboard)
    }

    private static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                if !item.setData(data, forType: type) {
                    Log.inject.error("pasteboard restore could not set type \(type.rawValue, privacy: .public)")
                }
            }
            return item
        }
        guard !items.isEmpty else {
            Log.inject.info("pasteboard restored: it was empty")
            return
        }
        guard pasteboard.writeObjects(items) else {
            Log.inject.error("pasteboard restore failed to write \(items.count, privacy: .public) items")
            return
        }
        Log.inject.info("pasteboard restored: \(items.count, privacy: .public) items")
    }

    /// Command-V from a private event source with the flags set explicitly, so live hardware
    /// modifier state (a finger still resting on a key) is never inherited.
    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.inject.error("could not create a private event source")
            return false
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            Log.inject.error("could not create Command-V key events")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func wait(_ duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            Log.inject.debug("injection wait cancelled")
        }
    }
}
