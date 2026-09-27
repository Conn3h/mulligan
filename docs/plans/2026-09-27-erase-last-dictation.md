# Erase Last Dictation Implementation Plan

> **For agentic workers:** Implement this plan task-by-task with a review checkpoint after each task (fresh subagent per task, or inline execution with checkpoints). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold push to talk and tap the neighbouring right-hand modifier to erase exactly the text Sotto last typed and start listening again. Keep context corrections out of Parakeet's bias list.

**Architecture:**
- A pure `ErasePlan` decides whether and how to erase from a record of what was typed and a fresh read of the target.
- `DictationEraser` owns the record, an input epoch fed by a passive global monitor, and the execution against a `EraseTarget` seam.
- `TextInjector` inserts and the eraser erases on one `MutationLane`, so they never overlap.
- The controller runs the erase as one more step of the cancelled utterance's terminal task, and restarts through the existing `pendingPress`.

**Tech Stack:** Swift 6 (strict concurrency), AppKit, ApplicationServices (AX), CoreGraphics event taps, Swift Testing, `make test`.

## Global Constraints

- SPEC.md is the contract: §6.16, plus the §6.2, §6.4, §6.6a, §6.7, §6.11, §6.14 and §10 edits made on this branch. Where this plan and the spec differ, fix the spec in the same commit and say so in its message.
- Build and test only with `make build` / `make test`, never bare `swift build`. Never `make run` or `make install` from a worktree. Never sign ad-hoc. Never run `tccutil`.
- Swift 6 language mode, strict concurrency. `MainActor.assumeIsolated` stays in exactly one place: the C event-tap callback in `HotkeyMonitor`.
- Tests first. Confirm each new test fails before making it pass.
- Every failure is logged; no `try?` without a log line. Non-user values use `privacy: .public`. Transcript text is never logged: log lengths only. This applies to erased text too.
- No literal colours, sizes, radii, fonts or durations in views; use `DS` tokens.
- No emojis in code, comments or logs. Conventional commits, no AI attribution.
- Baseline: `make test` passes 255 tests in 26 suites on `feat/erase-last-dictation` at 1006ac8.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SottoDictionary/DictionaryCorrector.swift` (modify) | `isContextCorrection`, `vocabularyPhrases` |
| `Sources/Sotto/Dictionary/DictionaryStore.swift` (modify) | `vocabularyPhrases` property |
| `Sources/Sotto/App/AppComposition.swift` (modify) | Parakeet gets `vocabularyPhrases`; eraser wiring |
| `Sources/Sotto/Core/EraseKey.swift` (create) | `EraseKey` enum and conflict rules |
| `Sources/Sotto/Support/Settings.swift` (modify) | `eraseKey`, conflict repair |
| `Sources/Sotto/Core/HotkeyMonitor.swift` (modify) | erase modifier handling in the flagsChanged tap |
| `Sources/Sotto/Core/ErasePlan.swift` (create) | `AXElementID`, `TypedDictation`, `ReadBack`, `EraseOutcome`, `ErasePlan.decide` (pure) |
| `Sources/Sotto/Core/MutationLane.swift` (create) | serial lane for target mutations |
| `Sources/Sotto/Core/SyntheticEvent.swift` (create) | marker for Sotto-posted events |
| `Sources/Sotto/Core/TextInjector.swift` (modify) | lane, marker, target capture, typed record, lastInjection snapshot |
| `Sources/Sotto/Core/UtterancePipeline.swift` (modify) | supersede the record at delivery start |
| `Sources/Sotto/Core/DictationEraser.swift` (create) | record, epoch, execution, token |
| `Sources/Sotto/Core/SystemEraseTarget.swift` (create) | real AX, key-posting and input-monitor implementations |
| `Sources/Sotto/Core/DictationController.swift` (modify) | `.erasing`, `.erased`, `onErase` |
| `Sources/Sotto/UI/SettingsWindow.swift`, `MenuBarContent.swift`, `HUDView.swift`, `App/SottoApp.swift` (modify) | picker, menu line, HUD text, start-up |
| `Tests/SottoDictionaryTests/DictionaryCorrectorBiasTests.swift`, `vectors.json` (modify) | vocabulary tests, context vector |
| `Tests/SottoAppTests/EraseKeyTests.swift`, `ErasePlanTests.swift`, `MutationLaneTests.swift`, `DictationEraserTests.swift` (create) | unit tests |
| `Tests/SottoAppTests/SettingsTests.swift`, `HotkeyMonitorTests.swift`, `Fakes.swift`, `DictationControllerTests.swift`, `DictationOrderTests.swift` (modify) | extended tests and fakes |

---

### Task 1: Context corrections stay out of Parakeet's bias list

**Files:**
- Modify: `Sources/SottoDictionary/DictionaryCorrector.swift` (after `biasPhrases`, ~line 125)
- Modify: `Sources/Sotto/Dictionary/DictionaryStore.swift:256-258`
- Modify: `Sources/Sotto/App/AppComposition.swift` (the `.parakeet` case)
- Test: `Tests/SottoDictionaryTests/DictionaryCorrectorBiasTests.swift`, `Tests/SottoDictionaryTests/vectors.json`

**Interfaces:**
- Produces: `DictionaryCorrector.isContextCorrection(_ entry: DictionaryEntry) -> Bool`, `DictionaryCorrector.vocabularyPhrases(from: [DictionaryEntry]) -> [String]`, `DictionaryStore.vocabularyPhrases: [String]`.

- [ ] **Step 1: Write the failing tests.** Append this suite to `DictionaryCorrectorBiasTests.swift`:

```swift
@Suite("DictionaryCorrector.vocabularyPhrases")
struct DictionaryCorrectorVocabularyTests {
    @Test(arguments: [
        ("security codex", "security code"),
        ("cloud session", "Claude session"),
        ("hard codex", "hard-coded"),
        ("cloud code", "Claude Code"),
    ])
    func sharedWordMultiWordCorrectionsAreContext(_ hear: String, _ write: String) {
        #expect(DictionaryCorrector.isContextCorrection(.correction(hear: hear, write: write)))
    }

    @Test(arguments: [
        ("clawed", "Claude"),
        ("codex", "Codex"),
        ("burr cell", "Vercel"),
        ("versal app", "Vercel dashboard"),
    ])
    func otherCorrectionsAreNotContext(_ hear: String, _ write: String) {
        #expect(!DictionaryCorrector.isContextCorrection(.correction(hear: hear, write: write)))
    }

    @Test func termsAreNeverContext() {
        #expect(!DictionaryCorrector.isContextCorrection(.term("Claude Code")))
    }

    @Test func contextTargetsAreDropped() {
        let entries: [DictionaryEntry] = [
            .term("Codex"),
            .correction(hear: "security codex", write: "security code"),
            .correction(hear: "clawed", write: "Claude"),
        ]
        #expect(DictionaryCorrector.vocabularyPhrases(from: entries) == ["Codex", "Claude"])
    }

    @Test func aContextTargetNamedElsewhereStillBoosts() {
        let entries: [DictionaryEntry] = [
            .correction(hear: "cloud code", write: "Claude Code"),
            .term("Claude Code"),
        ]
        #expect(DictionaryCorrector.vocabularyPhrases(from: entries) == ["Claude Code"])
    }

    @Test func matchesBiasPhrasesWhenThereAreNoContextCorrections() {
        let entries: [DictionaryEntry] = [
            .term("Alpha"), .correction(hear: "beeta", write: "Beta"), .term("alpha"),
            DictionaryEntry(kind: .term, write: "Off", isEnabled: false),
        ] + (0..<120).map { .term("T\($0)") }
        #expect(DictionaryCorrector.vocabularyPhrases(from: entries) == DictionaryCorrector.biasPhrases(from: entries))
    }
}
```

Append this vector to `vectors.json`, before the closing `]`. Add a comma after the previous object.

```json
  {
    "name": "a longer context trigger beats a shorter recasing one",
    "entries": [
      { "kind": "correction", "hear": "codex", "write": "Codex" },
      { "kind": "correction", "hear": "security codex", "write": "security code" }
    ],
    "input": "I need a security Codex and codex review",
    "expected": "I need a security code and Codex review",
    "applied": [
      { "from": "security Codex", "to": "security code", "count": 1 },
      { "from": "codex", "to": "Codex", "count": 1 }
    ]
  }
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run: `make test 2>&1 | grep -E "vocabulary|context|error:" | head`. Expected: compile error, because `isContextCorrection` and `vocabularyPhrases` are undefined. The vector should already pass, since leftmost-longest exists; if it fails, stop and report, because the spec claim is wrong.

- [ ] **Step 3: Implement.** In `DictionaryCorrector.swift`, after `biasPhrases`:

```swift
    /// A correction that fixes a word only in the company of another: both sides have at
    /// least two words and share one ("security codex -> security code"). Its target must not
    /// feed vocabulary boosting, which would push the engine toward the phrase it exists to undo.
    public static func isContextCorrection(_ entry: DictionaryEntry) -> Bool {
        guard entry.kind == .correction else { return false }
        let hearWords = words(entry.hear)
        let writeWords = words(entry.write)
        guard hearWords.count >= 2, writeWords.count >= 2 else { return false }
        return !Set(hearWords).isDisjoint(with: writeWords)
    }

    /// `biasPhrases` over every entry that is not a context correction: Parakeet's list.
    public static func vocabularyPhrases(from entries: [DictionaryEntry]) -> [String] {
        biasPhrases(from: entries.filter { !isContextCorrection($0) })
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" })
            .map(String.init)
    }
```

In `DictionaryStore.swift`, after `biasPhrases`:

```swift
    /// Parakeet's bias list (§6.6a): `biasPhrases` without context corrections' targets.
    var vocabularyPhrases: [String] {
        DictionaryCorrector.vocabularyPhrases(from: entries)
    }
```

In `AppComposition.swift`, change the Parakeet line to `return ParakeetSpeechEngine(biasPhrases: DictionaryStore.shared.vocabularyPhrases)`.

- [ ] **Step 4: Run the tests and confirm they pass.** Run: `make test 2>&1 | tail -3`. Expected: all pass, 255 + 12 = 267 or more tests.

- [ ] **Step 5: Commit.** Run `git add -A Sources/SottoDictionary Sources/Sotto/Dictionary Sources/Sotto/App/AppComposition.swift Tests/SottoDictionaryTests && git commit -m "feat(dictionary): keep context corrections out of Parakeet's bias list"`.

---

### Task 2: `EraseKey` and the Settings pair

**Files:**
- Create: `Sources/Sotto/Core/EraseKey.swift`
- Modify: `Sources/Sotto/Support/Settings.swift`
- Test: `Tests/SottoAppTests/EraseKeyTests.swift` (create), `Tests/SottoAppTests/SettingsTests.swift`

**Interfaces:**
- Produces: `enum EraseKey: String, CaseIterable, Sendable { case rightCommand, rightOption, off }` with `keyCode: Int64?`, `flag: CGEventFlags?`, `displayName: String`, `conflicts(with: PushToTalkKey) -> Bool`, `static func alternative(to: PushToTalkKey) -> EraseKey`; `Settings.eraseKey: EraseKey`.

- [ ] **Step 1: Write the failing tests.** `EraseKeyTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import Sotto

struct EraseKeyTests {
    @Test func modifiersUseTheSameCodesAndBitsAsPushToTalk() {
        #expect(EraseKey.rightCommand.keyCode == PushToTalkKey.rightCommand.keyCode)
        #expect(EraseKey.rightCommand.flag == PushToTalkKey.rightCommand.flag)
        #expect(EraseKey.rightOption.keyCode == PushToTalkKey.rightOption.keyCode)
        #expect(EraseKey.rightOption.flag == PushToTalkKey.rightOption.flag)
        #expect(EraseKey.off.keyCode == nil)
        #expect(EraseKey.off.flag == nil)
    }

    @Test func conflictsOnlyWithTheSamePhysicalKey() {
        #expect(EraseKey.rightCommand.conflicts(with: .rightCommand))
        #expect(!EraseKey.rightCommand.conflicts(with: .rightOption))
        #expect(EraseKey.rightOption.conflicts(with: .rightOption))
        #expect(!EraseKey.rightOption.conflicts(with: .fn))
        #expect(!EraseKey.off.conflicts(with: .rightOption))
    }

    @Test func alternativeIsTheOtherRightModifier() {
        #expect(EraseKey.alternative(to: .rightOption) == .rightCommand)
        #expect(EraseKey.alternative(to: .rightCommand) == .rightOption)
        #expect(EraseKey.alternative(to: .fn) == .rightCommand)
    }
}
```

Append to `SettingsTests`:

```swift
    @Test func erasePairDefaultsToRightOptionAndRightCommand() {
        let settings = Settings(defaults: makeDefaults())
        #expect(settings.pushToTalkKey == .rightOption)
        #expect(settings.eraseKey == .rightCommand)
    }

    @Test func switchingPushToTalkOntoTheEraseKeyMovesTheEraseKey() {
        let settings = Settings(defaults: makeDefaults())
        settings.pushToTalkKey = .rightCommand
        #expect(settings.eraseKey == .rightOption)
        // Back to Right Option: the erase key (now Right Option) conflicts again and moves back.
        settings.pushToTalkKey = .rightOption
        #expect(settings.eraseKey == .rightCommand)
    }

    @Test func fnKeepsTheEraseKey() {
        let settings = Settings(defaults: makeDefaults())
        settings.eraseKey = .off
        settings.pushToTalkKey = .fn
        #expect(settings.eraseKey == .off)
    }

    @Test func aConflictingStoredPairIsRepairedAndPersistedOnLoad() {
        let defaults = makeDefaults()
        defaults.set("rightCommand", forKey: "pushToTalkKey")
        defaults.set("rightCommand", forKey: "eraseKey")
        let settings = Settings(defaults: defaults)
        #expect(settings.eraseKey == .rightOption)
        #expect(defaults.string(forKey: "eraseKey") == "rightOption")
    }
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run: `make test 2>&1 | grep -E "error:" | head -3`. Expected: `EraseKey` is undefined.

- [ ] **Step 3: Implement.** `EraseKey.swift`:

```swift
import CoreGraphics

/// The key that, tapped while push to talk is held, erases the last dictation (§6.16).
/// Always a right-hand modifier: modifiers arrive as `.flagsChanged` on the tap Sotto
/// already has, so erase needs no key-down tap and can never leak key repeats into apps.
enum EraseKey: String, CaseIterable, Sendable {
    case rightCommand
    case rightOption
    case off

    var keyCode: Int64? {
        switch self {
        case .rightCommand: PushToTalkKey.rightCommand.keyCode
        case .rightOption: PushToTalkKey.rightOption.keyCode
        case .off: nil
        }
    }

    var flag: CGEventFlags? {
        switch self {
        case .rightCommand: PushToTalkKey.rightCommand.flag
        case .rightOption: PushToTalkKey.rightOption.flag
        case .off: nil
        }
    }

    var displayName: String {
        switch self {
        case .rightCommand: PushToTalkKey.rightCommand.displayName
        case .rightOption: PushToTalkKey.rightOption.displayName
        case .off: "Off"
        }
    }

    func conflicts(with key: PushToTalkKey) -> Bool {
        keyCode == key.keyCode
    }

    /// The erase key to fall back to when push to talk moves onto the current one.
    static func alternative(to key: PushToTalkKey) -> EraseKey {
        key == .rightCommand ? .rightOption : .rightCommand
    }
}
```

In `Settings.swift`:
- Add `static let eraseKey = "eraseKey"` to `Key`.
- Add the property:

```swift
    var eraseKey: EraseKey {
        didSet { defaults.set(eraseKey.rawValue, forKey: Key.eraseKey) }
    }
```

- Extend `pushToTalkKey`'s `didSet` to:

```swift
        didSet {
            defaults.set(pushToTalkKey.rawValue, forKey: Key.pushToTalkKey)
            if eraseKey.conflicts(with: pushToTalkKey) {
                eraseKey = EraseKey.alternative(to: pushToTalkKey)
            }
        }
```

- In `init`, after `pushToTalkKey` is assigned (`didSet` does not run in `init`):

```swift
        let storedErase = defaults.string(forKey: Key.eraseKey).flatMap(EraseKey.init(rawValue:)) ?? .rightCommand
        if storedErase.conflicts(with: pushToTalkKey) {
            eraseKey = EraseKey.alternative(to: pushToTalkKey)
            defaults.set(eraseKey.rawValue, forKey: Key.eraseKey)
        } else {
            eraseKey = storedErase
        }
```


- [ ] **Step 4: Run the tests and confirm they pass.** Run `make test 2>&1 | tail -3`.
- [ ] **Step 5: Commit.** Run `git commit -am "feat(settings): add the erase key, never the push-to-talk key"` after `git add` of the new files.

---

### Task 3: Erase modifier in the hotkey tap

**Files:**
- Modify: `Sources/Sotto/Core/HotkeyMonitor.swift` (protocol, properties, `handle`, `reconcilePressedState`, `stop`)
- Modify: `Tests/SottoAppTests/Fakes.swift` (`FakeHotkey`)
- Test: `Tests/SottoAppTests/HotkeyMonitorTests.swift`

**Interfaces:**
- Consumes: `EraseKey` (Task 2).
- Produces: `HotkeySource.eraseKey: EraseKey { get set }`, `HotkeySource.onErase: (() -> Void)? { get set }`, `HotkeyMonitor.isEraseKeyDown: (EraseKey) -> Bool` (probe, injectable), `FakeHotkey.erase()` (fires `onErase`).

- [ ] **Step 1: Write the failing tests.** Append to `HotkeyMonitorTests`:

```swift
    private func erase(_ down: Bool, _ key: EraseKey = .rightCommand) -> (CGEventType, Int64, CGEventFlags) {
        (.flagsChanged, key.keyCode!, down ? key.flag! : [])
    }

    private func armed(pttDown: Bool = true, eraseDown: Bool = false) -> (HotkeyMonitor, Counter) {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        monitor.eraseKey = .rightCommand
        let counter = Counter()
        monitor.isKeyDown = { _ in counter.pttDown }
        monitor.isEraseKeyDown = { _ in counter.eraseDown }
        counter.pttDown = pttDown
        counter.eraseDown = eraseDown
        monitor.onPress = { counter.events.append("press") }
        monitor.onRelease = { counter.events.append("release") }
        monitor.onErase = { counter.events.append("erase") }
        return (monitor, counter)
    }

    @Test func eraseDownWhileHeldFiresOnceAndIsSwallowedWithItsUp() {
        let (monitor, counter) = armed()
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        let e1 = erase(true)
        #expect(monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2))
        let e2 = erase(false)
        #expect(monitor.handle(type: e2.0, keyCode: e2.1, flags: e2.2))
        #expect(counter.events == ["press", "erase"])
    }

    @Test func eraseUpIsSwallowedAfterPushToTalkWasReleasedFirst() {
        let (monitor, counter) = armed()
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        let e1 = erase(true)
        _ = monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2)
        counter.pttDown = false
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        let e2 = erase(false)
        #expect(monitor.handle(type: e2.0, keyCode: e2.1, flags: e2.2))
        #expect(counter.events == ["press", "erase", "release"])
    }

    @Test func eraseKeyWithoutPushToTalkPassesAndFiresNothing() {
        let (monitor, counter) = armed(pttDown: false)
        let e1 = erase(true)
        #expect(!monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2))
        let e2 = erase(false)
        #expect(!monitor.handle(type: e2.0, keyCode: e2.1, flags: e2.2))
        #expect(counter.events.isEmpty)
    }

    @Test func aStalePressedStateDoesNotTurnCommandIntoErase() {
        let (monitor, counter) = armed()
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        counter.pttDown = false  // released, but the up was lost
        let e1 = erase(true)
        #expect(!monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2))
        #expect(counter.events == ["press"])
    }

    @Test func aRepeatedEraseDownWithoutAnUpFiresOnce() {
        let (monitor, counter) = armed()
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        let e1 = erase(true)
        _ = monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2)
        #expect(monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2))
        #expect(counter.events == ["press", "erase"])
    }

    @Test func eraseKeyFirstThenPushToTalkErasesAndPassesTheEraseUp() {
        let (monitor, counter) = armed(eraseDown: true)
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        #expect(counter.events == ["press", "erase"])
        let e2 = erase(false)
        #expect(!monitor.handle(type: e2.0, keyCode: e2.1, flags: e2.2))
    }

    @Test func aPassedThroughDownClearsAStaleSwallowFlag() {
        let (monitor, counter) = armed()
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        let e1 = erase(true)
        _ = monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2)  // its up is then lost
        counter.pttDown = false
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        #expect(!monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2))  // ordinary Command down
        let e2 = erase(false)
        #expect(!monitor.handle(type: e2.0, keyCode: e2.1, flags: e2.2))  // its up must reach the app
    }

    @Test func tapReenableClearsALostEraseUp() {
        let (monitor, counter) = armed()
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        let e1 = erase(true)
        _ = monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2)
        counter.eraseDown = false
        _ = monitor.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        counter.pttDown = false
        _ = monitor.handle(type: .flagsChanged, keyCode: PushToTalkKey.rightOption.keyCode, flags: [])
        let e2 = erase(false)
        #expect(!monitor.handle(type: e2.0, keyCode: e2.1, flags: e2.2))
    }

    @Test func eraseOffFiresNothing() {
        let (monitor, counter) = armed()
        monitor.eraseKey = .off
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        let e1 = erase(true)
        #expect(!monitor.handle(type: e1.0, keyCode: e1.1, flags: e1.2))
        #expect(counter.events == ["press"])
    }
```

Add this helper at the bottom of the test file:

```swift
@MainActor
private final class Counter {
    var events: [String] = []
    var pttDown = true
    var eraseDown = false
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** Expected: compile errors for `eraseKey`, `onErase` and `isEraseKeyDown`.

- [ ] **Step 3: Implement.**
- Protocol: add `var eraseKey: EraseKey { get set }` and `var onErase: (() -> Void)? { get set }` to `HotkeySource`.
- `FakeHotkey`: add `var eraseKey: EraseKey = .rightCommand`, `var onErase: (() -> Void)?`, and `func erase() { onErase?() }`.
- `HotkeyMonitor` properties:

```swift
    var eraseKey: EraseKey = .rightCommand
    var onErase: (() -> Void)?
    /// True between an erase-key down Sotto swallowed and its up, which is swallowed too so
    /// the target never sees an up without its down.
    private var eraseModifierSwallowed = false

    /// Physical state of the erase key, by keycode, like `isKeyDown`. Injectable for tests.
    var isEraseKeyDown: (EraseKey) -> Bool = { key in
        guard let code = key.keyCode else { return false }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }
```

- In `handle`, `.flagsChanged` case: keep the existing push-to-talk branch, but after `onPress?()` in the `pressed != isPressed` press branch, add:

```swift
                    // The other order: the erase key was already down when push to talk went
                    // down. Its down reached the app, so its up must too (no swallow flag).
                    if eraseKey != .off, isEraseKeyDown(eraseKey) {
                        onErase?()
                    }
```

  Before the `guard keyCode == key.keyCode` line, insert:

```swift
            if let eraseCode = eraseKey.keyCode, let eraseFlag = eraseKey.flag, keyCode == eraseCode {
                return handleEraseModifier(down: flags.contains(eraseFlag))
            }
```

  Add:

```swift
    /// The erase modifier's own `.flagsChanged`. Fires only while push to talk is both
    /// believed down and physically down, so a stale `isPressed` cannot turn every Right
    /// Command into an erase. A down that passes through clears the swallow flag, so a lost
    /// up can never make Sotto eat a later ordinary Command up and leave it stuck in the app.
    private func handleEraseModifier(down: Bool) -> Bool {
        if down {
            guard isPressed, isKeyDown(key) else {
                eraseModifierSwallowed = false
                return false
            }
            if !eraseModifierSwallowed {
                eraseModifierSwallowed = true
                Log.hotkey.info("erase key \(self.eraseKey.displayName, privacy: .public) while \(self.key.displayName, privacy: .public) held")
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
```

- In `reconcilePressedState`, at the top: `if eraseModifierSwallowed, !isEraseKeyDown(eraseKey) { eraseModifierSwallowed = false; Log.hotkey.info("erase key up was lost while the tap was disabled") }`. The existing `guard` stays below it.
- In `stop()`: `eraseModifierSwallowed = false` beside `isPressed = false`.
- Update the §6.4 test list in SPEC.md only if a behaviour differs; none is expected.

- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit.** `feat(hotkey): erase modifier while push to talk is held`.

---

### Task 4: The pure erase plan

**Files:**
- Create: `Sources/Sotto/Core/ErasePlan.swift`
- Test: `Tests/SottoAppTests/ErasePlanTests.swift`

**Interfaces:**
- Consumes: nothing. `LastInjectionSnapshot` is defined here at file scope, and Task 5 switches `TextInjector`'s private `LastInjection` over to it. The spec's `TextInjector.LastInjectionSnapshot` becomes this top-level type; fix §6.16 in the same commit.
- Produces (exact):

```swift
struct AXElementID: @unchecked Sendable, Equatable { let element: AXUIElement }
struct LastInjectionSnapshot: Sendable, Equatable { ... }
struct TypedDictation: Sendable, Equatable {
    let text: String; let processID: pid_t; let element: AXElementID?; let window: AXElementID?
    let caretEnd: Int?; let landedAt: ContinuousClock.Instant
    let previousInjection: LastInjectionSnapshot?; let inputEpoch: UInt64
}
enum ReadBack: Equatable {
    case unreadable(window: AXElementID?)
    case readable(element: AXElementID, window: AXElementID?, selection: CFRange, preceding: String?)
}
enum EraseOutcome: Sendable, Equatable { case erased, nothingToErase, notTyped, inputSince, textChanged, tooLongToVerify, interrupted, failed; var message: String? }
enum ErasePlan: Equatable {
    case refuse(EraseOutcome)
    case deleteRange(location: Int, length: Int)
    case backspaces(count: Int)
    static let unverifiedLimit = 500
    static func decide(record: TypedDictation?, superseded: Bool, epoch: UInt64, frontmostPID: pid_t?, readBack: ReadBack) -> ErasePlan
}
```

`ReadBack.unreadable` carries the window, because AX can often name a terminal's window even when it can't read the text. This is a deliberate refinement of the spec's `case unreadable`; update §6.16's `ReadBack` block in the same commit. `CFRange` is not `Equatable`, so give `ReadBack` a hand-written `==` that compares `location` and `length`.

- [ ] **Step 1: Write the failing tests.** `ErasePlanTests.swift`:

```swift
import ApplicationServices
import Testing
@testable import Sotto

@MainActor
struct ErasePlanTests {
    private let field = AXElementID(element: AXUIElementCreateApplication(101))
    private let otherField = AXElementID(element: AXUIElementCreateApplication(102))
    private let window = AXElementID(element: AXUIElementCreateApplication(201))
    private let otherWindow = AXElementID(element: AXUIElementCreateApplication(202))

    private func record(_ text: String = " Hello there.", element: Bool = true, caretEnd: Int? = 40, epoch: UInt64 = 7) -> TypedDictation {
        TypedDictation(
            text: text, processID: 42, element: element ? field : nil, window: window,
            caretEnd: element ? caretEnd : nil, landedAt: ContinuousClock().now,
            previousInjection: nil, inputEpoch: epoch
        )
    }

    private func caret(_ location: Int, preceding: String?, element: AXElementID? = nil, window: AXElementID? = nil) -> ReadBack {
        .readable(element: element ?? field, window: window ?? self.window, selection: CFRange(location: location, length: 0), preceding: preceding)
    }

    private func decide(_ record: TypedDictation?, superseded: Bool = false, epoch: UInt64 = 7, pid: pid_t? = 42, _ readBack: ReadBack) -> ErasePlan {
        ErasePlan.decide(record: record, superseded: superseded, epoch: epoch, frontmostPID: pid, readBack: readBack)
    }

    @Test func noRecord() { #expect(decide(nil, .unreadable(window: nil)) == .refuse(.nothingToErase)) }
    @Test func superseded() { #expect(decide(record(), superseded: true, caret(40, preceding: " Hello there.")) == .refuse(.notTyped)) }
    @Test func otherApp() { #expect(decide(record(), pid: 9, caret(40, preceding: " Hello there.")) == .refuse(.inputSince)) }

    @Test func readableCaretMatch() {
        let n = " Hello there.".utf16.count
        #expect(decide(record(), caret(40, preceding: " Hello there.")) == .deleteRange(location: 40 - n, length: n))
    }

    @Test func readableSelectionOfTheInsertMatches() {
        let n = " Hello there.".utf16.count
        let rb = ReadBack.readable(element: field, window: window, selection: CFRange(location: 40 - n, length: n), preceding: " Hello there.")
        #expect(decide(record(), rb) == .deleteRange(location: 40 - n, length: n))
    }

    @Test func readableEpochIsIgnored() {
        #expect(decide(record(epoch: 1), epoch: 99, caret(40, preceding: " Hello there.")) != .refuse(.inputSince))
    }

    @Test func differentText() { #expect(decide(record(), caret(40, preceding: " Hello thera.")) == .refuse(.textChanged)) }

    @Test func normalisationCountsAsChanged() {
        let nfd = "Cafe\u{301}."
        let nfc = "Caf\u{E9}."
        #expect(decide(record(nfd), caret(40, preceding: nfc)) == .refuse(.textChanged))
    }

    @Test func identicalTextInAnotherFieldIsNotOurs() {
        #expect(decide(record("Yes."), caret(40, preceding: "Yes.", element: otherField)) == .refuse(.inputSince))
    }

    @Test func anotherWindow() {
        #expect(decide(record(), caret(40, preceding: " Hello there.", window: otherWindow)) == .refuse(.inputSince))
    }

    @Test func caretMoved() { #expect(decide(record(), caret(41, preceding: "Hello there. ")) == .refuse(.textChanged)) }
    @Test func arbitrarySelection() {
        let rb = ReadBack.readable(element: field, window: window, selection: CFRange(location: 10, length: 3), preceding: "abc")
        #expect(decide(record(), rb) == .refuse(.textChanged))
    }
    @Test func precedingOutOfBounds() { #expect(decide(record(), caret(40, preceding: nil)) == .refuse(.textChanged)) }

    @Test func unreadableUntouched() {
        #expect(decide(record(element: false), .unreadable(window: window)) == .backspaces(count: " Hello there.".count))
    }
    @Test func unreadableAfterInput() {
        #expect(decide(record(element: false), epoch: 8, .unreadable(window: window)) == .refuse(.inputSince))
    }
    @Test func unreadableOtherWindow() {
        #expect(decide(record(element: false), .unreadable(window: otherWindow)) == .refuse(.inputSince))
    }
    @Test func unreadableUnknownWindowStillErases() {
        #expect(decide(record(element: false), .unreadable(window: nil)) == .backspaces(count: " Hello there.".count))
    }
    @Test func unreadableNewline() {
        #expect(decide(record("one\ntwo", element: false), .unreadable(window: window)) == .refuse(.tooLongToVerify))
    }
    @Test func unreadableAtAndOverTheLimit() {
        let at = String(repeating: "a", count: ErasePlan.unverifiedLimit)
        #expect(decide(record(at, element: false), .unreadable(window: window)) == .backspaces(count: ErasePlan.unverifiedLimit))
        #expect(decide(record(at + "a", element: false), .unreadable(window: window)) == .refuse(.tooLongToVerify))
    }
    @Test func recordWithoutElementButReadableNowMustStillMatch() {
        let text = " Hello there."
        #expect(decide(record(text, element: false), caret(40, preceding: text)) == .backspaces(count: text.count))
        #expect(decide(record(text, element: false), caret(40, preceding: "different!!!!")) == .refuse(.textChanged))
    }
    @Test func emojiCountsCharactersForBackspacesAndUnitsForRanges() {
        let text = " ok \u{1F44D}"
        #expect(decide(record(text, element: false), .unreadable(window: window)) == .backspaces(count: 5))
        #expect(decide(record(text), caret(40, preceding: text)) == .deleteRange(location: 40 - 6, length: 6))
    }
    @Test func everyRefusalHasAMessageAndErasedHasNone() {
        #expect(EraseOutcome.erased.message == nil)
        for outcome in [EraseOutcome.nothingToErase, .notTyped, .inputSince, .textChanged, .tooLongToVerify, .interrupted, .failed] {
            #expect(outcome.message?.isEmpty == false)
        }
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail** (the types don't exist yet).

- [ ] **Step 3: Implement** `ErasePlan.swift`:

```swift
import ApplicationServices
import Foundation

/// An accessibility element compared by `CFEqual`. Only ever compared off the main actor,
/// never messaged there.
struct AXElementID: @unchecked Sendable, Equatable {
    let element: AXUIElement
    static func == (lhs: AXElementID, rhs: AXElementID) -> Bool { CFEqual(lhs.element, rhs.element) }
}

/// What `TextInjector` knew about the previous injection, restored after an erase so the
/// restated text does not inherit the run-on leading space meant for the erased one.
struct LastInjectionSnapshot: Sendable, Equatable {
    let bundleID: String?
    let at: ContinuousClock.Instant
    let endedInWhitespace: Bool
}

/// What was last typed, captured when the insert was confirmed (§6.16).
struct TypedDictation: Sendable, Equatable {
    let text: String
    let processID: pid_t
    let element: AXElementID?
    let window: AXElementID?
    let caretEnd: Int?
    let landedAt: ContinuousClock.Instant
    let previousInjection: LastInjectionSnapshot?
    let inputEpoch: UInt64
}

enum ReadBack: Equatable {
    case unreadable(window: AXElementID?)
    case readable(element: AXElementID, window: AXElementID?, selection: CFRange, preceding: String?)

    static func == (lhs: ReadBack, rhs: ReadBack) -> Bool {
        switch (lhs, rhs) {
        case let (.unreadable(a), .unreadable(b)): a == b
        case let (.readable(e1, w1, s1, p1), .readable(e2, w2, s2, p2)):
            e1 == e2 && w1 == w2 && s1.location == s2.location && s1.length == s2.length && p1 == p2
        default: false
        }
    }
}

enum EraseOutcome: Sendable, Equatable {
    case erased, nothingToErase, notTyped, inputSince, textChanged, tooLongToVerify, interrupted, failed

    var message: String? {
        switch self {
        case .erased: nil
        case .nothingToErase: "Nothing to erase."
        case .notTyped: "The last dictation wasn't typed; nothing was erased."
        case .inputSince: "You've typed, clicked or switched since; nothing was erased."
        case .textChanged: "The text before the cursor changed; nothing was erased."
        case .tooLongToVerify: "That dictation is too long or has line breaks, so it can't be erased safely here."
        case .interrupted: "Erasing stopped part-way because you typed or switched; check the text."
        case .failed: "Couldn't erase; nothing was changed."
        }
    }
}

/// The decision, pure so every safety rule is unit-tested (§6.16 "Plan").
enum ErasePlan: Equatable {
    case refuse(EraseOutcome)
    case deleteRange(location: Int, length: Int)
    case backspaces(count: Int)

    /// Terminals fold longer or multi-line pastes into one placeholder (§10).
    static let unverifiedLimit = 500

    static func decide(
        record: TypedDictation?, superseded: Bool, epoch: UInt64, frontmostPID: pid_t?, readBack: ReadBack
    ) -> ErasePlan {
        guard let record else { return .refuse(.nothingToErase) }
        guard !superseded else { return .refuse(.notTyped) }
        guard frontmostPID == record.processID else { return .refuse(.inputSince) }

        if case let .readable(element, window, selection, preceding) = readBack,
           let recorded = record.element, let caretEnd = record.caretEnd {
            guard element == recorded else { return .refuse(.inputSince) }
            if let window, let recordedWindow = record.window, window != recordedWindow { return .refuse(.inputSince) }
            let n = record.text.utf16.count
            let isCaret = selection.length == 0 && selection.location == caretEnd
            let isInsert = selection.location == caretEnd - n && selection.length == n
            guard isCaret || isInsert, caretEnd - n >= 0, preceding == record.text else { return .refuse(.textChanged) }
            return .deleteRange(location: caretEnd - n, length: n)
        }

        guard epoch == record.inputEpoch else { return .refuse(.inputSince) }
        let currentWindow: AXElementID?
        switch readBack {
        case .unreadable(let window): currentWindow = window
        case .readable(_, let window, _, let preceding):
            currentWindow = window
            guard preceding == record.text else { return .refuse(.textChanged) }
        }
        if let currentWindow, let recordedWindow = record.window, currentWindow != recordedWindow {
            return .refuse(.inputSince)
        }
        guard !record.text.contains(where: \.isNewline), record.text.count <= unverifiedLimit else {
            return .refuse(.tooLongToVerify)
        }
        return .backspaces(count: record.text.count)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit** with the §6.16 `ReadBack` wording fix. `feat(erase): pure erase plan`.

---

### Task 5: Mutation lane, marker, and recording what was typed

**Files:**
- Create: `Sources/Sotto/Core/MutationLane.swift`, `Sources/Sotto/Core/SyntheticEvent.swift`
- Modify: `Sources/Sotto/Core/TextInjector.swift`, `Sources/Sotto/Core/UtterancePipeline.swift`
- Test: `Tests/SottoAppTests/MutationLaneTests.swift`, `Tests/SottoAppTests/UtterancePipelineTests.swift`

**Interfaces:**
- Consumes: `TypedDictation`, `LastInjectionSnapshot`, `AXElementID` (Task 4).
- Produces:
  - `MutationLane.run<T: Sendable>(_ body: @escaping @MainActor () async -> (T, Task<Void, Never>?)) async -> T`
  - `SyntheticEvent.marker: Int64` and `SyntheticEvent.isMarked(_ event: CGEvent) -> Bool`
  - `protocol TypingObserver: AnyObject { var inputEpoch: UInt64 { get }; func recordTyped(_ typed: TypedDictation); func supersede() }` (MainActor)
  - `TextInjector.observer: (any TypingObserver)?`
  - `TextInjector.lastInjectionSnapshot: LastInjectionSnapshot?` and `TextInjector.restoreLastInjection(_:)`
  - `TextInjector.configureAccessibilityTimeout()`
  - `TextInjector.focusedTarget() -> (element: AXElementID?, window: AXElementID?)`
  - `UtterancePipeline.init(..., markDeliveryStarted: @escaping @MainActor () -> Void = { TextInjector.observer?.supersede() })`

- [ ] **Step 1: Write the failing tests.** `MutationLaneTests.swift`:

```swift
import Testing
@testable import Sotto

@MainActor
@Suite(.serialized)
struct MutationLaneTests {
    @Test func mutationsRunOneAtATimeInOrder() async {
        var log: [String] = []
        let gate = Gate(open: false)
        async let first: Int = MutationLane.run {
            log.append("first start")
            await gate.pass()
            log.append("first end")
            return (1, nil)
        }
        await gate.waitForArrival()
        async let second: Int = MutationLane.run {
            log.append("second")
            return (2, nil)
        }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(log == ["first start"])
        await gate.open()
        _ = await (first, second)
        #expect(log == ["first start", "first end", "second"])
    }

    @Test func theNextMutationWaitsForTheSettleButTheCallerDoesNot() async {
        var log: [String] = []
        let settleGate = Gate(open: false)
        let value = await MutationLane.run {
            log.append("paste")
            return (1, Task { @MainActor in await settleGate.pass(); log.append("settled") })
        }
        #expect(value == 1)
        async let next: Int = MutationLane.run {
            log.append("erase")
            return (2, nil)
        }
        await settleGate.waitForArrival()
        #expect(log == ["paste"])
        await settleGate.open()
        _ = await next
        #expect(log == ["paste", "settled", "erase"])
    }
}
```

The `try? await Task.sleep` in the test must follow the logging rule, so write it as `do { try await Task.sleep(for: .milliseconds(20)) } catch { Issue.record("sleep cancelled") }`.

In `UtterancePipelineTests.swift`, find the existing pipeline constructor helper and add a test like the following. Use the file's existing helper names; read the file first.

```swift
    @Test func aHotkeyDeliveryMarksThePreviousRecordSupersededBeforeFormatting() async {
        var events: [String] = []
        let pipeline = UtterancePipeline(
            readSettings: { .init(cleanupEnabled: false, smartCleanup: false, soundEnabled: false) },
            makeCorrector: { DictionaryCorrector(entries: []) },
            recordHistory: { _ in events.append("history") },
            inject: { _, _ in events.append("inject"); return .landed },
            playEndSound: {},
            readFrontmostProcessID: { nil },
            markDeliveryStarted: { events.append("supersede") }
        )
        await pipeline.process(raw: "hello", utterance: Utterance(source: .hotkey, heldSeconds: 1, releasedAt: Date()))
        #expect(events == ["supersede", "inject", "history"])
    }

    @Test func aButtonDeliveryDoesNotSupersede() async {
        var superseded = false
        let pipeline = UtterancePipeline(
            readSettings: { .init(cleanupEnabled: false, smartCleanup: false, soundEnabled: false) },
            makeCorrector: { DictionaryCorrector(entries: []) },
            recordHistory: { _ in },
            inject: { _, _ in .landed },
            playEndSound: {},
            readFrontmostProcessID: { nil },
            markDeliveryStarted: { superseded = true }
        )
        await pipeline.process(raw: "hello", utterance: Utterance(source: .button, heldSeconds: 1, releasedAt: Date()))
        #expect(!superseded)
    }
```

- [ ] **Step 2: Run the tests and confirm they fail.**

- [ ] **Step 3: Implement.**

`MutationLane.swift`:

```swift
/// One target mutation at a time (§6.16): an insert and an erase never overlap, and each
/// waits for the previous one's settle (a paste's `pasteCompletionDelay`) before touching the
/// target. The caller gets its result as soon as its body returns; only the next mutation
/// waits for the settle.
@MainActor
enum MutationLane {
    private static var tail: Task<Void, Never>?

    static func run<T: Sendable>(_ body: @escaping @MainActor () async -> (T, Task<Void, Never>?)) async -> T {
        let previous = tail
        let work = Task { @MainActor () -> (T, Task<Void, Never>?) in
            await previous?.value
            return await body()
        }
        tail = Task { @MainActor in
            let (_, settle) = await work.value
            await settle?.value
        }
        return await work.value.0
    }
}
```

`SyntheticEvent.swift`:

```swift
import CoreGraphics

/// Marks events Sotto posts itself, so its input monitor does not mistake them for the user.
enum SyntheticEvent {
    /// "SOTTO" in ASCII; any fixed value other users are unlikely to set.
    static let marker: Int64 = 0x53_4F_54_54_4F

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
```

`TextInjector.swift` changes:
1. Replace the private `LastInjection` struct with the shared `LastInjectionSnapshot` (same three fields; `bundleID`, `at`, `endedInWhitespace`). Keep `private static var lastInjection: LastInjectionSnapshot?`, and add:

```swift
    static var lastInjectionSnapshot: LastInjectionSnapshot? { lastInjection }
    static func restoreLastInjection(_ snapshot: LastInjectionSnapshot?) {
        lastInjection = snapshot
        Log.inject.info("run-on state restored after an erase")
    }
    /// The eraser, set at launch (§6.16). Nil in tests that do not care.
    static var observer: (any TypingObserver)?
```

   Declare the protocol in the same file:

```swift
@MainActor
protocol TypingObserver: AnyObject {
    var inputEpoch: UInt64 { get }
    func recordTyped(_ typed: TypedDictation)
    func supersede()
}
```

2. Split `insert` into a thin lane wrapper and the existing body:

```swift
    @discardableResult
    static func insert(_ text: String, targetProcessID: pid_t? = nil) async -> Outcome {
        await MutationLane.run { await insertExclusive(text, targetProcessID: targetProcessID) }
    }
```

   `insertExclusive` returns `(Outcome, Task<Void, Never>?)`. It captures, before any mutation:

```swift
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let epoch = observer?.inputEpoch ?? 0
        let previous = lastInjection
        let target = focusedTarget()
```

   On the AX path, when `insertViaAccessibility` returns nil (landed), read `selectedRange(of:)` on the same focused element to get `caretEnd = range.location + range.length`. Then call `observer?.recordTyped(TypedDictation(text: inserted, processID: pid, element: target.element, window: target.window, caretEnd: caretEnd, landedAt: injectionClock.now, previousInjection: previous, inputEpoch: epoch))`. Return `(.landed, nil)`. `insertViaAccessibility` must return the `inserted` string it actually wrote, including the leading space. Change its return type to `Result<String, Reason>`, or return `(reason: String?, inserted: String)`.

   On the paste path, when it lands, build the settle task:

```swift
            let settle = Task { @MainActor in
                await wait(pasteCompletionDelay)
                let caretEnd = target.element.flatMap { selectedRange(of: $0.element) }.map { $0.location + $0.length }
                if let pid {
                    observer?.recordTyped(TypedDictation(
                        text: outgoing, processID: pid, element: target.element, window: target.window,
                        caretEnd: caretEnd, landedAt: injectionClock.now, previousInjection: previous, inputEpoch: epoch
                    ))
                }
            }
            return (.landed, settle)
```

   `insertViaPasteboard` must expose `outgoing`. Make it return `(Outcome, String)`. `.failed` and `.focusMoved` record nothing and return `(outcome, nil)`. A nil `pid` records nothing (log it).

3. Mark ⌘V: in `postCommandV`, call `SyntheticEvent.mark(keyDown)` and `SyntheticEvent.mark(keyUp)` before posting.

4. Add:

```swift
    /// Caps every synchronous AX call process-wide (the default is about 6 s), so a hung target
    /// cannot freeze the main actor, the event tap and every timer (§10). Called at launch.
    static func configureAccessibilityTimeout() {
        let error = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        if error != .success {
            Log.inject.error("could not set the AX messaging timeout (AXError \(error.rawValue, privacy: .public))")
        }
    }

    /// The focused element and its window, when readable.
    static func focusedTarget() -> (element: AXElementID?, window: AXElementID?) {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            Log.inject.debug("no readable focused element for the typed record")
            return (nil, nil)
        }
        let element = focused as! AXUIElement
        var window: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window)
        let windowID: AXElementID?
        if windowError == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            windowID = AXElementID(element: window as! AXUIElement)
        } else {
            Log.inject.debug("focused element has no readable window (AXError \(windowError.rawValue, privacy: .public))")
            windowID = nil
        }
        return (AXElementID(element: element), windowID)
    }
```

   Make `selectedRange(of:)` and `characterCount(of:)` `static` (drop `private`) so `SystemEraseTarget` can reuse them.

`UtterancePipeline.swift`: add the init parameter `markDeliveryStarted: @escaping @MainActor () -> Void = { TextInjector.observer?.supersede() }` and store it. At the top of `process`, `if utterance.source == .hotkey { markDeliveryStarted() }`.

- [ ] **Step 4: Run the tests and confirm they pass**, including every existing pipeline test.
- [ ] **Step 5: Commit.** `feat(inject): serialise mutations and record what was typed`.

---

### Task 6: `DictationEraser` and the real target

**Files:**
- Create: `Sources/Sotto/Core/DictationEraser.swift`, `Sources/Sotto/Core/SystemEraseTarget.swift`
- Test: `Tests/SottoAppTests/DictationEraserTests.swift`

**Interfaces:**
- Consumes: Tasks 4 and 5.
- Produces:

```swift
@MainActor final class EraseToken { private(set) var isRevoked = false; func revoke() }
@MainActor protocol EraseTarget: AnyObject {
    func frontmostProcessID() -> pid_t?
    func readBack(utf16Length: Int) -> ReadBack
    func select(_ range: CFRange, in element: AXElementID) -> Bool          // sets, reads back, true only on an exact match
    func deleteSelection(in element: AXElementID) -> Bool                    // AX write of ""
    func selection(in element: AXElementID) -> CFRange?
    func characterCount(in element: AXElementID) -> Int?
    func postBackspaces(_ count: Int)                                         // marked, empty flags, .privateState
    func isKeyDown(_ keyCode: Int64) -> Bool
}
@MainActor protocol InputMonitoring: AnyObject { func start(onInput: @escaping @MainActor () -> Void) -> Bool }
@MainActor final class DictationEraser: TypingObserver {
    static let shared: DictationEraser
    init(target: any EraseTarget, monitor: any InputMonitoring, eraseKey: @escaping @MainActor () -> EraseKey,
         restoreInjection: @escaping @MainActor (LastInjectionSnapshot?) -> Void)
    private(set) var inputEpoch: UInt64
    func start()
    func recordTyped(_ typed: TypedDictation)
    func supersede()
    func eraseLast(token: EraseToken) async -> EraseOutcome
}
```

- [ ] **Step 1: Write the failing tests.** `DictationEraserTests.swift` defines `FakeEraseTarget` (records calls; its `readBack` returns a settable value; `select` returns a settable Bool; `selection` and `characterCount` return values that change after `deleteSelection` or `postBackspaces` when configured to "apply") and `FakeInputMonitor` (stores `onInput`, with `fire()`). Tests:

```swift
@MainActor
@Suite(.serialized)
struct DictationEraserTests {
    // helpers: makeEraser() wires fakes, eraseKey .rightCommand, a restore spy.

    @Test func aLandingRecordsAndAnAttemptClearsIt() async { /* record, erase -> .erased; erase again -> .nothingToErase */ }
    @Test func inputBumpsTheEpoch() { /* monitor.fire() -> inputEpoch + 1 */ }
    @Test func supersedeRefusesWithNotTyped() async { /* record, supersede, erase -> .notTyped, nothing posted */ }
    @Test func recordAfterSupersedeClearsIt() async { /* supersede, record, erase -> .erased */ }
    @Test func deleteRangeUsesAXFirst() async { /* readable match; select true; delete applies -> .erased, zero backspaces */ }
    @Test func deleteRangeFallsBackToOneBackspaceOnlyWhileTheSelectionIsExact() async { /* delete does nothing; selection still exact -> exactly 1 backspace */ }
    @Test func deleteRangeStopsWhenTheSelectionCannotBeSet() async { /* select false -> .failed, zero backspaces, no delete */ }
    @Test func deleteRangeNeverCountsBackspaces() async { /* delete does nothing, selection moved -> .failed, zero backspaces */ }
    @Test func backspacesPostTheCountInChunks() async { /* unreadable, 25 chars -> postBackspaces called 10,10,5 */ }
    @Test func backspacesStopWhenInputArrivesMidRun() async { /* target fires monitor during 2nd chunk -> .interrupted, 20 posted */ }
    @Test func aRevokedTokenStopsBeforeTheNextSideEffect() async { /* revoke during modifier wait -> .failed, nothing posted */ }
    @Test func keysWaitForTheEraseModifierUp() async { /* isKeyDown true for 50 ms then false; first post after the flip */ }
    @Test func erasedRestoresTheRunOnState() async { /* restore spy receives record.previousInjection */ }
    @Test func refusalDoesNotRestoreRunOnState() async { /* textChanged -> spy not called */ }
    @Test func anEraseQueuedBehindASettleWaits() async { /* MutationLane.run with a gated settle, then eraseLast; nothing posted until the gate opens */ }
}
```

Write each body in full, following the one-line intent comments. Every `sleep` in these tests uses `do/catch` with `Issue.record`. The monitor-fire-mid-run test needs `FakeEraseTarget.postBackspaces` to call a closure hook after its Nth call.

- [ ] **Step 2: Run the tests and confirm they fail.**

- [ ] **Step 3: Implement** `DictationEraser.swift`:

```swift
import ApplicationServices
import Foundation

@MainActor
final class EraseToken {
    private(set) var isRevoked = false
    func revoke() { isRevoked = true }
}

/// Erases exactly what Sotto last typed, or refuses (§6.16).
@MainActor
final class DictationEraser: TypingObserver {
    static let shared = DictationEraser(
        target: SystemEraseTarget(), monitor: SystemInputMonitor(),
        eraseKey: { Settings.shared.eraseKey },
        restoreInjection: { TextInjector.restoreLastInjection($0) }
    )

    private static let chunk = 10
    private static let chunkPause: Duration = .milliseconds(2)
    private static let modifierPoll: Duration = .milliseconds(10)
    private static let modifierWaitCap: Duration = .seconds(1)
    private static let verifyTimeout: Duration = .milliseconds(150)
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

    init(target: any EraseTarget, monitor: any InputMonitoring,
         eraseKey: @escaping @MainActor () -> EraseKey,
         restoreInjection: @escaping @MainActor (LastInjectionSnapshot?) -> Void) {
        self.target = target
        self.monitor = monitor
        self.eraseKey = eraseKey
        self.restoreInjection = restoreInjection
    }

    func start() {
        guard !monitoring else { return }
        monitoring = monitor.start { [weak self] in self?.inputEpoch &+= 1 }
        if !monitoring {
            Log.inject.error("input monitor unavailable; erase will refuse in apps it cannot read")
        }
    }

    func recordTyped(_ typed: TypedDictation) {
        record = typed
        superseded = false
    }

    func supersede() {
        superseded = true
    }

    func eraseLast(token: EraseToken) async -> EraseOutcome {
        await MutationLane.run { (await self.eraseExclusive(token: token), nil) }
    }

    private func eraseExclusive(token: EraseToken) async -> EraseOutcome {
        guard let record else {
            Log.inject.info("erase: nothing recorded")
            return .nothingToErase
        }
        self.record = nil
        // Fail closed: without a monitor the epoch cannot vouch for an unreadable target.
        let epoch = monitoring ? inputEpoch : inputEpoch &+ 1
        let plan = ErasePlan.decide(
            record: record, superseded: superseded, epoch: epoch,
            frontmostPID: target.frontmostProcessID(), readBack: target.readBack(utf16Length: record.text.utf16.count)
        )
        let started = clock.now
        let outcome: EraseOutcome
        switch plan {
        case .refuse(let reason):
            outcome = reason
        case let .deleteRange(location, length):
            outcome = await deleteRange(location: location, length: length, record: record, token: token)
        case .backspaces(let count):
            outcome = await backspaces(count, record: record, token: token)
        }
        Log.inject.info(
            "erase: plan \(String(describing: plan), privacy: .public) -> \(String(describing: outcome), privacy: .public), \(record.text.utf16.count, privacy: .public) units, \(record.text.count, privacy: .public) chars, \(self.clock.now - started, privacy: .public)"
        )
        if outcome == .erased {
            restoreInjection(record.previousInjection)
        }
        return outcome
    }
}
```

`deleteRange` implements §6.16 exactly:
1. Call `waitForModifierUp`, which returns false when the token is revoked.
2. `guard let element = record.element`.
3. `guard target.select(range, in: element)`, else `.failed`.
4. Check the token.
5. `target.deleteSelection(in:)`, then poll `verifyTimeout` for `selection?.location == location && selection?.length == 0 && countBefore - countAfter == length`. Use `countBefore` only when readable, otherwise the caret alone. If verified, `.erased`.
6. Otherwise, if `target.selection(in:)` is still exactly the range, `postBackspaces(1)` and poll again. If verified, `.erased`.
7. Anything else is `.failed`, logged with both ranges.

`backspaces` does:
1. `waitForModifierUp`.
2. A loop over chunks of 10. Before each chunk: check the token, then check that `inputEpoch` and `target.frontmostProcessID()` still match the start values. A mismatch returns `.interrupted` if anything has been posted, `.failed` otherwise.
3. `postBackspaces(chunkSize)`, then sleep `chunkPause`.
4. When the loop completes, `.erased`.

`waitForModifierUp` polls `target.isKeyDown(eraseKey().keyCode ?? -1)` every `modifierPoll` up to `modifierWaitCap`, and returns false if the token is revoked. At the cap it logs and proceeds, because keys carry explicit empty flags.

The `.failed` versus `.interrupted` distinction for a stop before the first chunk matters to the user: nothing changed, so the message must not say "check the text".

`SystemEraseTarget.swift` implements `EraseTarget` with:
- AX, reusing `TextInjector.focusedTarget()`, `TextInjector.selectedRange(of:)` and `TextInjector.characterCount(of:)`.
- `kAXStringForRangeParameterizedAttribute` for `preceding`.
- `CGEventSource(stateID: .privateState)` for backspaces: kVK_Delete = 51, `flags = []`, marked, posted to `.cghidEventTap`.
- `CGEventSource.keyState(.combinedSessionState, key:)` for `isKeyDown`.

`readBack(utf16Length:)` returns `.unreadable(window:)` when there is no focused element or the selection is unreadable. Otherwise it reads `preceding` from `(selectionEnd - n, n)` when that is in bounds, else nil.

`SystemInputMonitor` implements `InputMonitoring`:

```swift
@MainActor
final class SystemInputMonitor: InputMonitoring {
    private var tokens: [Any] = []

    func start(onInput: @escaping @MainActor () -> Void) -> Bool {
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            if let cgEvent = event.cgEvent, SyntheticEvent.isMarked(cgEvent) { return }
            Task { @MainActor in onInput() }
        }) else {
            Log.inject.error("global input monitor could not be installed")
            return false
        }
        tokens.append(monitor)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onInput() }
            })
        }
        return true
    }
}
```

Never use `MainActor.assumeIsolated` here; CLAUDE.md allows exactly one site. The `Task` hop costs one run-loop turn. That is fine: the epoch is only read at erase time, well after.

- [ ] **Step 4: Run the tests and confirm they pass.**
- [ ] **Step 5: Commit.** `feat(erase): eraser with verified and inferred paths`.

---

### Task 7: Controller: `.erasing` and `.erased`

**Files:**
- Modify: `Sources/Sotto/Core/DictationController.swift`
- Modify: `Tests/SottoAppTests/Fakes.swift` (`Harness` gains an erase fake)
- Test: `Tests/SottoAppTests/DictationControllerTests.swift`, `Tests/SottoAppTests/DictationOrderTests.swift`

**Interfaces:**
- Consumes: `HotkeySource.onErase` and `eraseKey` (Task 3), `EraseOutcome` (Task 4), `EraseToken` (Task 6).
- Produces:
  - `DictationController.State.erasing`
  - `init(..., eraseTimeout: Duration = .seconds(3), eraseLast: @escaping @MainActor (EraseToken) async -> EraseOutcome = { _ in .nothingToErase })`
  - The spec's `eraseLast` signature gains the token; update §6.7 in the same commit.

- [ ] **Step 1: Extend the harness.** `Harness.init` gains `eraseTimeout: Duration = .seconds(3)` and passes:

```swift
            eraseTimeout: eraseTimeout,
            eraseLast: { [weak self] token in
                guard let self else { return .failed }
                self.eraseCalls += 1
                self.lastEraseToken = token
                if let gate = self.eraseGate { await gate.pass() }
                return self.eraseOutcome
            }
```

   Add these properties: `var eraseOutcome: EraseOutcome = .erased`, `var eraseGate: Gate?`, `private(set) var eraseCalls = 0`, `private(set) var lastEraseToken: EraseToken?`.

- [ ] **Step 2: Write the failing controller tests** in `DictationControllerTests`:

```swift
    // MARK: Erase

    @Test func eraseWhileListeningCancelsErasesAndRestartsWhileHeld() async throws {
        let first = FakeEngine(.init(finalText: "wrong"))
        let second = FakeEngine(.init(finalText: "right"))
        let harness = Harness(engines: [first, second])
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        try await settle("restarted") { harness.state == .listening && harness.factory.made.count == 2 }
        #expect(harness.eraseCalls == 1)
        #expect(harness.received.isEmpty)
        #expect(await first.cancelCalls == 1)
        #expect(await first.finishCalls == 0)
        try await harness.releaseAndIdle()
        #expect(harness.received.map(\.text) == ["right"])
        #expect(harness.controller.liveTaskCount == 0)
    }

    @Test func showsErasingWhileTheEraserRuns() async throws {
        let harness = Harness()
        harness.eraseGate = Gate(open: false)
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        await harness.eraseGate!.waitForArrival()
        #expect(harness.state == .erasing)
        #expect(harness.state.isActive)
        await harness.eraseGate!.open()
        try await settle("restarted") { harness.state == .listening }
        try await harness.releaseAndIdle()
    }

    @Test func releaseDuringErasingErasesWithoutRestarting() async throws {
        let harness = Harness()
        harness.eraseGate = Gate(open: false)
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        await harness.eraseGate!.waitForArrival()
        harness.hotkey.release()
        await harness.eraseGate!.open()
        try await settle("idle") { harness.state == .idle && harness.controller.liveTaskCount == 0 }
        #expect(harness.factory.made.count == 1)
    }

    @Test(arguments: [EraseOutcome.nothingToErase, .notTyped, .inputSince, .textChanged, .tooLongToVerify, .interrupted, .failed])
    func aRefusedEraseShowsItsMessageAndDoesNotRestart(_ outcome: EraseOutcome) async throws {
        let harness = Harness(errorDisplayDuration: .milliseconds(100))
        harness.eraseOutcome = outcome
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        try await settle("error") { harness.state == .error(outcome.message!) }
        try await settle("idle") { harness.state == .idle }
        #expect(harness.factory.made.count == 1)
    }

    @Test func eraseTimeoutRevokesTheTokenAndFails() async throws {
        let harness = Harness(errorDisplayDuration: .milliseconds(100), eraseTimeout: .milliseconds(50))
        harness.eraseGate = Gate(open: false)
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        try await settle("error") { harness.state == .error(EraseOutcome.failed.message!) }
        #expect(harness.lastEraseToken?.isRevoked == true)
        await harness.eraseGate!.open()
        try await settle("idle") { harness.state == .idle && harness.controller.liveTaskCount == 0 }
    }

    @Test func eraseQueuedBehindADeliveryRunsAfterIt() async throws {
        let harness = Harness(engines: [FakeEngine(.init(finalText: "first")), FakeEngine(.init(finalText: "again"))])
        harness.deliveryGate = Gate(open: false)
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.release()
        await harness.deliveryGate!.waitForArrival()
        harness.hotkey.press()      // queued
        harness.hotkey.erase()      // erase after delivery
        #expect(harness.eraseCalls == 0)
        await harness.deliveryGate!.open()
        try await settle("restarted") { harness.state == .listening && harness.factory.made.count == 2 }
        #expect(harness.eraseCalls == 1)
        #expect(harness.received.map(\.text) == ["first"])
        harness.deliveryGate = nil
        try await harness.releaseAndIdle()
    }

    @Test func eraseIsIgnoredForButtonSessionsIdleAndErrors() async throws {
        let harness = Harness()
        harness.controller.activate()
        harness.hotkey.erase()
        #expect(harness.eraseCalls == 0)
        harness.controller.startButtonRecording()
        try await settle("listening") { harness.state == .listening }
        harness.hotkey.erase()
        #expect(harness.state == .listening)
        harness.controller.stopButtonRecording()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.eraseCalls == 0)
    }

    @Test func deactivateDuringErasingRevokesAndDoesNotRestart() async throws {
        let harness = Harness()
        harness.eraseGate = Gate(open: false)
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        await harness.eraseGate!.waitForArrival()
        harness.controller.deactivate()
        #expect(harness.lastEraseToken?.isRevoked == true)
        await harness.eraseGate!.open()
        try await settle("idle") { harness.state == .idle && harness.controller.liveTaskCount == 0 }
        #expect(harness.factory.made.count == 1)
    }

    @Test func recordButtonDuringErasingIsIgnored() async throws {
        let harness = Harness()
        harness.eraseGate = Gate(open: false)
        harness.controller.activate()
        try await harness.pressAndListen()
        harness.hotkey.erase()
        await harness.eraseGate!.waitForArrival()
        harness.controller.startButtonRecording()
        await harness.eraseGate!.open()
        try await settle("restarted from the hotkey") { harness.state == .listening }
        harness.hotkey.release()
        try await settle("idle") { harness.state == .idle }
        #expect(harness.received.allSatisfy { $0.utterance.source == .hotkey })
    }
```

In `DictationOrderTests`:
- Add `case erase` to `OrderEvent`, applied as `hotkey.erase()`.
- Add it to `startingEvents`, `listeningEvents`, `endingEvents`, `queuedEvents` and `restingEvents`.
- Extend each cell's `switch` with the expected behaviour:
  - Starting and listening: the eraser is called once, then a restart. `expectQuiet` runs after a final release, so the cell applies `hotkey.release()` after settling on the restart, and expects `engines: 2`.
  - Ending while finishing or delivering without a queued press: ignored, because `pendingPress` is not `.hotkey`.
  - Queued: erase after delivery.
  - Resting: ignored.
- Add a two-event cell, "erase then immediate release before the terminal task starts erasing": no restart.
- Read the existing cell structure before editing, and keep each new case's expectations in the same style as its neighbours.

- [ ] **Step 3: Run the tests and confirm they fail.**

- [ ] **Step 4: Implement** in `DictationController.swift`:
- `State`: add `case erasing`. `isActive` includes `.erasing`. In `press()`'s `switch state`, add `.erasing` to the "without a session" error arm.
- `TerminalReason`: add `case erased` (label `"erased"`, `isRelease` false).
- `Session`: add `var eraseRequested = false`.
- Stored: `eraseTimeout`, `eraseLast`, and `private var eraseToken: EraseToken?`.
- `activate()` and `reloadHotkey()`: `hotkey.eraseKey = Settings.shared.eraseKey` next to `hotkey.key = ...`. In `activate()`, also set `hotkey.onErase = { [weak self] in self?.erase() }`.
- `deactivate()`: `eraseToken?.revoke()` before `dropPendingPress`.
- `press()`: in the `session.isTerminating` branch, if `session.eraseRequested && source == .button`, log "record ignored during erase" and return, before `pendingPress = source`.
- New:

```swift
    /// The erase key went down while push to talk is held (§6.16). A live hotkey utterance
    /// is cancelled and its terminal task erases, then the queued hotkey press restarts it.
    /// One already ending (the user pressed again while it delivers) erases after delivery.
    private func erase() {
        guard let session, session.source == .hotkey, !session.eraseRequested else {
            Log.app.info("erase ignored in state \(String(describing: self.state), privacy: .public)")
            return
        }
        if session.isTerminating {
            guard pendingPress == .hotkey else {
                Log.app.info("erase ignored: utterance \(session.id, privacy: .public) is ending with no press queued")
                return
            }
            session.eraseRequested = true
            Log.app.info("erase queued behind utterance \(session.id, privacy: .public)")
            return
        }
        session.eraseRequested = true
        pendingPress = .hotkey
        terminate(session, reason: .erased)
    }
```

- In `runTerminal`, after the `if endingError == nil, let notice = session.interruptionNotice` block and before step 6:

```swift
        // 5b. Erase (§6.16): after any delivery, before idle, so the text just delivered is
        // what gets erased and nothing else owns the target meanwhile.
        if session.eraseRequested, session === self.session {
            state = .erasing
            let outcome = await eraseBounded(id: session.id)
            if outcome != .erased {
                dropPendingPress(reason: "erase did not complete")
                endingError = outcome.message
            }
        }
```

- In step 6's `switch reason`, add `.erased` to the `.released, .tapped, .aborted` arm.
- `eraseBounded` mirrors `deliverBounded`:

```swift
    private func eraseBounded(id: Int) async -> EraseOutcome {
        let token = EraseToken()
        eraseToken = token
        defer { if eraseToken === token { eraseToken = nil } }
        let latch = RaceLatch()
        let box = OutcomeBox()
        Task { @MainActor in
            box.value = await self.eraseLast(token)
            latch.resolve(true)
        }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: eraseTimeout) } catch {
                Log.app.debug("erase timer cancelled")
                return
            }
            latch.resolve(false)
        }
        if await latch.value() {
            timer.cancel()
            return token.isRevoked ? .failed : box.value
        }
        token.revoke()
        Log.app.error("utterance \(id, privacy: .public) erase did not finish within \(self.eraseTimeout, privacy: .public); revoked")
        return .failed
    }

    @MainActor private final class OutcomeBox { var value: EraseOutcome = .failed }
```

   `deactivate()` revokes the token while the eraser is parked, and when it returns `eraseBounded` reports `.failed`. `pendingPress` was already dropped by `deactivate`, so there is no restart.

- [ ] **Step 5: Run the tests and confirm they pass**, including the full matrix. Run `make test 2>&1 | tail -3`.
- [ ] **Step 6: Commit** with the §6.7 signature update. `feat(controller): erase and restate from the push-to-talk hold`.

---

### Task 8: Wiring and UI

**Files:**
- Modify: `Sources/Sotto/App/AppComposition.swift`, `Sources/Sotto/App/SottoApp.swift`, `Sources/Sotto/UI/SettingsWindow.swift`, `Sources/Sotto/UI/MenuBarContent.swift`, `Sources/Sotto/UI/HUDView.swift`, and any view that switches exhaustively on `State` (the compiler will name them)

- [ ] **Step 1: Composition.** Pass `eraseLast: { token in await DictationEraser.shared.eraseLast(token: token) }` to the controller.
- [ ] **Step 2: Launch.** In `applicationDidFinishLaunching`, before `controller.activate()`:

```swift
        TextInjector.configureAccessibilityTimeout()
        TextInjector.observer = DictationEraser.shared
        DictationEraser.shared.start()
```

   `start()` is idempotent. If Accessibility is not granted yet, the global keyboard monitor may install but receive nothing, so also call `DictationEraser.shared.start()` where the accessibility poll activates the controller. `start()` only records success, so change it to retry when `monitoring` is false.
- [ ] **Step 3: HUD.** In `HUDLabel.text`, add `case .erasing: "Erasing…"` and update the doc comment.
- [ ] **Step 4: Settings.** After `pushToTalkSection`, add `eraseSection`:

```swift
    private var eraseSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Erase")
                SegmentedChoice(
                    options: EraseKey.allCases.filter { !$0.conflicts(with: settings.pushToTalkKey) },
                    selection: Binding(
                        get: { settings.eraseKey },
                        set: { newValue in
                            settings.eraseKey = newValue
                            controller.reloadHotkey()
                        }
                    )
                ) { $0.displayName }
                Text(settings.eraseKey == .off
                     ? "Erasing is off."
                     : "Hold \(settings.pushToTalkKey.displayName) and press \(settings.eraseKey.displayName) to remove your last dictation and say it again.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkTertiary)
            }
        }
    }
```

   The spec says the conflicting option is "disabled"; filtering hides it instead. Update §6.14's wording to "hides" in this commit.

   `reloadHotkey()` ends a live hotkey utterance as a release. That is acceptable here, because changing Settings means the user isn't dictating.
- [ ] **Step 5: Menu bar.** Under the "Hold … to dictate" line:

```swift
            if Settings.shared.eraseKey != .off {
                Text("\(Settings.shared.pushToTalkKey.displayName) + \(Settings.shared.eraseKey.displayName) erases the last one")
                    .disabled(true)
            }
```

- [ ] **Step 6: Build and test.** Run `make build && make test 2>&1 | tail -3`. Expected: success, and all tests pass.
- [ ] **Step 7: Commit.** `feat(ui): erase key setting, menu hint and HUD state`.

---

### Task 9: Verification and hand-off

- [ ] **Step 1: Review.** Run an independent review of the whole branch diff against §6.16 and CLAUDE.md, on Sonnet as a gate pass. Also run Codex review. Fix P0 and P1 findings, one commit per fix.
- [ ] **Step 2: Install.** From the main checkout (not a worktree): `pkill -x Sotto; make install`. Confirm there is one running copy with `pgrep -x Sotto`.
- [ ] **Step 3: Acceptance with the user.** Work through §6.16 "Acceptance". Read the log with `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.conn3h.sotto"' --style compact | grep -E "erase|inject"`. Hardware audio rule: tell the user what to dictate; Sotto does not hold the mic outside their presses.
- [ ] **Step 4: Dictionary entries.** After the user confirms, add the approved context corrections to `~/Library/Application Support/Sotto/dictionary.txt`. Show them the diff first.
- [ ] **Step 5: PR.** Push the branch and open a PR with a summary and the acceptance results. Squash-merge only when the user says so.
