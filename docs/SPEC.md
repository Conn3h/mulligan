# Sotto — v1 specification (v1.1, after external review)

Push-to-talk dictation for macOS, entirely on-device. Hold a key, talk, release, and
cleaned-up text lands in whatever text field has focus. Native Swift 6, SwiftUI, Apple's
`SpeechAnalyzer`, no third-party dependencies, no app server. Nothing you say or type leaves
the Mac; macOS itself may download Apple-managed speech model assets on first use.

This document is the source of truth for v1. Implementers work from it, not from any other
dictation app. Interfaces below are contracts between milestones that are built in
parallel; do not rename them without updating every consumer named in §9. Revision history:
v1.0 drafted 2026-09-01; v1.1 the same day after an adversarial review
(`docs/reviews/2026-09-01-codex-spec-review.md`), which reshaped §6.5–6.8 around
per-utterance generations, single-flight termination, and injectable dependencies;
v1.2 (2026-09-02) records the implementation deviations accepted from batches A and B,
marked "as built" below.

---

## 1. Product definition

- **Hold a key, speak, release.** Right Option by default; Right Command and fn are the
  alternatives. Nothing is ever recorded unless the key is down.
- **Live text while speaking** in a small floating HUD that never steals focus.
- **Cleanup before insertion.** Deterministic rules always; optionally Apple's on-device
  Foundation Model for smarter cleanup, with the rules as fallback.
- **A personal dictionary.** Words the engine should know, and "when you hear X, write Y"
  corrections. Editable in the app and as a plain text file.
- **History.** Every dictation kept locally, searchable, copyable, deletable.
- **A real app.** Dock icon, main window, Settings on ⌘, and a menu bar item for status.

## 2. Non-goals for v1

Explicitly out: Windows, comparison tooling against other dictation apps, command mode
("make this more formal"), onboarding flow, notarization, an installer, cloud anything,
GitHub Actions (tests run locally via `make test`; CI stays off for now), and live
file-watching of the dictionary (see §6.12).

## 3. Clean-room rule

Sotto is written from this spec. **Do not read, search, or copy code from any other
dictation project**, including anything elsewhere on this machine. The spec was written by
someone who studied prior art; the implementation is written by someone who has not. Test
vectors, prompts, and copy are authored fresh. If the spec is ambiguous, choose the simplest
behaviour that satisfies the acceptance criteria and note the choice in your report.

## 4. Architecture and data path

```
 key down ─► HotkeyMonitor ──► DictationController ◄── Settings
                                    │  (one Utterance generation at a time)
                        ┌───────────┼─────────────┐
                        ▼           ▼             ▼
                  AudioCapture   HUD (observes)  TranscriptionEngine
                        │                          (AppleSpeechEngine)
                   AudioChunk ──ordered stream──►  │
                                                   ▼
                                           TranscriptSnapshot (full text so far)
                                                   │
 key up ──► controller's single terminal task drains, finishes the engine, then hands
            the final text to:
                                                   ▼
                                          UtterancePipeline
                                    format ─► dictionary ─► inject ─► history
                                                   │
                                            TextInjector ─► focused app
```

Invariants that the whole design rests on:

1. **The HUD never becomes key.** If it took focus, the target text field would lose it and
   there would be nothing to insert into.
2. **Audio reaches the engine in capture order and nothing is dropped.** One unbounded
   `AsyncStream` drained by exactly one task. Never spawn a task per buffer.
3. **Audio buffers are copied before crossing threads.** `AVAudioEngine` reuses the buffer
   it hands a tap the moment the callback returns.
4. **The engine's preferred format wins.** Apple's analyzer has a hard precondition on
   sample format (it terminates the process on a mismatch rather than throwing), so capture
   converts to whatever the engine asks for.
5. **One utterance at a time, and every utterance ends exactly once.** Each press starts a
   new generation; any task or callback belonging to an older generation is ignored; all
   terminal events (release, failure, quit, hotkey reload) funnel into one terminal task per
   generation, which is the only code that finishes the engine, fires the final callback,
   and returns the controller to idle.
6. **Every failure is logged**, with enough public context to diagnose from the unified log
   without a debugger. `try?` without a log line is not allowed anywhere in this codebase.

## 5. Package layout

```
Package.swift                 tools 6.2, macOS 26, three targets + three test targets
Makefile                      build / test / app / run / install / clean (see §7)
Resources/                    Info.plist, Sotto.entitlements, AppIcon.icns (later)
Sources/
  SottoText/                  Foundation-only. TextFormatter, RuleBasedFormatter,
                              PassthroughFormatter, CleanupGuard.
  SottoDictionary/            Foundation-only. DictionaryEntry, DictionaryFile,
                              DictionaryCorrector, AppliedCorrection, DictionaryWarning.
  Sotto/
    App/                      SottoApp.swift (scenes, AppDelegate), AppComposition.swift
    Core/                     DictationController, HotkeyMonitor, AudioCapture, TextInjector,
                              UtterancePipeline
    Speech/                   TranscriptionEngine (protocol, AudioChunk, TranscriptSnapshot),
                              AppleSpeechEngine
    Cleanup/                  FoundationModelFormatter, CleanupModel
    Dictionary/               DictionaryStore
    History/                  DictationRun, HistoryLog, HistoryStore
    UI/                       DesignSystem, TokenSheet, HUDPanel, HUDView, MainWindow,
                              SettingsWindow, DictionaryPanel, HistoryPanel, MenuBarContent,
                              Components
    Support/                  Log, Settings, Permissions
Tests/
  SottoTextTests/
  SottoDictionaryTests/       vectors.json is authored by the orchestrator (an oracle)
  SottoAppTests/              controller state machine and cleanup timeout, with fakes
docs/SPEC.md                  this file
docs/reviews/                 external review transcripts
```

Identifiers: app name **Sotto**, executable `Sotto`, bundle id `com.conn3h.sotto`, log
subsystem `com.conn3h.sotto`, Application Support directory
`~/Library/Application Support/Sotto/` holding `dictionary.txt` and `history.jsonl`.

## 6. Module specifications

Types are Swift 6 language mode, strict concurrency. `@MainActor` where stated. Public API
of the two library targets is `public`; everything in the app target is internal (the app
test target uses `@testable import Sotto`).

### 6.1 Logging — `Support/Log.swift` (exists)

`enum Log` with one `os.Logger` per category: `app`, `hotkey`, `audio`, `speech`, `inject`,
`dictionary`, `history`. Rules: interpolate non-user values with `privacy: .public`; never
log transcript text (log `text.count` instead); every caught error is logged at `.error`
with what was being attempted.

### 6.2 Settings — `Support/Settings.swift`

```swift
@MainActor @Observable final class Settings {
    static let shared: Settings
    var pushToTalkKey: PushToTalkKey     // default .rightOption
    var cleanupEnabled: Bool             // default true
    var smartCleanup: Bool               // default false (Foundation Model cleanup)
    var soundEnabled: Bool               // default true
}
```

Backed by `UserDefaults.standard`; each setter persists immediately. Read per-utterance by
consumers, so a change applies to the very next hold without a restart.

### 6.3 Permissions — `Support/Permissions.swift`

```swift
@MainActor enum Permissions {
    static var hasAccessibility: Bool            // AXIsProcessTrusted()
    static var hasMicrophone: Bool               // AVCaptureDevice status == .authorized
    @discardableResult static func promptForAccessibility() -> Bool   // AXIsProcessTrustedWithOptions with the prompt option
    static func requestMicrophone() async -> Bool
    static func openAccessibilitySettings()      // x-apple.systempreferences:… Privacy_Accessibility
    static func openMicrophoneSettings()
}
```

Note: `kAXTrustedCheckOptionPrompt` imports as a mutable global and is unusable from
strictly-concurrent code; spell the key out as the string `"AXTrustedCheckOptionPrompt"`.

### 6.4 Hotkey — `Core/HotkeyMonitor.swift`

```swift
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption, rightCommand, fn
    var keyCode: Int64          // kVK_RightOption 61, kVK_RightCommand 54, kVK_Function 63
    var flag: CGEventFlags      // see below
    var displayName: String     // "Right ⌥", "Right ⌘", "fn"
    var consumesEvent: Bool     // true for the two right-hand modifiers, false for fn
}

/// The seam the controller depends on, so tests can drive presses without a CGEventTap.
@MainActor protocol HotkeySource: AnyObject {
    var key: PushToTalkKey { get set }
    var onPress: (() -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
    @discardableResult func start() -> Bool   // false when the tap cannot be created (no Accessibility)
    func stop()
}

@MainActor final class HotkeyMonitor: HotkeySource { init() }
```

Behaviour:

- A `CGEvent.tapCreate` session tap (`.cgSessionEventTap`, `.headInsertEventTap`,
  `.defaultTap`) for `.flagsChanged` only, added to the main run loop in common modes.
  `NSEvent` global monitors cannot distinguish left from right modifiers or see fn, which
  is why a tap is required and why Accessibility is a hard requirement.
- **Use the device-specific modifier bits, not the public masks.** `.maskAlternate` is set
  when *either* Option key is down, so with Left Option held a Right Option release is
  invisible and the mic would stay open. Right Option is raw flag `0x40`, Right Command is
  `0x10`, fn is `.maskSecondaryFn`. Pressed state is `flags.contains(key.flag)` on an event
  whose keycode equals `key.keyCode`.
- Only transitions fire callbacks, tracked via `isPressed`: a same-state "up" is ignored, and
  a same-state "down" is never a mere repeat (`.flagsChanged` only fires on a real change) —
  it means a release was lost, handled below.
- On `.tapDisabledByTimeout` or `.tapDisabledByUserInput`, re-enable the tap and pass the
  event through. While the tap was disabled it delivered no events, so a key-up in that
  window produced no `.flagsChanged` and `isPressed` would be stale-high, stranding the
  utterance with the mic hot. After re-enabling, **reconcile**: read the key's real state
  (`CGEventSource.keyState(.combinedSessionState, key: key.keyCode)`, by keycode — the
  device-specific modifier bits are not reliable in `CGEventSource` flag state) and, if the
  key is no longer down while `isPressed` is true, emit the missed release. Only the release
  direction is reconciled; a missed press is left alone.
- A `.flagsChanged` reporting our key down while `isPressed` is already true is always a
  real transition, never a repeat: it means a release was lost with neither
  `.tapDisabledByTimeout` nor `.tapDisabledByUserInput` in between (the key came up during
  sleep or screen lock, which disables the tap without either event). Emit the missed
  release, then this press, rather than swallowing the second down and leaving the user
  talking to nothing.
- Return `nil` from the callback to swallow the event when `consumesEvent`, otherwise pass
  it through untouched. fn is never swallowed: swallowing it breaks fn-arrow, fn-delete and
  the emoji picker.
- The C callback runs on the main thread because the run loop source is on the main run
  loop. Extract plain values (`keyCode`, `flags`, `type`) from the `CGEvent` first, then
  cross into the main actor. `MainActor.assumeIsolated` is permitted **here only**, with a
  comment saying why; nowhere else in the app.
- `stop()` disables the tap, removes the run loop source, and resets `isPressed` **without
  emitting a release**; the controller is responsible for ending any utterance before it
  stops or reloads the monitor (§6.7).

The tap needs Accessibility and real events, so `handle(type:keyCode:flags:)` is internal
and the key-state probe is injectable, and `Tests/SottoAppTests/HotkeyMonitorTests.swift`
drives `handle` with plain values and a fake probe to cover: a key-up lost while the tap was
disabled is reconciled into a release on re-enable; no spurious release fires when the key is
still physically held across a tap flap; a second down for our key with no tap-disabled
event in between (the key came up during sleep or screen lock) emits the missed release
before starting the new press; and a release while the key is already considered up is
ignored.

### 6.5 Audio — `Core/AudioCapture.swift`

```swift
struct AudioChunk: @unchecked Sendable { let buffer: AVAudioPCMBuffer }   // lives in Speech/TranscriptionEngine.swift

protocol AudioCapturing: AnyObject, Sendable {
    func start(outputFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AudioChunk) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws
    func stop()
}

final class AudioCapture: AudioCapturing { init() }
```

Behaviour: `AVAudioEngine` input node tap, buffer size 2048 frames in the node's native
format; an `AVAudioConverter` to `outputFormat` when they differ (output capacity =
frames × rate ratio, rounded up, plus headroom). When no conversion is needed the buffer is
**deep-copied** (invariant 3); conversion already allocates fresh storage. `onLevel` gets an
RMS level mapped from roughly −50…0 dBFS onto 0…1 so quiet speech still moves the meter.

**A fresh `AVAudioEngine` is built on every `start()`**, not reused: a cached engine kept the
input device and format it first saw, so after AirPods connected or the input changed
between holds the tap could get a stale format, and one failed start poisoned every later
press until relaunch. The new engine costs a few milliseconds, logged alongside the native
and engine sample rates.

`start()` also registers for `.AVAudioEngineConfigurationChange`, before starting the
engine and keyed by a per-start token (a new engine can reuse an old one's address). The
observer runs on the posting thread (`queue: nil`) and only enqueues the handler on a
private serial queue: an observer registered *with* a queue makes the poster wait for it,
and the handler takes the lock `start()` holds while the engine may be posting. The engine stops itself on a device connect, disconnect, or a
Bluetooth profile switch; the handler re-installs the tap on the input's new native format
and restarts the engine, so a change mid-hold costs a moment of audio rather than the rest
of the utterance. If the restart itself fails, capture tears itself down and calls
`onInterruption(microphoneChangedMessage)` ("The microphone changed and could not be
restarted. Try again.") instead of leaving the utterance listening to silence; the
controller ends the utterance as a release and then shows that message (§6.7).

**No mutable state is shared with the audio thread.** `start()` builds one immutable
`Session` value (converter, output format, `onBuffer`, `onLevel`) and the tap closure
captures that value; the class itself holds only the running engine, the output format, all
three callbacks, and the configuration-change observer, bundled in one `Running` value
behind a `Synchronization.Mutex` (as built: the protocol requires `Sendable` and unchecked
conformance is forbidden). `stop()` removes the tap, stops the engine, and removes the
observer; a callback already in flight completes against its own captured session and its
output is discarded by the controller's generation check (§6.7). No `nonisolated(unsafe)`
fields, no `@unchecked Sendable` on anything but `AudioChunk`.

Logs the native → engine sample rates on start, and every conversion error. `start()` while
running is a logged no-op; `stop()` is idempotent.

### 6.6 Transcription — `Speech/TranscriptionEngine.swift`, `Speech/AppleSpeechEngine.swift`

```swift
struct TranscriptSnapshot: Sendable {
    let text: String      // the FULL transcript so far, not a delta; consumers replace, never append
    let isFinal: Bool     // true means: no further snapshots will follow for this session
}

protocol TranscriptionEngine: Actor {
    func preferredInputFormat() async -> AVAudioFormat?
    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error>
    func feed(_ chunk: AudioChunk) async
    /// Close input, wait for every result already published, emit the final snapshot,
    /// finish the stream. Idempotent.
    func finish() async
    /// Abort now: close input, discard pending results, finish the stream (throwing
    /// CancellationError if it has not finished), release everything. Idempotent, and safe
    /// to call at any point including before or during start().
    func cancel() async
}

enum TranscriptionError: LocalizedError { case localeUnsupported(Locale), modelInstallFailed(String), noAudioFormat, notRunning }

actor AppleSpeechEngine: TranscriptionEngine {
    init(locale: Locale = .current, biasPhrases: [String] = [])
    /// Resolves the locale and installs assets ahead of time so the first hold is fast.
    static func prepare(locale: Locale = .current) async
}
```

`AppleSpeechEngine` behaviour, in this order in `start()`:

1. Throw `localeUnsupported(locale)` if `SpeechTranscriber.isAvailable` is false.
2. Resolve the locale: `await SpeechTranscriber.supportedLocale(equivalentTo: locale)`;
   if nil, try the same for `Locale(identifier: "en-US")`; if that is nil too, throw
   `localeUnsupported` **with the originally requested locale**.
3. Construct `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
   with `transcriptionOptions: []`, `reportingOptions: [.volatileResults]` (live text
   while speaking), `attributeOptions: []`.
4. `if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])`
   then `try await request.downloadAndInstall()`, logging both ends; `nil` means the assets
   are already installed. Wrap errors as `modelInstallFailed`.
5. Create `SpeechAnalyzer(modules: [transcriber])`. If `biasPhrases` is non-empty, set an
   `AnalysisContext` whose `contextualStrings[.general]` is the list, **before any audio
   arrives**, logging the count.
6. Create the `AsyncStream<AnalyzerInput>` input, the output
   `AsyncThrowingStream<TranscriptSnapshot, Error>`, and start the **result-drain task**
   that iterates `transcriber.results`, folds each result into the accumulator, and yields a
   snapshot with `isFinal: false`. Store this task.
7. `try await analyzer.start(inputSequence:)`. Log the resolved locale.

`preferredInputFormat()` returns `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:
[transcriber])`, creating a transcriber for the resolved locale if `start()` has not run.

Accumulation: final results are appended to a committed string; a volatile result is shown
appended to the committed text but never stored, so the next revision replaces it cleanly.
Each snapshot's `text` is committed + volatile, trimmed.

`finish()`: end the input stream; `try await analyzer.finalizeAndFinishThroughEndOfInput()`
(on error, log and `await analyzer.cancelAndFinishNow()`); **then await the stored
result-drain task** (results already published by the module can still be pending after the
analyzer finishes, and reading the committed text before the drain completes loses them);
then yield `TranscriptSnapshot(text: committed, isFinal: true)`, finish the output stream,
and release the analyzer and transcriber. Second call is a no-op.

`cancel()`: end the input stream; `await analyzer?.cancelAndFinishNow()`; cancel and await
the drain task; finish the output stream with `CancellationError()` if it is still open;
release everything. Second call is a no-op. Never throws.

`prepare(locale:)`: steps 1–4 only, logging the outcome; errors are logged, never thrown.
Called once at app launch (§6.15) so a cold machine pays the asset download before the
first hold rather than during it.

Never log transcript text.

### 6.6a Parakeet (experimental) — `Speech/ParakeetSpeechEngine.swift`, `Speech/ParakeetModels.swift`, `Speech/SpeechEngineChoice.swift`

A second engine behind the same seam, for side-by-side accuracy testing against Apple. It
is the one third-party dependency: `FluidAudio` (SwiftPM, statically linked, `traits: []`
so the NeMo text-normalisation xcframework is not pulled in), which ships NVIDIA
Parakeet TDT 0.6B as CoreML. FluidAudio's own resource bundle is only read by its TTS code,
which Sotto never calls, so `make app` does not copy it.

```swift
enum SpeechEngineChoice: String, CaseIterable, Sendable { case apple, parakeet }
    // displayName for Settings, engineName ("Apple" / "Parakeet") for DictationRun.engine

@MainActor @Observable final class ParakeetModels {
    enum State: Equatable, Sendable { case idle, downloading(fraction: Double), loading, ready, failed(String) }
    static let shared: ParakeetModels
    static let version: AsrModelVersion   // .v2, English-only
    private(set) var state: State
    func prepare()                        // download + load once; idempotent; retried after a failure
    struct Loaded: Sendable { let asr: AsrModels; let ctc: CtcModels? }
    func readyModels() throws -> Loaded  // throws modelInstallFailed with the reason while not ready
}

actor ParakeetSpeechEngine: TranscriptionEngine { init(biasPhrases: [String] = []) }
```

Behaviour:

- `Settings.speechEngine` (default `.apple`) is read per press by `AppComposition`'s engine
  factory, which also records the choice's `engineName` for the pipeline's history record
  (`UtterancePipeline.init(readEngineName:)`), so a switch made mid-utterance cannot mislabel
  a run.
- Models live in FluidAudio's default cache (`~/Library/Application Support/FluidAudio/Models/`).
  `ParakeetModels.prepare()` runs at launch when Parakeet is selected and when the user
  switches to it in Settings, never from a press: a press while the models are downloading
  or loading throws `modelInstallFailed` with the progress, which the HUD shows as an error,
  rather than holding the utterance open for a multi-minute download.
- `preferredInputFormat()` is 16 kHz mono Float32, so capture converts once and the
  library's converter takes its no-op path.
- `start()` builds a `SlidingWindowAsrManager` with the `.streaming` preset and the model
  version's blank id, takes its update stream **before** `startStreaming`, and runs a drain
  task that, after each update, reads the manager's confirmed and volatile transcripts and
  yields their join as a non-final snapshot.
- `finish()` awaits the manager's `finish()` (which flushes the remaining audio and returns
  the final text; on error the last live text is kept and the error logged), cancels the
  drain (the library never ends its update stream), yields the final snapshot, and releases.
- `cancel()` cancels the manager, the drain, finishes the stream with `CancellationError`,
  and releases; the same phase machine and idempotence rules as `AppleSpeechEngine`.
- Bias phrases are applied as FluidAudio vocabulary boosting: `ParakeetModels` also loads the
  separate CTC 110M encoder (`CtcModels.downloadAndLoad()`), and `start()` calls
  `configureVocabularyBoosting` with one `CustomVocabularyTerm` per phrase before streaming
  begins, logging the count. The rescorer's engine-wide floor (`minBiasSimilarity`, 0.75
  spelling similarity) is too loose for a short single-word term, which is often one edit
  from an ordinary word ("code" to Codex is 0.80); each such term (six characters or fewer,
  no space or hyphen) gets a per-term `minSimilarity` of 0.85 instead — above the 0.83 that
  one edit costs a six-character word — from `BiasStrictness.minimumSimilarity(for:)`
  (`SottoDictionary`), so it only replaces a spelling that is nearly exact. The rescorer runs
  with `spotterRescueEnabled: false`: the acoustic rescue replaces correctly heard words with
  unspoken dictionary terms (a "Kubernetes" entry swallowed "the quick brown fox" in
  testing), and the library's own benchmarks show turning it off cuts false positives roughly
  five-fold while raising recall. A CTC load failure is logged and leaves `Loaded.ctc` nil;
  the engine then transcribes without bias and logs the skipped count. Corrections still run
  in the pipeline either way.
- Settings gets an "Engine" section: a `SegmentedChoice` over `SpeechEngineChoice` and a
  caption that reflects `ParakeetModels.state`.

### 6.7 Controller — `Core/DictationController.swift`

```swift
enum UtteranceSource: Sendable { case hotkey, button }

struct Utterance: Sendable {
    let source: UtteranceSource
    let heldSeconds: TimeInterval   // measured with ContinuousClock, key down → key up
    let releasedAt: Date            // wall clock, for history display only
    let targetProcessID: pid_t?     // frontmost app's pid at release; text is typed only if
                                     // it is still frontmost when the text is ready; nil when unknown
}

@MainActor @Observable final class DictationController {
    enum State: Equatable {
        case idle, starting, listening, finishing, error(String)
        var isActive: Bool        // starting | listening | finishing
        var showsHUD: Bool        // isActive || error
    }
    private(set) var state: State
    private(set) var transcript: String          // live, drives the HUD
    private(set) var level: Float                // smoothed 0…1
    private(set) var holdStartedAt: Date?        // for the main window's elapsed counter

    init(hotkey: any HotkeySource,
         capture: any AudioCapturing,
         requestMicrophone: @escaping @MainActor () async -> Bool,
         makeEngine: @escaping @MainActor () -> any TranscriptionEngine,
         errorDisplayDuration: Duration = .seconds(3),
         engineFinishTimeout: Duration = .seconds(2),   // cap on engine.finish() in the terminal path
         minimumHold: Duration = .milliseconds(250),    // a shorter release is a mis-tap: cancel, don't finalize
         maxHold: Duration = .seconds(180),             // cap on .listening: a stuck recording ends as a release
         deliveryTimeout: Duration = .seconds(10))      // cap on onFinalTranscript so a hung pipeline cannot wedge .finishing

    /// Receives the final raw transcript once per utterance. Awaited before returning to idle.
    /// A returned message (the text was recorded but not typed) is shown as the ending error.
    var onFinalTranscript: (@MainActor (String, Utterance) async -> String?)?

    @discardableResult func activate() -> Bool    // installs the hotkey from Settings; false = no Accessibility
    func deactivate()                              // ends any utterance (no final callback), stops the hotkey
    @discardableResult func reloadHotkey() -> Bool // ends a hotkey utterance as a release, then re-arms
    func startButtonRecording()                    // press with source .button
    func stopButtonRecording()                     // release
    /// Number of tasks belonging to any utterance that have not completed. Exposed for tests.
    var liveTaskCount: Int { get }
}
```

The real app builds it through `AppComposition` (§6.15) with `HotkeyMonitor`,
`AudioCapture`, `Permissions.requestMicrophone`, and an `AppleSpeechEngine` factory.

**Generations.** Every press increments a private `generation` counter and creates a
private `Session` value holding: the generation id, the source, the hold start instant,
the engine, the audio continuation, and the tasks below. Every suspension point in every
task compares the session's id to the controller's current generation and checks
`Task.isCancelled`; on mismatch it stops immediately (cancelling its own engine if it owns
one that the controller no longer references). Callbacks from capture (`onLevel`,
`onBuffer`) carry the generation they were created for and are ignored when stale.

**Press** (only from `.idle`; from `.error` too, which clears the error): new generation,
state `.starting`, transcript cleared, `holdStartedAt` set. Start the **setup task**:

1. `await requestMicrophone()`; false → terminate with `.failed("Microphone access is
   off. Enable it in System Settings > Privacy & Security > Microphone.")`.
2. `makeEngine()`, store it in the session, `try await engine.start()` → the snapshot
   stream.
3. `await engine.preferredInputFormat()`; nil → `.failed(TranscriptionError.noAudioFormat)`.
4. Create the audio stream with `bufferingPolicy: .unbounded` (invariant 2) and store the
   continuation. Start the **drain task** (detached, user-initiated): `for await chunk in
   stream { await engine.feed(chunk) }`.
5. `try capture.start(outputFormat:onBuffer:onLevel:onInterruption:)` with `onBuffer`
   yielding into the continuation; `onLevel` hopping to the main actor to apply
   `level += (new - level) * 0.35` and track the hold's peak level (logged at release), both
   only if the generation is still current; and `onInterruption` hopping to the main actor
   to end the utterance **as a release** if the generation is still live (capture could not
   survive a device change, §6.5), so everything said before the change is still delivered,
   and to show the message afterwards.
6. State `.listening`; play the start sound if `Settings.shared.soundEnabled`. Start the
   **consume task** on the main actor: `for try await snapshot in stream { transcript =
   snapshot.text }`; if the stream throws, log and terminate with `.failed(message)`. Also
   start the **watchdog task**: after `maxHold`, if the utterance is still the live
   generation and still `.listening`, terminate with `.released`. This is the backstop for a
   release that is never delivered (a key-up lost while the event tap was disabled, or during
   sleep or screen lock); `maxHold` is generous so no real hold is cut short. `terminate`
   cancels the watchdog when any real terminal event arrives.

Any thrown error in the setup task terminates with `.failed(message)`. If the session was
terminated while the setup task was suspended, the setup task's next check sees the
mismatch and exits; nothing it created leaks because the terminal task cancels and awaits
it (below).

**Terminal events** are `.released`, `.failed(String)`, and `.aborted` (quit, deactivate).
`terminate(reason:)` is the **only** path out of an utterance:

- If the session already has a terminal task, `.released` and `.aborted` return
  immediately (the first terminal event wins); `.failed` after a release is logged and
  ignored.
- A `.released` held for less than `minimumHold` is a mis-tap, not dictation, and is
  converted to `.tapped` before anything else: the engine is cancelled instead of finalized,
  the state never becomes `.finishing`, and no callback fires, so a quick tap recovers
  instantly rather than flashing "Transcribing..." while a finalize that saw almost no audio
  stalls (the `engineFinishTimeout` above is the backstop for a longer release that still
  captured nothing; `minimumHold` is the instant path for the obvious tap). `.tapped`
  otherwise behaves exactly like `.aborted`.
- Otherwise create and store the **terminal task** (main actor) and, for `.released`, set
  state `.finishing`, stop capture, zero the level, record the release instant and the
  frontmost app's pid (`NSWorkspace.shared.frontmostApplication?.processIdentifier`) as the
  utterance's `targetProcessID` — the text is typed later, after finishing and cleanup, only
  if that app is still frontmost then (§6.8). The task:
  1. Cancel the setup task and await it (so a suspended setup cannot resume later).
  2. Stop capture (idempotent), finish the audio continuation, await the drain task.
  3. `.released` → finish the engine, bounded by a **finish timeout that grows with the
     hold**: `finishTimeout(base:heldSeconds:)` is `engineFinishTimeout` plus 0.25 s per
     second held, capped at `finishTimeoutCap` (15 s) — Parakeet decodes nothing until 13 s of
     audio is buffered, so a hold shorter than that is decoded entirely after release, and a
     fixed cap would abandon it mid-decode. If `engine.finish()` does not return in time it is
     abandoned and `engine.cancel()` is called instead, so a stalled finalize (a quick tap
     that releases just after listening begins can hang the analyzer's
     `finalizeAndFinishThroughEndOfInput`) can never wedge the utterance in `.finishing`.
     `.tapped` / `.failed` / `.aborted` → `await engine.cancel()`.
  4. Await the consume task (it ends when the stream finishes).
  5. `.released`: log the hold's peak meter level, then: a blank transcript fires no
     callback; a transcript made only of hesitation sounds (**filler-only**, below) is
     discarded; otherwise deliver `onFinalTranscript?(raw, utterance)`, bounded by `deliveryTimeout`: if
     delivery (formatting + injection) does not finish in time the controller stops waiting
     and proceeds to idle, so a hung pipeline or AX injection cannot wedge `.finishing` (the
     one state the Stop button cannot rescue); the in-flight delivery is left running rather
     than cancelled, so a slow injection is never cut mid-paste.
  6. Clear the session and `holdStartedAt`. `.failed` always shows `.error(message)`.
     `.tapped` and `.aborted` always show `.idle`. `.released` shows `.idle` too, unless one
     of these applies, in which case it shows `.error(message)` instead (the first that
     applies wins): the finish timed out and the transcript was blank
     (`transcriptionTimedOutMessage`, "Transcription took too long; nothing was typed. Try
     again."); the finish timed out but a transcript was still delivered
     (`transcriptionIncompleteMessage`, "Transcription took too long; the end may be
     missing."); delivery itself returned a message because the pipeline recorded the text
     without typing it (§6.8); or capture was interrupted (`microphoneChangedMessage`). Any
     of these auto-returns to `.idle` after
     `errorDisplayDuration` unless the state has changed since.

**Filler-only transcripts.** Parakeet transcribes a silent hold as a hesitation sound
("Mm-.", "Hmm.") that used to get typed. `FillerOnly.matches` (`SottoText`) is true when a
transcript has at least one word and every word — split on whitespace and hyphens, with
surrounding punctuation trimmed — is `m`, `mm`, `mmm`… or one of `hmm hm mhm uh um erm uhm er ah eh`
(stretched forms such as "hmmm" count). A word holding a digit or symbol ("42", "50%") is
content, so "Um, 42." is kept. Such a transcript is discarded at step 5; any real
word keeps it. Loudness cannot make this decision: on a laptop microphone in a normal room a
quiet one-word answer peaks no higher on the meter than a silent hold's background noise
(measured 0.21–0.35 against 0.21–0.27), so a level threshold either misses silent holds or
swallows short words.

**Press while ending**: a press that arrives while the session is terminating (the user
presses again during "Transcribing…", or a recovered lost release is followed at once by
its press, §6.4) is **queued**, not dropped: it starts as soon as the terminal task returns
the controller to idle or error. A release matching the queued press (or the Stop button)
before then drops it instead, and so do `deactivate()` and, for a queued hotkey press,
`reloadHotkey()`: the new key's monitor never sees the old key's release, so a press queued
under it would start recording with nothing held.

**Release**: the hotkey's key-up calls `release(onlyFrom: .hotkey)`, which runs
`terminate(reason: .released)` only if the live session was also started by the hotkey; a
Record-button utterance is left running, so holding the push-to-talk key for something else
(Command-Tab, a special character) while Recording from the main window cannot cut it short.
`stopButtonRecording()` calls `release()` with no source restriction, ending whichever
utterance is live. Either way, no session or a terminal task already running is ignored.
**`deactivate()`**: `terminate(.aborted)`, then `hotkey.stop()`. **`reloadHotkey()`**: if a
hotkey session exists, `terminate(.released)` (the user's physical release will be invisible
to the new monitor); a Record-button session does not depend on the key and keeps running,
so changing the key in Settings cannot cut it short. Then `hotkey.stop()`, reread the key
from Settings, `hotkey.start()`.

**Tests** (`Tests/SottoAppTests/DictationControllerTests.swift`, Swift Testing, with a
fake hotkey, a fake capture that records calls and can emit buffers and levels on demand, a
fake engine whose `start()`/`preferredInputFormat()`/`finish()` can be suspended and
resumed by the test, and a `requestMicrophone` closure the test controls) must cover, each
as its own test:

- press → listening → release → exactly one `onFinalTranscript` with the engine's final
  text, then idle, with `liveTaskCount == 0`.
- release while setup is suspended at each of: microphone request, `engine.start()`,
  `preferredInputFormat()`; in each case no capture buffer is fed after the release, the
  engine is cancelled or finished exactly once, and a **new press after the release** starts
  a fresh generation whose engine is a different instance and whose transcript is untouched
  by the old setup resuming.
- duplicate release (two releases in a row) → one callback.
- press while `.finishing` → queued: a new utterance starts once the old one reaches idle;
  a press and release both inside `.finishing` → dropped, no new utterance.
- engine `start()` throws → `.error`, then `.idle` after the display duration, no callback.
- snapshot stream throws during listening → `.error`, capture stopped, no callback.
- microphone denied → `.error` with the message, no engine created.
- `deactivate()` during listening → engine cancelled, no callback, idle, hotkey stopped.
- `reloadHotkey()` during listening → utterance ends as a release (callback fires), then
  the hotkey is restarted with the new key.
- feed order: fifty buffers emitted by the fake capture arrive at the fake engine in order.
- blank final transcript → no callback.
- a release held for less than `minimumHold` → engine cancelled, state never `.finishing`,
  no callback, idle (the quick-tap instant-recovery path).
- a `.released` whose `engine.finish()` never returns → bounded by the finish timeout, after
  which the engine is cancelled and the controller shows `transcriptionTimedOutMessage`
  before reaching `.idle` (no silent wedge).
- `finishTimeout(base:heldSeconds:)`, as a pure function: equals `base` at zero held seconds,
  grows with `heldSeconds`, and never exceeds `finishTimeoutCap`.
- a `.listening` utterance that is never released → the `maxHold` watchdog ends it as a
  release, delivering the transcript and reaching `.idle` (the lost-release backstop).
- a `.released` whose `onFinalTranscript` never returns → bounded by `deliveryTimeout`,
  after which the controller reaches `.idle` without waiting (no `.finishing` wedge).
- stale level callback (from the previous generation) does not change `level`.
- `.button` source is passed through to the callback.
- a filler-only transcript ("Mm-.") is discarded: no callback fires.
- a quiet one-word transcript ("Yes.") with low meter levels throughout is delivered.
- a hotkey release does not end a utterance the Record button started; `stopButtonRecording`
  still ends it.
- a capture interruption (a device change `AudioCapture` could not survive, §6.5) ends a
  live utterance as a release: the transcript is delivered, then its message is shown.
- a message returned by `onFinalTranscript` (the pipeline recorded the text but did not type
  it) is shown as the ending error, then the controller returns to `.idle`.

Write these tests first; the fake types live in `Tests/SottoAppTests/Fakes.swift`.

### 6.8 Pipeline and injection — `Core/UtterancePipeline.swift`, `Core/TextInjector.swift`

```swift
@MainActor final class UtterancePipeline {
    init(engineName: String = "Apple")
    func process(raw: String, utterance: Utterance) async -> String?   // a message when the text was recorded but not typed
}

@MainActor enum TextInjector {
    static func insert(_ text: String) async -> Bool   // as built: async, so the ~540 ms paste sequence never blocks the main actor; false when neither path delivered the text
}
```

`process`: choose the formatter per utterance (`Settings.cleanupEnabled` off →
`PassthroughFormatter`; on and `smartCleanup` and the Foundation Model available →
`FoundationModelFormatter`; otherwise `RuleBasedFormatter`); format; apply
`DictionaryStore.shared.corrector` **regardless of the cleanup setting** (biasing only
raises the odds of the right word, the correction pass guarantees it, so it must not be
switchable off by accident); record a `DictationRun` (§6.13) with `processSeconds` measured
with `ContinuousClock` from the moment `process` was entered plus the caller-supplied
release-to-entry gap (the controller passes `heldSeconds`; the pipeline measures its own
duration; `processSeconds` = pipeline duration), which is the latency the user actually
feels; **inject only when `utterance.source == .hotkey`**, and only into the app that was
frontmost at release. The text is not ready to type until after finishing and cleanup, so
`Utterance.targetProcessID` carries the frontmost app's pid captured at release (§6.7); a
hotkey utterance compares it against the frontmost app now, and types only on a match.
Play the end sound, meaning "the text landed", only when it actually did.

Why the source check: pressing Record in Sotto's own window activates Sotto and focuses
the button, so the system-wide focused element is Sotto's, not the field the user was
writing in. A button-started utterance is therefore recorded to history (where Copy is one
click away) and never injected. The History panel labels such rows "recorded".

`process` returns a message for the controller to show as the utterance's ending error
(§6.7) whenever the text was recorded to history but not typed: `focusMovedMessage`
("You switched apps before the text was ready; it is in History.") when the frontmost app
changed since release (checked before injection, and again by `TextInjector` right before
⌘V, since the accessibility verification and settle waits suspend), or `insertFailedMessage` ("The text could not be typed; it is in
History.") when `TextInjector.insert` itself reports that neither strategy delivered the
text. Either way the sound stays silent, but the run is still recorded and returns `nil`
otherwise.

Log the count of corrections applied and the character count injected or recorded.

`TextInjector.insert(_:targetProcessID:)` tries two strategies in order and returns an
`Outcome`: `.landed`, `.failed`, or `.focusMoved` (another app came to the front before the
paste, so nothing was typed):

1. **Accessibility, verified.** Get the system-wide focused element; require
   `kAXSelectedTextAttribute` to be settable; read `kAXSelectedTextRangeAttribute` and
   `kAXNumberOfCharactersAttribute` before the write; set the selected text to `text`. The
   write can report success and still drop the text (Electron, Chrome, most terminals do),
   and some apps (Firefox) apply it at once but report the new selection only 10–20 ms
   later, so **poll for up to 150 ms** rather than checking once. `ExpectedWrite` decides
   what counts: the selection changed and its end now lies between half and twice the
   inserted length past where the write started (plus a tolerance of 2 UTF-16 units or a
   tenth of the insertion), or a field the write should grow grew by between half and twice
   the inserted length less what it replaced (a field it should shrink must land within the
   tolerance). The wide band is deliberate: editors that convert on insert (markdown, emoji
   shortcodes, autocorrect) change the landed length, and treating their write as failed
   pastes it a second time. Backwards moves, small changes and far jumps (a terminal
   printing a screenful) are someone else's and do not count. No evidence inside the timeout falls back to the pasteboard.
2. **Pasteboard + ⌘V.** Add one leading space to `text` only when the previous injection
   was Sotto's own, into the same frontmost application, within eight seconds, and did not
   end in whitespace; otherwise paste `text` unchanged (the paste path cannot read the
   target to look at the character before the caret, unlike the accessibility path, so it
   uses this bounded same-app heuristic instead). Save every pasteboard item's data by
   type; write the (possibly space-prefixed) text as a plain string and **record
   `pasteboard.changeCount`**; wait ~40 ms so the target observes the new pasteboard
   generation; post ⌘V as `CGEvent`s from a `.privateState` source with
   `flags = .maskCommand` set explicitly (do not inherit live hardware modifier state; the
   user may still be resting a finger on a key); wait ~500 ms for the asynchronous paste;
   **restore the saved items only if `changeCount` is still the value recorded after our
   write**, otherwise log that restoration was skipped because the pasteboard changed
   underneath us. The deliberate tradeoff: a caret moved within that window and app is a
   rare false positive, preferred over reliably-glued run-ons in Electron and Chromium apps.

Log which strategy was used and why the AX path was not trusted, with the character count.

### 6.9 SottoText — `Sources/SottoText/`

```swift
public protocol TextFormatter: Sendable { func format(_ raw: String) async -> String }
public struct RuleBasedFormatter: TextFormatter { public init() }
public struct PassthroughFormatter: TextFormatter { public init() }   // trims only

public enum CleanupVerdict: Sendable, Equatable { case accepted; case rejected(reason: String) }
public enum CleanupGuard {
    public static func evaluate(original: String, cleaned: String) -> CleanupVerdict
}
```

`RuleBasedFormatter.format`, in order:

1. Trim; empty in → empty out.
2. **Strip standalone fillers** `um, uh, erm, uhm, hmm, mhm` as whole words,
   case-insensitive, together with one immediately following comma if present. A word is
   standalone when it is not preceded by a letter, digit, or apostrophe and not followed by
   a letter or digit. Must not touch words that merely contain them (`umbrella`, `hummus`,
   `ums`).
3. **Spoken punctuation**: the whole-phrase, case-insensitive `new paragraph` → `\n\n` and
   `new line` → `\n`, fenced like fillers (not preceded by a letter, digit or apostrophe, not
   followed by a letter or digit), so `renew paragraph` is left alone.
4. **Collapse whitespace**: runs of spaces and tabs to one space; remove spaces and tabs
   immediately before or after a newline; remove spaces before `, . ! ? ; :`; three or more
   consecutive newlines to two; trim.
5. **Capitalise sentence starts.** The first letter of the text, the first letter after a
   newline, and the first letter after a terminator (`.`, `!`, `?`) **that is immediately
   followed by whitespace or end of text**. A terminator with a non-whitespace character
   after it is not a boundary. Only the next *letter* is capitalised, and only if no other
   letter has been seen since the boundary: a boundary followed by digits then letters
   capitalises nothing (`3 apples`).
6. **Terminal punctuation**: if the last character is a letter or digit, append `.`.

Exact examples the tests must include (input → output):

| Input | Output |
|---|---|
| `um, hello there` | `Hello there.` |
| `I think, uh, it works` | `I think, it works.` |
| `the umbrella and the hummus` | `The umbrella and the hummus.` |
| `removing all the ums` | `Removing all the ums.` |
| `hello new paragraph world` | `Hello\n\nWorld.` |
| `first new line second` | `First\nSecond.` |
| `new paragraph hello` | `Hello.` |
| `hello new paragraph` | `Hello.` |
| `one new paragraph new paragraph two` | `One\n\nTwo.` |
| `it cost 3.5 million dollars` | `It cost 3.5 million dollars.` |
| `see www.example.com for details` | `See www.example.com for details.` |
| `e.g. this one` | `E.g. This one.` |
| `3 apples and 2 pears` | `3 apples and 2 pears.` |
| `is it working? yes it is` | `Is it working? Yes it is.` |
| `wait , what ?` | `Wait, what?` |
| `already done.` | `Already done.` |
| `   ` | `` |

(`e.g. This one` is the documented limitation: the abbreviation itself is preserved, the
word after it is capitalised.)

`CleanupGuard.evaluate` decides whether a model-produced cleanup is recognisably a cleanup
of the input rather than an *answer* to it (dictate "what is the capital of France" and a
helpful model returns "The capital of France is Paris."). Tokenisation for every check:
lowercase, then split on any character that is not a letter or digit (so `isn't` → `isn`,
`t`; `3.5` → `3`, `5`). Content words are tokens not in the stop set
`a an the and or but so then s t re ll ve d m`. Checks, in order:

1. **Empty**: reject if `cleaned` has no content words, or `original` has no content words.
   Reason: `empty`.
2. **No invented content words**: reject if any content word of `cleaned` does not occur
   among the content words of `original`. Reason: `invented: w1, w2, …` (up to five).
3. **Length ratio**: `ratio = cleanedContentCount / denominator` where `denominator` is the
   count of original content words that are not in the single-token filler set
   `um uh erm uhm hmm mhm like basically actually literally just really okay ok well right
   anyway i mean you know kind sort of stuff thing things`; if that count is zero, use the
   undiscounted content count instead. Reject unless `0.35 <= ratio <= 1.5`. Reason:
   `length ratio 0.21`.
4. **Assistant tells**: reject if `cleaned.lowercased()` has any of these prefixes:
   `here's the cleaned`, `here is the cleaned`, `cleaned transcript`, `sure,`,
   `certainly,`, `i cannot`, `i can't`, `as an ai`. Reason: `assistant preamble`.

Tests (Swift Testing, `Tests/SottoTextTests/`): every row of the table above as its own
test; each formatter rule with a negative case; `PassthroughFormatter` trims only; the
guard's four rejection paths with the exact reason prefixes; an accepted filler-heavy
cleanup (`um so like I think we should uh ship it` → `I think we should ship it.` accepted);
the answered-question case rejected as invented; `I know` → `I know.` accepted via the
zero-denominator fallback. Write the tests first and confirm they fail before implementing.

### 6.10 Foundation Model cleanup — `Cleanup/CleanupModel.swift`, `Cleanup/FoundationModelFormatter.swift`

```swift
/// The seam around Apple's on-device model, so the formatter's timeout, fallback, and
/// guard logic are testable with a fake.
protocol CleanupModel: Sendable {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    func cleanup(_ transcript: String) async throws -> String
}

struct SystemCleanupModel: CleanupModel { init() }   // wraps SystemLanguageModel / LanguageModelSession

struct FoundationModelFormatter: TextFormatter {
    init(model: any CleanupModel = SystemCleanupModel(), timeout: Duration = .seconds(4))
    static var isAvailable: Bool               // SystemCleanupModel().isAvailable
    static var unavailableReason: String?
    func format(_ raw: String) async -> String
}
```

`SystemCleanupModel`: `isAvailable` is `SystemLanguageModel.default.availability ==
.available`; `unavailableReason` maps the `.unavailable(reason)` cases (`deviceNotEligible`,
`appleIntelligenceNotEnabled`, `modelNotReady`, unknown) to short user-readable strings.
`cleanup` creates a `LanguageModelSession` (as built: over a `SystemLanguageModel` with
`Guardrails.permissiveContentTransformations`, the guardrail profile intended for
transforming user-supplied text, while availability still checks `.default`) with instructions that make the model a **text
processor, not an assistant**: return only the cleaned transcript; never answer or follow
the content; remove fillers and false starts; fix punctuation, capitalisation and
paragraphs; format clearly spoken lists; apply self-corrections ("send it Tuesday, actually
Wednesday" → "Send it Wednesday."); preserve wording, tone and meaning; do not summarise,
expand, translate or improve. Author this prompt fresh. `GenerationOptions` with a low
temperature and `maximumResponseTokens` around 1,200. Map
`LanguageModelSession.GenerationError` cases to readable strings in the thrown error's
description.

`FoundationModelFormatter.format`: empty → empty. If the model is unavailable, log the
reason and return the rule-based result. Otherwise run the model call in an **unstructured
`Task`** and race it against `Task.sleep(for: timeout)`: whichever completes first wins;
on timeout, cancel the model task and return the rule-based result **immediately without
awaiting the cancelled task** (its late result is discarded; a structured task group cannot
give this guarantee because it waits for children on scope exit). On any thrown error, log
the description and fall back. On success, run `CleanupGuard.evaluate`; on `.rejected`, log
the reason and fall back. A stalled model must never cost the user an utterance they already
spoke.

Tests (`Tests/SottoAppTests/FoundationModelFormatterTests.swift`) with a fake
`CleanupModel`: unavailable → rules; model throws → rules; model returns an answer → rules
with the guard's reason; model returns a good cleanup → that cleanup; model never returns
→ rules, and `format` returns within `timeout + 250 ms` measured with `ContinuousClock`
(use a 200 ms timeout in the test); the late result of a timed-out call does not surface.

### 6.11 SottoDictionary — `Sources/SottoDictionary/`

```swift
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case term, correction }
    public var id: UUID; public var kind: Kind
    public var write: String     // the correct text; for .correction, what gets written
    public var hear: String      // .correction only: what the engine tends to produce
    public var isEnabled: Bool
    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true)
    public static func term(_ word: String) -> DictionaryEntry
    public static func correction(hear: String, write: String) -> DictionaryEntry
}

public enum DictionaryFile {
    public static func parse(_ text: String) -> [DictionaryEntry]
    public static func serialize(_ entries: [DictionaryEntry]) -> String
}

public struct AppliedCorrection: Codable, Hashable, Sendable {
    public let from: String; public let to: String; public let count: Int
    public init(from: String, to: String, count: Int)
}

public struct DictionaryCorrector: Sendable {
    public init(entries: [DictionaryEntry])
    public var isEmpty: Bool
    public func apply(to text: String) -> (text: String, applied: [AppliedCorrection])
    public static let biasLimit: Int   // 100
    public static func biasPhrases(from entries: [DictionaryEntry]) -> [String]
}

public struct DictionaryWarning: Identifiable, Sendable, Equatable {
    public var id: String { message }; public let message: String
    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning]
}
```

**File format**, one entry per line. A bare line is a term. A line containing `->` is a
correction: the text before the **first** `->` is `hear`, everything after it is `write`
(so `x -> y -> z` hears `x` and writes `y -> z`; there is no escaping). A line starting with
`#` is a comment, except `# off: <entry>` (case-insensitive `off:`), which is a **disabled**
entry. Blank lines are ignored; each side is trimmed; a correction with an empty side is
ignored. `serialize` writes a fixed comment header explaining the format, then one line per
entry in order, disabled entries as `# off: …`. Round-tripping is **semantic**: entries
survive parse → serialize → parse with kind, write, hear and enabled intact; ordinary
comments are discarded by design; ids are not persisted.

**Corrector semantics** (the vectors in `Tests/SottoDictionaryTests/vectors.json` are the
oracle; they are authored by the orchestrator, not the implementer):

- Only enabled `.correction` entries participate. Terms never match anything.
- **NFC-normalise** the input text and every trigger before matching. macOS returns
  decomposed strings from several APIs; an accented trigger otherwise silently never fires.
  The returned text is the NFC form.
- A trigger is split into parts on spaces, tabs and hyphens; each part is regex-escaped;
  parts are joined with `[\s\-]*` (zero or more whitespace or hyphens), so `cloud code`
  also matches `CloudCode`, `cloud-code`, and `cloud\ncode`. Matching is case-insensitive.
- **Fences**: the character before the match must not be a letter, digit, combining mark,
  or hyphen; the character after the match must not be a letter, digit, combining mark, or
  hyphen. Apostrophes (`'` and `’`) **are** boundaries, so possessives get corrected.
  Consequently a `cloud` rule fires in `jon's cloud` and `(cloud)` but not in
  `cloud-native`, `cloudflare`, or `icloud`.
- **Single pass, leftmost, longest.** Scan the original text from left to right; at each
  position the enabled trigger that matches the longest span wins; ties (identical
  triggers) go to the earlier entry in the list. The matched span is replaced by the
  entry's `write` verbatim (its casing is never adapted to the input) and scanning resumes
  after the span. **Replacement text is never re-matched**, so `foo -> bar` plus
  `bar -> baz` turns `foo` into `bar`, not `baz`.
- **Already-correct `write` text is not duplicated.** If the text at a winning match's start
  already reads as that entry's `write` (case-insensitive, NFC-normalised) past the end of
  the trigger's own match, and that occurrence is fenced the same way a trigger is, the match
  replaces that whole existing span (so its casing is fixed, and it is reported like any
  other fire, `from` being the existing span) and scanning resumes after it — so
  `next -> Next.js` does not turn "Next.js" into "Next.js.js", and nothing re-matches
  inside the replaced span. A same-length occurrence (e.g. `codex -> Codex` matching "codex")
  is unaffected and still recases normally.
- `applied` contains one `AppliedCorrection` per entry that fired, **ordered by the
  position of that entry's first match**, with `from` = the exact substring matched by that
  first match (original casing and spacing), `to` = `write`, `count` = how many times the
  entry fired.

`biasPhrases`: the `write` side of every enabled entry (terms and corrections), trimmed,
skipping empties, de-duplicated case-insensitively keeping the first occurrence, in entry
order, capped at `biasLimit` (100). Distinct write targets fill this budget (corrections
sharing a target cost one slot; the correction pass itself is uncapped), so a real
per-project vocabulary fits without silently dropping terms. Still bounded on purpose: an
unbounded context list makes speech models drift and invent primed words on quiet audio,
which is worse than the misspelling it was meant to fix.

`DictionaryWarning.check` (only corrections can misfire; terms return `[]`). Exact
messages, so the UI and tests agree:

- Trigger (trimmed) has four or fewer characters and contains no space or hyphen:
  `"“<trigger>” is very short and will match often. Consider a longer phrase."`
- `write` equals `hear` after trimming, case-insensitively:
  `"This rewrites “<trigger>” to itself, so it will never change anything."`

Never blocks. No common-word heuristic in v1.

Tests (`Tests/SottoDictionaryTests/`): a `VectorTests` suite that loads `vectors.json`
(schema: `[{ "name", "entries": [{ "kind": "term"|"correction", "write", "hear"?,
"enabled"? }], "input", "expected", "applied": [{ "from", "to", "count" }] }]`) and asserts
`expected` and `applied` (including order) for every vector, reporting the vector's `name`
on failure; `DictionaryFile` tests for parse of terms, corrections, comments, `# off:`,
blank lines, first-arrow rule, empty-side rejection, and a semantic round-trip; bias tests
for order, case-insensitive de-duplication, the cap, and disabled/empty exclusion; warning
tests for each message and for a term returning none. The vector file is complete before
implementation starts; do not edit it (report if you believe a vector is wrong).

### 6.12 Dictionary store — `Dictionary/DictionaryStore.swift`

```swift
@MainActor @Observable final class DictionaryStore {
    static let shared: DictionaryStore
    static var fileURL: URL                      // App Support/Sotto/dictionary.txt
    private(set) var entries: [DictionaryEntry]
    private(set) var revision: Int               // bumps on every change to `entries`
    func add(_ entry: DictionaryEntry)
    func update(_ entry: DictionaryEntry)        // matched by id; unknown id → logged no-op
    func delete(id: UUID)                        // unknown id → logged no-op
    func delete(ids: Set<UUID>)
    func reloadFromDisk()                        // see below
    func filtered(by query: String) -> [DictionaryEntry]   // localizedStandardContains on both sides
    var corrector: DictionaryCorrector           // rebuilt on demand; cheap
    var biasPhrases: [String]
}
```

Loads on init. Saves atomically after every edit via `DictionaryFile.serialize`; **a failed
save is logged at error level** (it means the UI shows an entry that will be gone on
relaunch). There is **no live file watcher** in v1: dispatch-source events arrive after
the save that caused them, so a store cannot reliably tell its own atomic write from an
external edit. Instead, `reloadFromDisk()` reads the file, and is called on
`NSApplication.didBecomeActiveNotification`, from a "Reload Dictionary" menu item, and (as
built) from `AppComposition`'s engine factory on every press: hotkey dictation never brings
Sotto frontmost, so without this a hand edit to `dictionary.txt` would only reach a hold
started some other way. A reload skips work when the file's modification date and size
match the last load or save, so the per-press call costs a stat when nothing changed.
When entries are re-parsed, **existing ids are preserved** for entries whose `(kind, hear,
write)` triple matches an entry already in memory (first match wins); new lines get fresh
ids. `revision` bumps only if the entry list actually changed.

### 6.13 History — `History/`

```swift
struct DictationRun: Codable, Sendable, Identifiable {
    var id: UUID                   // decoded leniently: missing → fresh UUID, persisted on next rewrite
    let date: Date                 // releasedAt
    let engine: String
    let source: String             // "hotkey" | "button"
    let audioSeconds: Double       // key held
    let processSeconds: Double     // release → text ready
    let text: String
    var corrections: [AppliedCorrection]?
}

@MainActor enum HistoryLog {      // App Support/Sotto/history.jsonl
    static func record(_ run: DictationRun)
    static func load() -> [DictationRun]
    static func delete(ids: Set<UUID>)
    static func clear()
}

@MainActor @Observable final class HistoryStore {   // the UI's view of the log
    static let shared: HistoryStore
    private(set) var runs: [DictationRun]
    func prepend(_ run: DictationRun)
    func reload()
}
```

Append one JSON line per run (ISO-8601 dates). `load` skips undecodable lines but logs how
many were skipped, and writes freshly minted ids back to the file during that load (as built:
`delete(ids:)` re-reads the file, so a lazily minted id could never match). `delete`/`clear`
rewrite the whole file atomically. Every write failure is logged. A successful `record`
resolves `HistoryStore.shared` before appending and then prepends the known run to
`HistoryStore` in memory, with no read; an append failure reloads instead, so the store
still reflects the file's actual contents. `delete` and `clear` rewrite the file atomically
and then replace the store from the known file order (or reload, on a failed rewrite).
`HistoryStore.runs` are newest first (as built). There is no HTML dashboard. Both stores
share `Support/AppSupportDirectory.swift` for the directory (as built).

### 6.14 UI

**Design direction: "quiet instrument".** Sotto is a tool you glance at, not a toy. Matte
surfaces, one accent, generous whitespace, tabular numerals for timings. In light
appearance: warm off-white panels on a slightly darker ground with ink-black text. In dark
appearance: near-black panels on true black with off-white text. Two rules that are not
negotiable: **the accent (a muted coral red) means "recording" and is used for nothing
else**, and **level meters use a restrained green-to-amber scale that appears nowhere else
in the chrome**. No gradients, no glow, no blur-heavy glass except the HUD's material
background, no decorative skeuomorphism. Depth comes from flat fills and hairline borders.

`UI/DesignSystem.swift` defines every token under `enum DS`: `Color` (ground, panel,
panelRaised, ink, inkSecondary, inkTertiary, hairline, accent, meterLow, meterHigh,
selection), `Space` (hair 2, tight 4, snug 8, base 12, roomy 16, wide 24, panel 32),
`Radius` (control 6, panel 10, hud 22), `Font` (title, body, label, caption, readout —
readout uses monospaced digits), `Border` (hairline 1), `Motion` (quick 0.12 s, panel
0.2 s, hud 0.16 s), and `Metric` (hudWidth 340, hudHeight 76, hudBottomOffset 96,
hudBarCount 12, hudBarFloor 3, hudBarWidth 3, hudBarSpacing 3, meterBarCount 12,
windowDefaultWidth 860, windowDefaultHeight 620, windowMinWidth 720, windowMinHeight 520,
copiedFeedbackSeconds 1.4). **Views must not contain literal colours, sizes, radii, fonts
or durations.** If a component needs a value that is not a token, **add the token**: later
batches may append to `DesignSystem.swift` (never rename or remove existing tokens).
Colours adapt to light/dark via `Color(nsColor: NSColor(name:dynamicProvider:))`; verify
both appearances. `UI/TokenSheet.swift` is a single SwiftUI view that lays out every
colour, font and spacing token with its name, for visual checks.

**HUD** — `UI/HUDPanel.swift`, `UI/HUDView.swift`. An `NSPanel` with
`[.borderless, .nonactivatingPanel]`, `isFloatingPanel`, level `.statusBar`,
`collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
`hidesOnDeactivate = false`, `ignoresMouseEvents = true`, transparent background, **and
`canBecomeKey` / `canBecomeMain` overridden to `false`** (invariant 1). Sized from
`DS.Metric`, positioned bottom-centre of the screen with the key window (fall back to the
first screen), `hudBottomOffset` above the visible frame's bottom. `present()` fades in over
`DS.Motion.hud` and is a no-op when already fully visible (state changes mid-utterance must
not flicker); `dismiss()` fades out and orders out on completion. Shown whenever
`controller.state.showsHUD` is true (so errors are visible for their display duration).
Content: a `hudBarCount`-bar level meter (each bar with a fixed phase offset so the group
ripples rather than pumps; bars rest at `hudBarFloor` when inactive; animation phase lives
in a plain reference type the view holds, never in `@State` mutated from a draw closure)
and the live transcript, two lines, head-truncated, or "Preparing…" while `.starting`,
"Listening…" while `.listening` with an empty transcript, "Transcribing…" while
`.finishing` with an empty transcript, or the error message in the accent colour. Hosted
with `NSHostingView`.

**Main window** — `UI/MainWindow.swift`, single `Window` scene (not a `WindowGroup`),
default and minimum sizes from `DS.Metric`. Top: a transport strip with Record/Stop
(`startButtonRecording` / `stopButtonRecording`), a recording lamp in the accent colour, a
live level meter, and an elapsed counter in readout digits driven by
`controller.holdStartedAt`. A caption under the transport says "Recordings started here are
saved to History, not typed." Below: a two-tab area, **History** and **Dictionary**.
History (`UI/HistoryPanel.swift`): search field, newest first, each row showing engine,
source ("typed" / "recorded"), process time, time of day, the text (selectable), correction
badges when any fired (strikethrough "heard" → "written" ×count), a Copy button with a
`copiedFeedbackSeconds` "Copied" state, and a hover-only delete without confirmation; a
footer with the count and a "Delete all" that confirms. Dictionary
(`UI/DictionaryPanel.swift`): search, an add row with a kind toggle (term / correction),
inline edit, enable toggle, delete, and the `DictionaryWarning` messages shown inline when
adding. File menu: "Reveal Dictionary File" and "Reload Dictionary".

**Settings** — `UI/SettingsWindow.swift`, the standard `Settings` scene (⌘,). Sections:
Push to talk (segmented choice of the three keys; changing it calls
`controller.reloadHotkey()`), Cleanup (toggle; when on, a Smart cleanup toggle disabled with
the `unavailableReason` shown when the Foundation Model is unavailable), Sound (toggle), and
a Permissions section showing Accessibility and Microphone status with "Open System
Settings" buttons when either is missing. Fully qualify `SwiftUI.Settings` because the app
has its own `Settings` type.

**Menu bar** — `UI/MenuBarContent.swift`: icon `waveform` / `waveform.circle.fill` when
active; "Hold ⟨key⟩ to dictate"; Open Sotto; Settings…; Grant Accessibility… / Grant
Microphone… when missing; Quit.

### 6.15 App lifecycle — `App/SottoApp.swift`, `App/AppComposition.swift`

```swift
/// The composition root. Exactly one instance for the life of the process, owned by the
/// AppDelegate; every scene reaches it through the delegate adaptor.
@MainActor final class AppComposition {
    let controller: DictationController
    let pipeline: UtterancePipeline
    // as built: the HUD is held by AppDelegate, not here
    init()                        // wires real dependencies and sets controller.onFinalTranscript = pipeline.process
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let composition = AppComposition()
}
```

Scenes access `delegate.composition.controller` via `@NSApplicationDelegateAdaptor`.
`AppDelegate.applicationDidFinishLaunching`: activation policy `.regular`; create the HUD
and store it on the composition; `Task { await AppleSpeechEngine.prepare() }`;
`controller.activate()`; if that fails, show the Accessibility prompt and **poll once a
second until trusted, then activate** (there is no notification for the grant); observe
`controller.state` with `withObservationTracking` (re-registering on each change) to
present or dismiss the HUD according to `showsHUD`; observe
app activation (as built: the `applicationDidBecomeActive` delegate method) to call
`DictionaryStore.shared.reloadFromDisk()`.
`applicationWillTerminate` calls `controller.deactivate()`.

Batch A1 creates `AppComposition` with the controller wired to real dependencies and
`onFinalTranscript` set to a closure that logs the transcript length; B1 replaces that
closure with the pipeline; B2 adds the HUD; C1 adds the scenes.

## 7. Build, signing, permissions

`make build` / `make test` / `make app` / `make run` / `make install` / `make clean`, see the
Makefile. Build products and the staged bundle live in `~/Library/Caches/SottoBuild`, never
in the repo; a linked worktree gets its own stage under `worktrees/<name>` there. The bundle
is signed with the first Developer ID Application identity found, with `--options runtime`
and the entitlements file; `make app` fails rather than falling back to ad-hoc, because an
ad-hoc signature changes on every build. Two grants are needed and neither can be requested
silently: Accessibility (event tap and AX insert) and Microphone (prompted on first
dictation). Because TCC keys grants to the code signature, Developer ID signing is what
makes a grant survive a rebuild. TCC and LaunchServices key on the bundle id, so only the
canonical stage may be launched or installed: `make run` and `make install` refuse to work
from a worktree or an overridden `STAGE`, and `make install` unregisters the staged copy so
the installed app is the only registered one. While the grant is missing, every launch of
any copy shows the Accessibility prompt. If a grant wedges, reset that one row, always
passing the bundle id (a bare `tccutil reset Accessibility` wipes every app):
`tccutil reset Accessibility com.conn3h.sotto`, then quit System Settings fully.

## 8. Testing and acceptance

- Library targets and the app test target: Swift Testing, tests written before
  implementation, `make test` green.
- Runtime acceptance is by running the app and reading
  `/usr/bin/log show --predicate 'subsystem == "com.conn3h.sotto"' --info --last 5m`
  (spell out `/usr/bin/log`; `log` is often shadowed in shells).

Milestone acceptance:

| Milestone | Done when |
|---|---|
| A1 core loop | Every controller test in §6.7 passes. Running the app: hold the key, speak, release, and the log shows `listening for Right ⌥`, capture start with sample rates, analyzer start, capture stop, and `final transcript: N chars`. Holding Left Option while tapping Right Option still logs a release. A tap shorter than engine start-up logs no error and leaves `liveTaskCount` at zero (log it after every utterance). Quitting during a hold does not crash. |
| A2 SottoText | `make test` passes every table row, rule case and guard case in §6.9. |
| A3 SottoDictionary | `make test` passes every vector in `vectors.json` and every file, bias and warning test in §6.11. |
| A4 design tokens | `DS` compiles with every token named in §6.14, colours resolve in both appearances, and `TokenSheet` renders them. |
| B1 pipeline | Every formatter test in §6.10 passes. Running the app: dictating into TextEdit uses the AX path; dictating into Terminal uses paste and the clipboard is restored; copying something else during the 500 ms window is not clobbered (log shows the skip); the run appears in `history.jsonl`; a dictionary correction fires and is recorded; a Record-button utterance is saved with source `button` and nothing is typed. |
| B2 HUD | The HUD appears bottom-centre on press without the target field losing focus (dictation still lands), shows "Preparing…" then live text, stays visible through starting → listening → finishing without flicker, shows an error for its display duration, and disappears on idle. |
| C1 app shell | Main window, Settings, Dictionary and History panels work end to end with no literal values in views; both appearances checked; "Reload Dictionary" picks up a hand edit. |
| V verification | Independent review confirms §4 invariants, §6.1 logging rules, no `try?` without a log, `MainActor.assumeIsolated` only in the tap callback, no shared mutable state in `AudioCapture`, and the design rules in §6.14. |

## 9. Milestones and ownership

Batches run in order; agents within a batch run in parallel and own disjoint files.

| Batch | Agent | Owns (creates or edits) | Depends on |
|---|---|---|---|
| A | A1 core loop | `Support/Settings.swift`, `Support/Permissions.swift`, `Core/HotkeyMonitor.swift`, `Core/AudioCapture.swift`, `Core/DictationController.swift`, `Speech/*`, `App/SottoApp.swift` (AppDelegate: activate, retry poll, prepare), `App/AppComposition.swift` (initial: logging `onFinalTranscript`), `Tests/SottoAppTests/Fakes.swift`, `Tests/SottoAppTests/DictationControllerTests.swift` | scaffold |
| A | A2 text | `Sources/SottoText/*`, `Tests/SottoTextTests/*` | scaffold |
| A | A3 dictionary | `Sources/SottoDictionary/*`, `Tests/SottoDictionaryTests/*` except `vectors.json` | scaffold + vectors |
| A | A4 tokens | `UI/DesignSystem.swift`, `UI/TokenSheet.swift` | scaffold |
| B | B1 pipeline | `Core/UtterancePipeline.swift`, `Core/TextInjector.swift`, `Cleanup/*`, `Dictionary/DictionaryStore.swift`, `History/*`, `App/AppComposition.swift`, `Tests/SottoAppTests/FoundationModelFormatterTests.swift` | A1–A3 |
| B | B2 HUD | `UI/HUDPanel.swift`, `UI/HUDView.swift`, `App/SottoApp.swift` (HUD create/present/dismiss only), tokens appended to `UI/DesignSystem.swift` if needed | A1, A4 |
| C | C1 shell | `UI/MainWindow.swift`, `UI/HistoryPanel.swift`, `UI/DictionaryPanel.swift`, `UI/SettingsWindow.swift`, `UI/MenuBarContent.swift`, `UI/Components.swift`, `App/SottoApp.swift` (scenes, menu commands, reload-on-activate), tokens appended if needed | B1, B2 |
| V | verifier | read-only review + `make test` + `make app` | C1 |

Agents do not commit; the orchestrator commits after each batch. Agents must not edit
`Package.swift`, the Makefile, `vectors.json`, or files owned by another agent in the same
batch.

## 10. Traps checklist

Things that look wrong and are not, or look fine and will bite:

- Ad-hoc signatures reset TCC grants on every build (§7). Sign with a Developer ID.
- The public `.maskAlternate` cannot tell Right Option from Left Option (§6.4).
- Apple's analyzer kills the process on the wrong sample format; it does not throw (§4.4).
- Results already published by the transcriber can still be pending after the analyzer
  finishes; await the drain task before reading the committed text (§6.6).
- A setup task suspended at an `await` can resume after the utterance ended; generation
  checks after every suspension, and cancel-and-await from the terminal task (§6.7).
- An AX write can return success and do nothing, or a field can change on its own for an
  unrelated reason; verify by a caret or length change matching the write's size, polled for
  up to 150 ms rather than checked once (§6.8).
- `AVAudioEngine` recycles tap buffers on return; copy them (§4.3).
- `MainActor.assumeIsolated` asserts, it does not check. One permitted site (§6.4).
- Never make the HUD key (§4.1).
- Spawning a task per audio buffer silently reorders audio (§4.2).
- A structured task group waits for all children, so it cannot enforce a timeout against
  a stalled child; use an unstructured task and abandon it (§6.10).
- Unified log redacts interpolations without `privacy: .public` (§6.1).
- `log` is shadowed in some shells; use `/usr/bin/log`.
- Mutating `@State` inside a `Canvas` or `TimelineView` draw closure floods the log; keep
  animation physics in a plain reference type the view holds.
- Never build inside an iCloud-synced folder; the Makefile's scratch path exists for this.

## 11. Later

Parakeet via CoreML as a second engine (the seam exists), command mode on selected text,
first-run onboarding, notarization and a DMG, an app icon, live dictionary file watching
done properly (content fingerprints, debounce), a common-word warning list for the
dictionary, per-app injection preferences.
