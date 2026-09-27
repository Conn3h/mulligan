import CoreGraphics
import Foundation

/// The keys the user can hold to dictate.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case rightCommand
    case fn

    /// HIToolbox virtual key codes: kVK_RightOption, kVK_RightCommand, kVK_Function.
    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        }
    }

    /// The device-specific modifier bit for this key. The public masks (`.maskAlternate`,
    /// `.maskCommand`) are set when either the left or the right key is down, so with Left
    /// Option held a Right Option release would be invisible and the mic would stay open.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)
        case .rightCommand: CGEventFlags(rawValue: 0x10)
        case .fn: .maskSecondaryFn
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right \u{2325}"
        case .rightCommand: "Right \u{2318}"
        case .fn: "fn"
        }
    }

    /// The two right-hand modifiers are swallowed while Sotto owns them. fn never is:
    /// swallowing it breaks fn-arrow, fn-delete and the emoji picker.
    var consumesEvent: Bool {
        switch self {
        case .rightOption, .rightCommand: true
        case .fn: false
        }
    }
}

/// The seam the controller depends on, so tests can drive presses without a CGEventTap.
@MainActor
protocol HotkeySource: AnyObject {
    var key: PushToTalkKey { get set }
    /// Tapped while `key` is held, erases the last dictation (§6.16).
    var eraseKey: EraseKey { get set }
    var onPress: (() -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
    var onErase: (() -> Void)? { get set }
    /// False when the tap cannot be created, which means Accessibility is not granted.
    @discardableResult func start() -> Bool
    func stop()
}

/// A session-level `CGEvent` tap for `.flagsChanged`, on the main run loop. An `NSEvent`
/// global monitor cannot tell left from right modifiers or see fn, which is why a tap is
/// required and why Accessibility is a hard requirement.
@MainActor
final class HotkeyMonitor: HotkeySource {
    var key: PushToTalkKey = .rightOption
    var eraseKey: EraseKey = .rightCommand
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onErase: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    /// True between an erase-key down Sotto swallowed and its up, which is swallowed too so
    /// the target never sees a modifier up without its down.
    private var eraseModifierSwallowed = false

    /// Reads whether the push-to-talk key is physically down right now. Keyed by virtual
    /// keycode, not modifier flag: the device-specific Right-Option / Right-Command bits are
    /// not reliably reported by `CGEventSource` flag state, but per-key state is. Injectable
    /// so the reconciliation path can be unit-tested without a real event tap.
    var isKeyDown: (PushToTalkKey) -> Bool = { key in
        HotkeyMonitor.isPhysicallyDown(CGKeyCode(key.keyCode))
    }

    /// Physical state of the erase key, by keycode like `isKeyDown`. Injectable for tests.
    var isEraseKeyDown: (EraseKey) -> Bool = { key in
        guard let code = key.keyCode else {
            return false
        }
        return HotkeyMonitor.isPhysicallyDown(CGKeyCode(code))
    }

    /// Down in either the hardware state or the session state. This tap swallows the
    /// push-to-talk key's own events, so the session state alone may never see it go down;
    /// the hardware state does. Either saying "down" counts: it can only make reconciliation
    /// wait for a real release, and lets the erase check see a key Sotto is holding back.
    nonisolated static func isPhysicallyDown(_ keyCode: CGKeyCode) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: keyCode)
            || CGEventSource.keyState(.combinedSessionState, key: keyCode)
    }

    init() {}

    @discardableResult
    func start() -> Bool {
        if tap != nil {
            Log.hotkey.info("hotkey monitor already running for \(self.key.displayName, privacy: .public)")
            return true
        }
        isPressed = false
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: userInfo
        ) else {
            Log.hotkey.error(
                "event tap creation failed for \(self.key.displayName, privacy: .public); accessibility trusted: \(Permissions.hasAccessibility, privacy: .public)"
            )
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Log.hotkey.error("run loop source creation failed for the event tap")
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        Log.hotkey.info("listening for \(self.key.displayName, privacy: .public)")
        return true
    }

    /// Disables the tap and forgets the pressed state without emitting a release. The
    /// controller ends any utterance before it stops or reloads the monitor.
    func stop() {
        isPressed = false
        eraseModifierSwallowed = false
        guard let tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
        Log.hotkey.info("stopped listening for \(self.key.displayName, privacy: .public)")
    }

    /// Handles one tap event, already reduced to plain values. Returns true when the event
    /// should be swallowed. Internal so the reconciliation path is unit-testable.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.hotkey.error("event tap disabled (type \(type.rawValue, privacy: .public)); re-enabling")
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            reconcilePressedState()
            return false
        case .flagsChanged:
            // Push to talk always wins a shared keycode; Settings never allows one (§6.16).
            if let eraseCode = eraseKey.keyCode, let eraseFlag = eraseKey.flag,
               keyCode == eraseCode, eraseCode != key.keyCode {
                return handleEraseModifier(down: flags.contains(eraseFlag))
            }
            guard keyCode == key.keyCode else {
                return false
            }
            let pressed = flags.contains(key.flag)
            if pressed, isPressed {
                // A flagsChanged for our key is always a real transition, so a second "down"
                // means the release was lost without a tap-disabled event (the key came up
                // during sleep or screen lock). Emit the missed release, then this press,
                // rather than swallowing the press and leaving the user talking to nothing.
                Log.hotkey.error("\(self.key.displayName, privacy: .public) down while already down; emitting the missed release")
                onRelease?()
                onPress?()
            } else if pressed != isPressed {
                isPressed = pressed
                Log.hotkey.debug("\(self.key.displayName, privacy: .public) \(pressed ? "down" : "up", privacy: .public)")
                if pressed {
                    onPress?()
                    // The other order: the erase key was already down when push to talk went
                    // down. Its down reached the app, so its up must too (no swallow flag).
                    if eraseKey != .off, isEraseKeyDown(eraseKey) {
                        Log.hotkey.info("erase key already down as \(self.key.displayName, privacy: .public) went down")
                        onErase?()
                    }
                } else {
                    onRelease?()
                }
            }
            return key.consumesEvent
        default:
            return false
        }
    }

    /// The erase modifier's own `.flagsChanged` (§6.16). It fires only while push to talk is
    /// both believed down and physically down, so a stale `isPressed` cannot turn every Right
    /// Command into an erase. A down that passes through clears the swallow flag, so a lost up
    /// can never make Sotto eat a later ordinary Command up and leave Command stuck in the app.
    private func handleEraseModifier(down: Bool) -> Bool {
        if down {
            let physicallyHeld = isPressed && isKeyDown(key)
            guard physicallyHeld else {
                if isPressed {
                    Log.hotkey.info(
                        "erase key ignored: \(self.key.displayName, privacy: .public) is believed down but does not read as physically down"
                    )
                }
                eraseModifierSwallowed = false
                return false
            }
            if !eraseModifierSwallowed {
                eraseModifierSwallowed = true
                Log.hotkey.info(
                    "erase key \(self.eraseKey.displayName, privacy: .public) while \(self.key.displayName, privacy: .public) held"
                )
                onErase?()
            }
            return true
        }
        guard eraseModifierSwallowed else {
            return false
        }
        eraseModifierSwallowed = false
        return true
    }

    /// While the tap was disabled it delivered no events, so a release that happened in that
    /// window produced no `.flagsChanged` and `isPressed` is stale-high: the utterance would
    /// never end and the mic would stay hot. On re-enable, compare against the real key state
    /// and emit the missed release. Only the release direction is reconciled; a missed press
    /// is left alone rather than start recording from a key the user is merely still holding.
    private func reconcilePressedState() {
        if eraseModifierSwallowed, !isEraseKeyDown(eraseKey) {
            eraseModifierSwallowed = false
            Log.hotkey.info("erase key up was lost while the tap was disabled; nothing left to swallow")
        }
        guard isPressed, !isKeyDown(key) else {
            return
        }
        Log.hotkey.error("reconciled a missed release for \(self.key.displayName, privacy: .public) after the tap was re-enabled")
        isPressed = false
        onRelease?()
    }
}

/// The C callback for the event tap. It only ever runs on the main thread, because the
/// tap's run loop source is added to the main run loop.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    // Reduce the event to plain values before crossing into the main actor; the CGEvent
    // itself stays on this side of the boundary.
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    // This is the single permitted use of assumeIsolated in Sotto. The compiler cannot see
    // that CGEvent invokes a main-run-loop tap callback on the main thread, but it does,
    // and assumeIsolated asserts exactly that (it traps rather than hopping if ever wrong).
    let swallow = MainActor.assumeIsolated {
        monitor.handle(type: type, keyCode: keyCode, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
