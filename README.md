# MyWords

A personal, on-device keystroke logger for macOS. It records the text **you**
type and which app you typed it in, stores everything in a **fully encrypted**
local database, and lets you export the data to train your own AI model.

> ⚠️ **Use it only on your own Mac, for your own typing.** Running a keylogger
> on a machine you don't own, or capturing someone else's keystrokes without
> their consent, is illegal in most places. macOS enforces consent for you: the
> app captures nothing until *you* grant it Accessibility permission.

## What it does

- **Captures typed text** via a listen-only `CGEventTap` — it observes keystrokes
  but never modifies or delays them.
- **Tags each segment with the foreground app** (name + bundle id).
- **Skips passwords.** While a secure text field is focused, macOS turns on
  "secure event input" and the app drops everything typed during that window.
  Keyboard shortcuts (⌘/⌃ chords) are ignored too — they aren't "typed text".
  For fields that *don't* trigger secure input (browsers, Electron apps), a
  user-editable **redaction list** scrubs matches before they're stored — see
  [Redacting secrets](#redacting-secrets).
- **Ignores itself.** Keystrokes typed while MyWords is frontmost (its own
  passphrase / redaction dialogs) are never recorded.
- **Encrypts the whole database** with **SQLCipher** (AES-256). The *entire*
  file is encrypted at rest — text *and* metadata (timestamps, app names) — so
  nothing readable ever hits disk. It's unlocked with a passphrase stored in
  your **Keychain**, never in a file.
- **Segments by idle time** — a burst of typing in one app stays in a single
  row and is closed after ~3 seconds of silence (or an app switch).
- **Runs as a menu-bar app** (no Dock icon), starts at login, pause/resume any
  time.

## What it's for

MyWords is the **capture layer** — a private, searchable record of everything
*you* write. What you build on it is up to you. Some reasons people want that:

- **A personal LLM context / "second brain."** Feed your own writing to a model
  so it knows your projects, style, and vocabulary — without shipping your life
  to a cloud service.
- **Never lose what you typed.** A crashed form, a chat message that didn't
  send, a commit message you rewrote — recoverable from an encrypted local
  history that spans every app.
- **Writing & language self-improvement.** Track vocabulary, tone, and recurring
  mistakes over time. The [`examples/`](examples/) coach turns that into daily
  feedback (the author uses it to practice English, Portuguese, and German).
- **Quantified self.** Words per day, which apps you actually write in, when
  you're most productive — your own analytics, computed locally.
- **Private training data.** Build a corpus of *how you write* to fine-tune or
  personalize your own models — kept on your machine and encrypted at rest.
- **A searchable journal of your thinking.** Reconstruct what you worked on or
  worked out on a given day, in your own words.

The common thread: **your data, on your device, encrypted, under your control**
— never a cloud account. And the boundary, plainly: it's for *your own* typing
on *your own* Mac, never for monitoring someone else.

## Install (build from source)

**There is no download — and that's the point.** MyWords is a keystroke logger,
so the trust model is *see exactly what you're running*: read the source, or
have a tool or an LLM you trust review it for you, and then compile it yourself.
There's no prebuilt or notarized binary to take on faith (or for antivirus to
flag) — you build the exact code you (or your reviewer) audited. It's a small
codebase and a short build.

### 1. Prerequisites

- **macOS 13 or later.**
- **Xcode command-line tools** (`xcode-select --install`) — provides Swift 6.
- **SQLCipher via [Homebrew](https://brew.sh):**
  ```bash
  brew install sqlcipher
  ```
  This is a **build-time** dependency only. `build.sh` links against
  `/opt/homebrew/opt/sqlcipher` (Apple Silicon; on Intel, edit
  `sqlcipherPrefix` in `Package.swift` to your `/usr/local` prefix) and
  **bundles a copy of the libraries inside the app**, so the finished
  `MyWords.app` is self-contained and keeps working even if you later uninstall
  sqlcipher.

### 2. Build & install

```bash
git clone <your-fork-url> MyWords && cd MyWords
./build.sh install      # compiles, assembles a signed self-contained app,
                        # and copies it to ~/Applications
open ~/Applications/MyWords.app
```

`./build.sh` alone just produces `build/MyWords.app` (plus the `mywords-export`
CLI) without installing.

### 3. Grant Accessibility & start

On first launch macOS prompts for **Accessibility** permission
(System Settings ▸ Privacy & Security ▸ Accessibility). Grant it — nothing is
captured until you do. The menu-bar keyboard icon then shows status (filled =
recording). Your encrypted database is created at:

```
~/Library/Application Support/MyWords/keystrokes.db
```

### Signing note

`build.sh` auto-detects a code-signing identity:

- **With a Developer ID / Apple Development certificate**, it signs stably, so
  the Accessibility grant (and Keychain access) **survive rebuilds**. Override
  the chosen identity with `MYWORDS_SIGN_ID="…" ./build.sh`.
- **Without any certificate**, it falls back to **ad-hoc signing**. The app
  still runs, but its signature changes every build, so macOS will ask you to
  re-grant Accessibility after each rebuild. Fine for occasional builds; get a
  free Apple Development certificate (via Xcode ▸ Settings ▸ Accounts) if that
  annoys you.

## Reviewing your data

Because the whole database is SQLCipher-encrypted, you review it in one of two
ways — **neither writes plaintext to disk unless you explicitly export**.

**1. Open it directly in a SQLCipher-capable GUI** (recommended). Use
**DB Browser for SQLCipher**: open `keystrokes.db`, choose "SQLCipher 4
defaults", and paste the passphrase. Find the passphrase in **Keychain
Access** under service `com.mywords.logger`, account `db-passphrase`. It
decrypts pages into memory only — no plaintext file is created. (The plain
`sqlite3` CLI can't open it; use the `sqlcipher` CLI or a GUI.)

**2. Query it from the terminal** with the `mywords-sql` helper. It reads the
passphrase from the Keychain, sets the SQLCipher key, and drops you into a query
(results print to the terminal only — no plaintext file):

```bash
./mywords-sql "SELECT app_name, count(*) FROM keystrokes GROUP BY app_name ORDER BY 2 DESC"
./mywords-sql "SELECT datetime(ts,'unixepoch','localtime'), text FROM keystrokes WHERE app_name='Claude'"
./mywords-sql                      # interactive SQLCipher shell
```

Under the hood it uses the `sqlcipher` CLI (the plain `sqlite3` CLI cannot open
an encrypted database). Columns: `id, ts, app_name, app_bundle, text`.

**3. Export a plaintext copy for training.** `mywords-export` unlocks the
database with the Keychain passphrase and writes it out:

```bash
build/mywords-export --out corpus.jsonl                 # JSON Lines (default)
build/mywords-export --format text --readable           # to stdout, tokens shown
build/mywords-export --format csv  --out corpus.csv
```

`--readable` renders control keys as `<RET>`/`<TAB>`/`<DEL>`/`<ESC>`. Exports
are **plaintext** — treat them as sensitive and delete when done (`corpus.*` and
`*.jsonl` are git-ignored).

## Redacting secrets

macOS's secure-input detection catches many password fields, but not all —
browsers, Electron apps, and terminal prompts often don't trigger it. For those,
keep a **redaction list** so secrets are scrubbed *before* they're written to
the database.

The patterns are stored **inside the encrypted database** (not a plaintext
file), so they're protected like everything else. Manage them from the menu:

- **Add Redaction Pattern…** — case-insensitive; a plain word matches literally,
  or use a regex. Matches become `[REDACTED]` before storage.
- **Clear Redaction Patterns** — removes all patterns.
- **Apply Redaction to Existing Log** — scrubs matches from data captured
  *before* the pattern was added.

Example patterns: `myS3cretPassw0rd`, `\b\d{6}\b` (6-digit OTP),
`sk-[A-Za-z0-9]{20,}` (API keys). You can also manage them with SQL via
`mywords-sql` (table `redaction_patterns`).

> Prefer regex patterns over pasting real passwords where you can — a shape like
> `\b\d{6}\b` catches secrets without you writing the secret down anywhere.

## Choosing which apps to log

The menu's **Apps** submenu controls capture per application:

- **Record all apps (except blocked)** — the default. Everything is captured;
  click an app to toggle its checkmark off and it's blocked. Good for a broad
  personal corpus while excluding a few sensitive apps.
- **Record only allowed apps** — flip this on to switch to a strict allowlist;
  then only apps you check are recorded.
- **Ask before recording new apps** — when on, the first time you switch to a
  never-seen app it's blocked and you get a notification to Record or ignore it.
  When off, new apps are recorded automatically.

The list shows every app you've switched to (MyWords watches app activations,
not just typing), plus any you've already ruled. Rules live in the encrypted
database (bundle id + allow/deny) and apply live. MyWords never records itself.

## Project

- **License:** [GNU AGPL v3](LICENSE) — © 2026 Guilherme Prokisch. Strong
  copyleft: any distributed *or network-hosted* derivative must publish its
  source. Fitting for a privacy tool — a modified keylogger can't be shipped or
  offered as a service while staying closed.
- **Security & threat model:** [SECURITY.md](SECURITY.md) — what it protects
  against and, just as importantly, what it doesn't.
- **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md).
- **Examples:** optional glue (language coaching, automations, study-app
  integration) lives in [`examples/`](examples/) — none of it is core, and it
  only sends data off-device when *you* wire it up.

### Legal & ethics

MyWords is a keystroke logger. Run it **only on a machine you own, to record
your own typing.** Capturing anyone else's keystrokes without their knowledge is
illegal in most jurisdictions — you are responsible for lawful use. The software
is provided **as is, without warranty** (see [LICENSE](LICENSE)).

## Project layout

| Path | Purpose |
|------|---------|
| `Sources/CSQLCipher/`     | Module map binding Homebrew's SQLCipher |
| `Sources/MyWordsCore/`    | Data layer: `Database` (SQLCipher), `KeyManager`, `Migration`, `Crypto` (legacy) |
| `Sources/MyWords/`        | Menu-bar app: `Recorder` (event tap), `AppDelegate`, UI |
| `Sources/mywords-export/` | CLI to decrypt & export the corpus |
| `Tests/MyWordsCoreTests/` | Storage, wrong-passphrase, and at-rest-encryption tests |

## Notes & limits

- **Losing the passphrase = losing the data.** It lives in the login Keychain
  (`com.mywords.logger` / `db-passphrase`). Don't delete it. The data isn't
  portable to another Mac unless you export it or copy the passphrase.
- **Migration.** On first run of the SQLCipher version, any old
  `keystrokes.sqlite` (the previous per-field-encrypted format) is imported and
  renamed to `keystrokes.sqlite.pre-sqlcipher-bak`. Delete that backup once
  you've confirmed your data is present — it still holds plaintext metadata.
- **Signing.** `build.sh` auto-selects a stable Developer ID / Apple Development
  identity so the Accessibility grant survives rebuilds. Override with
  `MYWORDS_SIGN_ID`.
- **Control characters** are captured raw (Return/Tab/Backspace); normalize in
  preprocessing if your model doesn't want them.
