# Erase-last-dictation spec: independent review (2026-09-27)

Read-only review of the first draft of §6.16 (commits af92e79 and 4227249), checked against
the unchanged code. Findings as reported, condensed; the revised §6.16 answers each one.

1. **P0, Executing.** `awaitIdle()` returns once ⌘V has been posted, but the paste is applied
   asynchronously. Counted backspaces can overtake it and delete older text. Resolved by the
   mutation lane, which waits out `pasteCompletionDelay`.
2. **P0, Recording and Plan.** The target's identity is never recorded. Identical text in
   another field of the same app would be erased, and a Spaces switch between two windows
   of one terminal raises no input event. Resolved by recording the element, window and
   caret, and bumping the epoch on a Space change.
3. **P0, non-modifier erase keys.** Delete autorepeat leaks once the tap is disabled, and
   Sotto's own backspaces would fire `onErase`. Resolved by removing Delete and Escape.
4. **P1, modifier key state.** A lost up leaves `eraseModifierDown` stale, so ⌘ sticks down,
   and a stale `isPressed` turns every Right ⌘ into an erase. Resolved: a pass-through down
   clears the flag, both keys are reconciled, and push to talk must be physically down.
5. **P1, Controller.** `.erasing` has no owning session, and `press()` has no `.erasing`
   case. Resolved: the erase runs in the terminal task, and `pendingPress` drives the
   restart.
6. **P1, stale record.** A delivery that is still running, has failed, or moved focus leaves
   the previous record to be erased. Resolved by marking the record superseded at the start
   of each delivery.
7. **P1, timeout.** An abandoned eraser races later work, and synchronous AX blocks for
   about 6 s. Resolved with a cancellation token, the mutation lane and
   `AXUIElementSetMessagingTimeout`.
8. **P1, keys posted while modifiers are held.** Resolved: posting waits for the erase
   modifier's up, keys carry explicit empty flags, and the spike checks each app.
9. **P2, run-on leading space after restating.** Resolved by restoring `lastInjection`.
10. **P2, Settings.** `didSet` does not run in `init`, and the `eraseKey` owner was
    contradictory. Resolved: `init` repairs the pair, and the controller sets the key.
11. **P2, a selection equal to the insertion** was refused. Resolved: it is now erasable.
12. **P2, Parakeet.** Terms-only dropped the boost for recasing corrections. Resolved by
    excluding only context corrections.
13. **P2, chords and timing.** The suggested 150 ms guard was declined: with Right ⌥ as push
    to talk, ⌥⌘ shortcuts on the right-hand keys are already unavailable. Either key order
    now erases.
14. **P2, shared callback details.** These no longer apply without the second tap.
15. **P3.** The unused `strategy` field was cut; NFC comparison was removed (exact UTF-16
    comparison instead); a refusal now clears the record; the HUD text was added; the
    too-long message now covers line breaks; the paste-collapse thresholds are measured in
    the spike.

Verdict as reported: the shape is right (one level, read-back as proof, refusal as the
default), but the draft was not ready to plan from until findings 1-8 were fixed.
