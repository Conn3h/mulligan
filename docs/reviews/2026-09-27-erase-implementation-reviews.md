# Erase last dictation: implementation reviews (2026-09-27)

Two read-only reviews ran on the branch at fe4bf6e, before any fixes. Findings are
condensed; the resolution of each follows it.

## Codex

1. **P0. Checks went stale during the modifier wait.** The plan was made, then the eraser
   waited for the erase key to come up, so a caret moved meanwhile was not seen. Fixed in
   7115cd2: the eraser plans again from a fresh read after the wait, and the backspace run
   compares against the record's epoch.
2. **P0. The fallback backspace could reach another field.** It checked the selection on
   the recorded element but posted to whatever had focus. Fixed in 7115cd2:
   `isStillOurSelection` re-checks the app, the input epoch, the focused element, the
   selection and the text right before posting.
3. **P0. A paste record could adopt an older caret.** The caret is read 500 ms after the
   paste, so a click in between moved it. Fixed in 7115cd2: input while the text is landing
   records it without element, window or caret, and the unchanged-input rule then refuses it.
4. **P0. A known element with no caret fell into counted backspaces.** A non-collapsed
   selection was also accepted on the unverified path. Fixed in 41e3f44: a record with an
   element is erased on proof or not at all, and the unverified path requires a caret.
5. **P0. An older paste settling late cleared `superseded`.** Fixed in 7115cd2: deliveries
   carry a generation, and only the current one's landing clears the mark.
6. **P0. The modifier timeout went ahead while the key was still down.** Fixed in 7115cd2:
   the erase now fails and nothing is posted.
7. **P1. Deactivate before the token existed did not cancel the erase.** Fixed in f656780:
   deactivate clears an erase that was requested but not yet started.
8. **P1. A failed key creation was reported as erased.** Fixed in 7115cd2: `postBackspaces`
   returns the count it posted, and a shortfall gives `.interrupted` or `.failed`.

## Independent gate (Sonnet)

No P0 or P1 findings; `make test` passed 345 tests, and the build was clean with no new
warnings. It confirmed a single `MainActor.assumeIsolated` site, no `try?`, and no text in
logs.

1. **P3.** Revoking the token as the erase finishes reports `.failed`. This is deliberate:
   no restart after deactivate.
2. **P3.** The `vocabularyPhrases` doc comment cited the wrong section. Fixed.
3. **P2.** There is no integration test for erase and restate through the real
   `TextInjector`. It relies on AX and real events, so it is covered in hands-on acceptance.
4. **P3.** A record that had an element but now reads as unreadable went to the unverified
   path. Fixed in 41e3f44 (Codex finding 4).

## Codex, rounds two and three (on the fixes)

Round two found six of the eight fixes closed and three gaps in the fixes themselves:
- **A (P1).** Without a running input monitor, a delayed paste caret was still trusted.
  Fixed in bd22863: `TypedDictation.landingIsTrusted` requires the monitor.
- **B (P1).** The generation was sampled at insertion, not at delivery start. Fixed in
  bd22863: `supersede()` returns the generation, and the pipeline passes it to the insert.
- **C (P1).** Pressing the erase modifier again was not seen before posting. Fixed in
  bd22863 for each burst, and completed in 3820d7f: the fallback backspace checks the
  modifier after its last AX read.

Round three confirmed A and B closed and no new P0 or P1 issues. It flagged the check order
in the fallback (C), which 3820d7f closes.
