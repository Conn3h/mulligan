# Mulligan

Push-to-talk dictation for macOS, on-device, native Swift 6. Read `docs/SPEC.md` before
changing anything; it is the source of truth for v1 and every interface in it is a contract.

## Rules

- **Clean room.** Mulligan is written from the spec. Do not read, search, or copy code from
  any other dictation project, on this machine or elsewhere. Author prompts, test vectors
  and copy fresh.
- **Build with `make`**, never bare `swift build`. Products live in `~/Library/Caches/MulliganBuild`.
  `make test` runs the library tests; `make install` signs and installs to /Applications.
- **Launch only from the main checkout.** `make run` and `make install` refuse to work in a
  linked worktree or with an overridden `STAGE`; a worktree builds and tests in its own
  stage under `~/Library/Caches/MulliganBuild/worktrees/`. Never `open` a staged `Mulligan.app`
  by hand and never stage one anywhere else. Every opened copy registers with
  LaunchServices under the same bundle id, and while the Accessibility grant is missing
  each one pops the system prompt.
- **Never sign ad-hoc.** `make app` fails without a Developer ID Application identity. Do
  not work around it with `SIGN_ID=-`; an ad-hoc signature changes every build and resets
  the grant.
- **Never run `tccutil`.** Resetting the row wipes the grant and every launch prompts until
  the user re-grants it in System Settings. That command is the user's, never an agent's.
- **Swift 6 language mode, strict concurrency.** `MainActor.assumeIsolated` is allowed in
  exactly one place: the C event-tap callback in `HotkeyMonitor`, with a comment.
- **Tests first for the library targets** (`MulliganText`, `MulliganDictionary`). Confirm a new
  test fails before making it pass.
- **Every failure is logged.** No `try?` without a log line. Non-user values are logged
  with `privacy: .public`. Transcript text is never logged; log its length.
- **No literal values in views.** Colours, sizes, radii, fonts and durations come from
  `DS` in `UI/DesignSystem.swift`. Add a token rather than inlining a number.
- **Red means recording** and nothing else. Meter colours appear only in meters. No
  gradients, no glow.
- **The HUD never becomes key.** Do not change `canBecomeKey` / `canBecomeMain`.
- **No GitHub Actions** for now. Tests run locally.
- Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`). No AI attribution
  in commit messages.
- No emojis in code, comments, or logs.

## Diagnostics

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.conn3h.sotto"' --style compact
```

Spell out `/usr/bin/log`; `log` is often shadowed. If the Accessibility grant wedges after
a signing change, the user (not an agent) resets only this app's row and then quits System
Settings fully:

```bash
tccutil reset Accessibility com.conn3h.sotto
```
