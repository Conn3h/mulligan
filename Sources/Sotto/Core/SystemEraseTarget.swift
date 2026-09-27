import AppKit
import ApplicationServices
import CoreGraphics

/// The real `EraseTarget`: Accessibility for reading and selecting, synthesized backspaces
/// for deleting where AX cannot (§6.16).
@MainActor
final class SystemEraseTarget: EraseTarget {
    /// kVK_Delete (Backspace) on an ANSI keyboard.
    private static let deleteKeyCode: CGKeyCode = 51

    func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func readBack(utf16Length: Int) -> ReadBack {
        let focus = TextInjector.focusedTarget()
        guard let element = focus.element else {
            return .unreadable(window: focus.window)
        }
        guard let selection = TextInjector.selectedRange(of: element.element) else {
            return .unreadable(window: focus.window)
        }
        let end = selection.location + selection.length
        let preceding = end >= utf16Length ? string(in: CFRange(location: end - utf16Length, length: utf16Length), of: element) : nil
        return .readable(element: element, window: focus.window, selection: selection, preceding: preceding)
    }

    func select(_ range: CFRange, in element: AXElementID) -> Bool {
        var wanted = range
        guard let value = AXValueCreate(.cfRange, &wanted) else {
            Log.inject.error("erase: could not create an AXValue for the selection")
            return false
        }
        let error = AXUIElementSetAttributeValue(element.element, kAXSelectedTextRangeAttribute as CFString, value)
        guard error == .success else {
            Log.inject.info("erase: setting the selection failed (AXError \(error.rawValue, privacy: .public))")
            return false
        }
        guard let now = TextInjector.selectedRange(of: element.element) else {
            return false
        }
        return now.location == range.location && now.length == range.length
    }

    func deleteSelection(in element: AXElementID) -> Bool {
        let error = AXUIElementSetAttributeValue(element.element, kAXSelectedTextAttribute as CFString, "" as CFString)
        if error != .success {
            Log.inject.info("erase: AX delete failed (AXError \(error.rawValue, privacy: .public))")
        }
        return error == .success
    }

    func selection(in element: AXElementID) -> CFRange? {
        TextInjector.selectedRange(of: element.element)
    }

    func characterCount(in element: AXElementID) -> Int? {
        TextInjector.characterCount(of: element.element)
    }

    func postBackspaces(_ count: Int) -> Int {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.inject.error("erase: could not create a private event source")
            return 0
        }
        for posted in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKeyCode, keyDown: false)
            else {
                Log.inject.error("erase: could not create backspace events after \(posted, privacy: .public)")
                return posted
            }
            // Push to talk is still physically down: explicit empty flags, so no app reads
            // these as Option-Delete (delete word).
            down.flags = []
            up.flags = []
            SyntheticEvent.mark(down)
            SyntheticEvent.mark(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return count
    }

    /// For the modifiers that can be erase keys, the hardware modifier flags: the per-key state
    /// reads a modifier Sotto's tap swallows as up while it is held (measured 2026-09-27). The
    /// generic mask is stricter than the key itself (either Command counts), which only ever
    /// makes the eraser wait or stop, never post.
    func isKeyDown(_ keyCode: Int64) -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        switch keyCode {
        case PushToTalkKey.rightCommand.keyCode:
            return flags.contains(.maskCommand)
        case PushToTalkKey.rightOption.keyCode:
            return flags.contains(.maskAlternate)
        default:
            return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
        }
    }

    /// The text in `range`, read with the range-parameterized attribute so the whole document
    /// is never copied. Nil when unreadable.
    private func string(in range: CFRange, of element: AXElementID) -> String? {
        var wanted = range
        guard let value = AXValueCreate(.cfRange, &wanted) else {
            Log.inject.error("erase: could not create an AXValue for the read-back range")
            return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element.element, kAXStringForRangeParameterizedAttribute as CFString, value, &result
        )
        guard error == .success, let text = result as? String else {
            Log.inject.debug("erase: string-for-range unavailable (AXError \(error.rawValue, privacy: .public))")
            return nil
        }
        return text
    }
}

/// The real `InputMonitoring`: a passive global monitor (it cannot delay anyone's typing)
/// plus app and Space switches. Sotto's own marked events are ignored. It looks only at the
/// event type and the marker, never at key codes or characters, and logs nothing per event.
@MainActor
final class SystemInputMonitor: InputMonitoring {
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func start(onInput: @escaping @MainActor () -> Void) -> Bool {
        guard eventMonitor == nil else {
            return true
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            if let cgEvent = event.cgEvent, SyntheticEvent.isMarked(cgEvent) {
                return
            }
            Task { @MainActor in
                onInput()
            }
        }
        guard eventMonitor != nil else {
            Log.inject.error("erase: the global input monitor could not be installed")
            return false
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    onInput()
                }
            })
        }
        return true
    }
}
