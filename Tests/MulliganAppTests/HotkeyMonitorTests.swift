import CoreGraphics
import Testing
@testable import Mulligan

/// The event tap itself needs Accessibility and real events, so these drive `handle`
/// directly with plain values (the same reduction the C callback performs) and a fake
/// key-state probe, exercising the reconciliation that recovers a release lost while the
/// tap was disabled.
@MainActor
@Suite
struct HotkeyMonitorTests {
    private func pressEvent(_ key: PushToTalkKey) -> (CGEventType, Int64, CGEventFlags) {
        (.flagsChanged, key.keyCode, key.flag)
    }

    @Test func missedReleaseIsReconciledWhenTheTapReenables() {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        var keyDown = false
        monitor.isKeyDown = { _ in keyDown }
        var presses = 0
        var releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }

        // The key goes down through a normal flagsChanged event.
        keyDown = true
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        #expect(presses == 1)
        #expect(releases == 0)

        // It is released while the tap is disabled: no flagsChanged arrives, only the
        // re-enable. Reconciliation must emit the missed release so the mic does not stay hot.
        keyDown = false
        _ = monitor.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        #expect(releases == 1)
        #expect(presses == 1)

        // A second re-enable with the key already up must not emit a duplicate release.
        _ = monitor.handle(type: .tapDisabledByUserInput, keyCode: 0, flags: [])
        #expect(releases == 1)
    }

    @Test func noSpuriousReleaseWhileTheKeyIsStillHeld() {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        var keyDown = true
        monitor.isKeyDown = { _ in keyDown }
        var releases = 0
        monitor.onPress = {}
        monitor.onRelease = { releases += 1 }

        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        // The tap flaps but the user is still physically holding: no release.
        _ = monitor.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        #expect(releases == 0)
    }

    @Test func pressAfterAReleaseLostWithoutATapEventStillStartsDictation() {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        monitor.isKeyDown = { _ in true }
        var events: [String] = []
        monitor.onPress = { events.append("press") }
        monitor.onRelease = { events.append("release") }

        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        // The key comes up during sleep or screen lock: no flagsChanged and no tap-disabled
        // event arrive, so the monitor still believes the key is down. The next real press
        // is a flagsChanged for our key carrying our flag again; it must not be dropped.
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        #expect(events == ["press", "release", "press"])
    }

    @Test func releaseWhileAlreadyUpIsIgnored() {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        monitor.isKeyDown = { _ in false }
        var releases = 0
        monitor.onPress = {}
        monitor.onRelease = { releases += 1 }

        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        #expect(releases == 0)
    }
    // MARK: Erase modifier (§6.16)

    /// The erase key's own event. Like a real one it carries every modifier held at that
    /// moment, including push to talk's device bit while the board says it is down.
    private func erase(
        _ down: Bool, _ board: KeyBoard, _ key: EraseKey = .rightCommand, ptt: PushToTalkKey = .rightOption
    ) -> (CGEventType, Int64, CGEventFlags) {
        var flags: CGEventFlags = down ? key.flag! : []
        if board.pttDown {
            flags.formUnion(ptt.flag)
        }
        return (.flagsChanged, key.keyCode!, flags)
    }

    /// Push to talk going down, carrying the erase key's bit when the board says it is down.
    private func pttDown(_ board: KeyBoard, _ key: PushToTalkKey = .rightOption) -> (CGEventType, Int64, CGEventFlags) {
        var flags = key.flag
        if board.eraseDown {
            flags.formUnion(EraseKey.rightCommand.flag!)
        }
        return (.flagsChanged, key.keyCode, flags)
    }

    private func armed(pttDown: Bool = true, eraseDown: Bool = false) -> (HotkeyMonitor, KeyBoard) {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        monitor.eraseKey = .rightCommand
        let board = KeyBoard()
        board.pttDown = pttDown
        board.eraseDown = eraseDown
        monitor.isKeyDown = { _ in board.pttDown }
        monitor.isEraseKeyDown = { _ in board.eraseDown }
        monitor.onPress = { board.events.append("press") }
        monitor.onRelease = { board.events.append("release") }
        monitor.onErase = { board.events.append("erase") }
        return (monitor, board)
    }

    private func send(_ monitor: HotkeyMonitor, _ event: (CGEventType, Int64, CGEventFlags)) -> Bool {
        monitor.handle(type: event.0, keyCode: event.1, flags: event.2)
    }

    @Test func eraseDownWhileHeldFiresOnceAndIsSwallowedWithItsUp() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        #expect(send(monitor, erase(true, board)))
        #expect(send(monitor, erase(false, board)))
        #expect(board.events == ["press", "erase"])
    }

    @Test func eraseUpIsSwallowedAfterPushToTalkWasReleasedFirst() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        _ = send(monitor, erase(true, board))
        board.pttDown = false
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        #expect(send(monitor, erase(false, board)))
        #expect(board.events == ["press", "erase", "release"])
    }

    @Test func eraseKeyWithoutPushToTalkPassesAndFiresNothing() {
        let (monitor, board) = armed(pttDown: false)
        #expect(!send(monitor, erase(true, board)))
        #expect(!send(monitor, erase(false, board)))
        #expect(board.events.isEmpty)
    }

    @Test func aStalePressedStateDoesNotTurnCommandIntoErase() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        board.pttDown = false  // released, but the up was lost: the Command event lacks its bit
        #expect(!send(monitor, erase(true, board)))
        #expect(board.events == ["press"])
    }

    @Test func aRepeatedEraseDownWithoutAnUpFiresOnce() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        _ = send(monitor, erase(true, board))
        #expect(send(monitor, erase(true, board)))
        #expect(board.events == ["press", "erase"])
    }

    @Test func eraseKeyFirstThenPushToTalkErasesAndPassesTheEraseUp() {
        let (monitor, board) = armed(eraseDown: true)
        _ = send(monitor, pttDown(board))
        #expect(board.events == ["press", "erase"])
        #expect(!send(monitor, erase(false, board)))
    }

    @Test func aPassedThroughDownClearsAStaleSwallowFlag() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        _ = send(monitor, erase(true, board))  // its up is then lost
        board.pttDown = false
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        #expect(!send(monitor, erase(true, board)))   // an ordinary Command down reaches the app
        #expect(!send(monitor, erase(false, board)))  // and so must its up
    }

    @Test func tapReenableClearsALostEraseUp() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        _ = send(monitor, erase(true, board))
        board.eraseDown = false
        _ = monitor.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        board.pttDown = false
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        #expect(!send(monitor, erase(false, board)))
    }

    @Test func stopClearsTheSwallowFlag() {
        let (monitor, board) = armed()
        _ = send(monitor, pttDown(board))
        _ = send(monitor, erase(true, board))
        monitor.stop()
        board.pttDown = false
        #expect(!send(monitor, erase(false, board)))
    }

    @Test func eraseOffFiresNothing() {
        let (monitor, board) = armed()
        monitor.eraseKey = .off
        _ = send(monitor, pttDown(board))
        #expect(!send(monitor, erase(true, board)))
        #expect(board.events == ["press"])
    }

    /// What the user's Mac does (2026-09-27): the key-state probe reports a swallowed
    /// modifier as up while it is held. The event's own flags are the truth.
    @Test func eraseFiresWhenTheKeyStateProbeCannotSeeTheHeldKey() {
        let (monitor, board) = armed()
        monitor.isKeyDown = { _ in false }
        _ = send(monitor, pttDown(board))
        #expect(send(monitor, erase(true, board)))
        #expect(board.events == ["press", "erase"])
    }

    @Test func theOtherOrderFiresWhenTheKeyStateProbeCannotSeeTheEraseKey() {
        let (monitor, board) = armed(eraseDown: true)
        monitor.isEraseKeyDown = { _ in false }
        _ = send(monitor, pttDown(board))
        #expect(board.events == ["press", "erase"])
    }

    @Test func aConflictingPairNeverSwallowsPushToTalk() {
        let (monitor, board) = armed()
        monitor.eraseKey = .rightOption
        _ = send(monitor, pttDown(board))
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        #expect(board.events == ["press", "release"])
    }

    @Test func rightOptionAsTheEraseKeyWorksWithRightCommandAsPushToTalk() {
        let (monitor, board) = armed()
        monitor.key = .rightCommand
        monitor.eraseKey = .rightOption
        _ = send(monitor, pttDown(board, .rightCommand))
        #expect(send(monitor, erase(true, board, .rightOption, ptt: .rightCommand)))
        #expect(board.events == ["press", "erase"])
    }
}

/// Physical key state and the callbacks a test observed. `pttDown` also feeds the monitor's
/// key-state probe, which only reconciliation uses.
@MainActor
private final class KeyBoard {
    var events: [String] = []
    var pttDown = true
    var eraseDown = false
}
