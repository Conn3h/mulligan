Read-only review completed; no files changed. Findings are spec/code inferences unless explicitly marked verified.

1. **P0 — §6.16, Plan:** Matching text is not insertion identity. After moving to another occurrence or another field in the same process, identical preceding text passes despite `untouched == false`. Store the originating element and insertion range; invalidate on intervening input/focus changes, and require that same range.

2. **P0 — §§6.8, 6.16, 10:** `inserted/outgoing` is what Sotto sent, not necessarily what landed. Current `ExpectedWrite` explicitly accepts conversion/autocorrection. An unreadable target can shorten text, create a paste object, or process IME/bracketed paste differently; 300 Characters establishes no safe deletion bound. Refuse unverified deletion unless target-specific receipt and deletion semantics are established. Claude Code’s safe threshold remains unverified.

3. **P0 — §6.16, Executing:** If setting the selection succeeds but read-back is delayed, the counted-backspace fallback deletes the entire selection first, then older text. An adjusted selection is similarly dangerous. Remove that fallback: require the exact selection and current target, otherwise refuse. Post-deletion polling cannot undo damage.

4. **P0 — §§6.8, 6.16, Recording/Executing:** Current paste returns `.landed` immediately after posting ⌘V, before the asynchronous paste completes. `awaitIdle()` explicitly excludes the restore window, so erase can overtake insertion. Frontmost PID recorded afterward can also misattribute an AX insertion during verification. Capture target identity before mutation and serialize erase behind confirmed delivery; elapsed clipboard-restoration time alone is insufficient.

5. **P0 — §6.16, Executing:** PID/input checks happen only before execution. Clicking, changing focus, or switching apps during the 2-ms yields sends remaining backspaces to unrelated text. Use a target-bound mutation where available; otherwise abort on an input/focus epoch change before every emission. Do not promise safety where already-queued global events cannot be recalled.

6. **P0 — §§6.7, 6.16, Timeouts:** Both delivery and erasure may outlive their timeout. A delivery still formatting is invisible to `awaitIdle()`; an abandoned eraser can delete after another dictation starts. Serialize mutations under an operation token that timeouts/deactivation revoke before further side effects, while separately completing clipboard cleanup. Test late completions after a new generation.

7. **P0 — §6.16, Hotkey:** Disabling the nonmodifier tap on push-to-talk release leaks Delete autorepeats and the matching key-up while Delete remains held. Those repeats can erase older text. Keep suppression active until every swallowed physical key is released, including across reload/stop, with explicit recovery for lost releases.

8. **P1 — §6.16, Hotkey:** With `eraseKey == .delete`, the second tap swallows Sotto’s own synthetic backspaces; only the passive monitor exempts the marker. Apple’s CGEvent headers verify HID-posted events traverse subsequent taps. Bypass marked events before hotkey matching. Add an integration test proving an actual deletion and no recursive `onErase`.

9. **P1 — §§6.4, 6.16, Hotkey:** Swallowing modifier `flagsChanged` does not clear Command/Option flags on later forwarded key/mouse events; shortcuts can still fire. Lost-up recovery also reconciles only push-to-talk. Specify modifier-flag sanitization and both keys’ physical-state reconciliation. Apple headers verify keycode 54 and bits 0x10/0x40; simultaneous chord delivery remains untested and needs a macOS 26 physical-event trace.

10. **P1 — §§6.7, 6.16, Controller:** Release handling begins only in `.erasing`, after waiting for the previous terminal task; a release during that wait can leave restart pending. Existing terminal cleanup also publishes idle and consumes queued presses. Enter erase ownership before the first suspension; prevent terminal dequeue, and use one current-hold token for restart, release/repress, reload, and deactivate.

11. **P1 — §6.16, AX ranges:** NFC equality does not preserve UTF-16 length. An NFD record converted to NFC at field start can compare equal while `location - record.utf16.count` is negative. Determine the actual matched target range before normalization, validate bounds, and delete its raw UTF-16 extent; test both normalization directions.

12. **P1 — §6.16, eraseTimeout:** Synchronous AX calls on MainActor can block the actor running the timeout and event taps. A three-second task timer cannot bound them. Apple’s `AXUIElementSetMessagingTimeout` header verifies a separate AX messaging timeout exists. Use bounded AX calls on a dedicated executor and an overall deadline.

13. **P2 — §§6.16, 10, Monitoring:** [Apple documents](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)) asynchronous global callbacks excluding own-app events; [Apple DTS](https://developer.apple.com/forums/thread/828052) says Accessibility includes listening, so an additional Input Monitoring requirement is not established. Monitor health, callback ordering, and marker preservation on macOS 26 are unverified. Fail closed on unavailable monitoring, preserve input epochs across insertion waits, and test actual posted-event delivery with metadata-only logs.

14. **P2 — §§6.6a, 6.11:** Terms-only removes recognition hints from correction-only dictionaries; deterministic correction cannot recover arbitrary new recognition variants. Current DictionaryCorrector does implement the stated leftmost-longest context example. Document separate term entries for desired vocabulary and add accuracy regressions covering correction-only dictionaries and engine-specific bias lists.

Codex session ID: 01a0e461-49b8-7360-b8b4-2f31843be325
Resume in Codex: codex resume 01a0e461-49b8-7360-b8b4-2f31843be325
