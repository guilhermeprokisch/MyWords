# Security & threat model

MyWords is a keystroke logger. It is designed to record **your own typing on
your own Mac**, store it **encrypted at rest**, and keep it **local**. This
document states plainly what that does and does not protect against.

## What MyWords does

- Captures keystrokes via a listen-only `CGEventTap`. macOS requires you to
  grant **Accessibility** permission first — nothing is captured until you do.
- Stores everything in a **SQLCipher (AES-256) encrypted database**. The whole
  file is encrypted, including timestamps and app names.
- Holds the database passphrase in the **macOS Keychain** (never in a file).
- Skips password fields (macOS secure-event-input), lets you **redact**
  patterns before they're stored, and lets you **choose which apps** are
  recorded. It never records itself.

## What it protects against

- **Casual disk access.** Someone copying `keystrokes.db` cannot read it without
  the Keychain passphrase. Metadata is encrypted too.
- **Accidental plaintext on disk.** The live database is never written in the
  clear. (Explicit exports *are* plaintext — see below.)

## What it does NOT protect against

- **An attacker with your unlocked user session.** Anyone who can run code as
  your logged-in user can read the Keychain passphrase and decrypt the data,
  exactly as your own tools do. MyWords is not a defense against local malware
  or someone at your unlocked machine.
- **Exports.** `mywords-export` writes **plaintext** files by design (for
  training). Treat them as sensitive and delete them when done.
- **Anything sent to an LLM.** Optional coaching/analysis (see `examples/`)
  sends text off-device to whatever service you configure. That is your choice
  and leaves the local trust boundary.
- **Physical/OS-level compromise, screen capture, or other input methods**
  (dictation, paste, on-screen keyboards may not be captured or protected).

## Explicitly out of scope / your responsibility

- **Consent & legality.** Run MyWords **only on a machine you own, to record
  your own typing.** Capturing someone else's keystrokes without their
  knowledge is illegal in most jurisdictions. You are responsible for lawful
  use.
- **Losing the passphrase** (Keychain item `com.mywords.logger` /
  `db-passphrase`) means the data is unrecoverable. That's intended.

## Reporting a vulnerability

Please report security issues privately by opening a
[GitHub security advisory](https://docs.github.com/en/code-security/security-advisories)
on the repository, or by contacting the maintainer, rather than filing a public
issue. Include steps to reproduce and the impact. We aim to acknowledge reports
within a few days.
