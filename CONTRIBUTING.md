# Contributing to MyWords

Thanks for your interest. MyWords is a small, local-first, **auditable**
keystroke logger — contributions that keep it simple, private, and easy to read
are very welcome.

## Ground rules

- **Privacy first.** Never add anything that transmits captured data off-device
  without an explicit, opt-in user action. The default must always be
  local-only.
- **No hidden capture.** Recording must remain visible (menu-bar indicator) and
  pausable, and MyWords must never record itself or bypass the app allow/deny
  rules and redaction.
- **Keep it legible.** This is a security tool people are trusted to read.
  Prefer clear, boring code over cleverness; comment the *why*.

## Development

Requirements: macOS, Xcode toolchain, and SQLCipher via Homebrew
(`brew install sqlcipher`).

```sh
swift build            # compile
swift test             # run the test suite (storage, encryption, redaction, rules)
./build.sh             # assemble a signed, self-contained MyWords.app in build/
./build.sh install     # also copy it to ~/Applications
```

Signing auto-detects a Developer ID / Apple Development identity; override with
`MYWORDS_SIGN_ID`. See the README for the architecture and layout.

## Pull requests

- Add or update tests for behavior changes (see `Tests/`).
- Run `swift test` and make sure `./build.sh` produces a launchable app.
- Keep PRs focused; describe the user-visible effect and any security
  implications.
- By contributing you agree your work is licensed under the project's
  [GNU AGPL v3](LICENSE).

## Good first areas

- Broader default redaction (entropy-based secret detection).
- A first-run onboarding / permission flow.
- A settings window (so the CLI tools become optional).
- Tests for edge cases (IME/dictation, non-Latin input).
