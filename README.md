# Mulligan

*(formerly Sotto)*

> **mulligan** *(noun, golf)* — a free second shot, taken as if the first never happened.

Hold a key, talk, let go: Mulligan writes it where you were typing. Said it wrong? Tap one more
key while you are still holding, and it takes the text back so you can say it again.

![Mulligan: hold a key, talk, release, and the text lands in the Claude Code prompt](docs/media/demo.gif)

Push-to-talk dictation for macOS. Hold a key, talk, release, and cleaned-up text lands in
whatever text field has focus: a terminal, an editor, a chat box, a prompt for a coding
agent. Everything runs on your Mac: Apple's on-device speech engine (or NVIDIA Parakeet as
an experimental second engine), optional on-device cleanup with Apple's Foundation Model, a
personal dictionary for the names and jargon speech models get wrong, and local history.
No accounts, no network, no subscription.

Built for talking to Claude Code, Codex and the like all day without typing, but it works in
any app that takes text. If you have used Wispr Flow or Superwhisper, Mulligan is the same
hold-to-talk idea, but open source, fully on-device and free.

Requires macOS 26.

## Install

Download the latest `Mulligan-x.y.z.zip` (releases before 0.2.1 are called Sotto) from [Releases](https://github.com/Conn3h/mulligan/releases),
unzip it and drag `Mulligan.app` to Applications. The build is signed and notarised, so it opens
without warnings.

Or build it yourself (needs Xcode 26):

```bash
make install     # builds, signs, installs to /Applications, launches
```

Then grant two permissions, neither of which can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| Accessibility | System Settings > Privacy & Security > Accessibility | Seeing the push-to-talk key and inserting text |
| Microphone | Prompted on first dictation | Audio capture |

Mulligan notices the Accessibility grant on its own; no restart needed. Then hold
**Right Option** and talk.

Said it wrong? Keep holding **Right Option** and tap **Right Command**: Mulligan removes what it
just typed and listens again, so you simply say it again. It only erases text it can show is
still its own, and tells you why when it refuses. Both keys can be changed in Settings.

Other targets: `make test`, `make app`, `make run`, `make clean`.

## Building from source

`make app` signs the bundle with a Developer ID Application identity from your keychain and
refuses to sign ad-hoc, because an ad-hoc signature changes on every build and macOS resets
the Accessibility grant each time. If you have no Developer ID, `make app SIGN_ID=-`
produces a throwaway build; expect to re-grant Accessibility after each rebuild.

The library targets (`MulliganText`, `MulliganDictionary`) are tested first and `docs/SPEC.md` is
the contract every module is written against. Contributions are welcome; keep to the spec,
or change the spec in the same change. There is no CI; run `make test` locally.

Maintainers cut a release with `make release`: it notarises the signed bundle, tags
`v<version>` from `Resources/Info.plist` and publishes the zip on GitHub. It needs notarytool
credentials stored once under the keychain profile `sotto-notary`. `Tools/demo-gif.sh`
turns a screen recording into the README demo.

## Privacy

Nothing you say or type leaves the Mac. There is no account, no server and no analytics.
macOS itself may download Apple's speech model for your language the first time it is needed.

## Design and status

Built clean-room from a written spec, with the modules implemented independently against it.
See `docs/SPEC.md` for the architecture and module contracts, and `docs/reviews/` for the
external reviews the spec and the code went through.

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) runs the
  experimental Parakeet engine on CoreML.
- [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and
  Parakeet CTC 110M (CC-BY-4.0) are downloaded on first use of that engine; they are not
  part of this repository.
- Apple's Speech and Foundation Models frameworks provide the default engine and cleanup.

## License

MIT. See [LICENSE](LICENSE).
