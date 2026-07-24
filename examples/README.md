# Examples

Optional glue showing what you can *build on top of* MyWords. None of this is
part of the core app — it's reference, and it deliberately sends your text to
places you choose, so treat it as opt-in.

> ⚠️ Everything here reads your decrypted text and sends it somewhere (an LLM, an
> email relay, another app). That leaves the local-only trust boundary. Only use
> it with services you trust, on your own data.

## `mywords-coach`

A shell script that exports your recent text (`mywords-export --days N`),
wraps it in a language-coaching prompt, and pipes it to the `claude` CLI (or
prints the prompt if the CLI isn't installed). Produces a report of phrasing
fixes, vocabulary, and things to practice.

```sh
./examples/mywords-coach --days 7
```

## `mywords-stats`

Language & vocabulary statistics over your log (per-language detection with
Apple's NaturalLanguage framework, vocabulary size, top words, activity, top
apps). It's a language-learning tool, so it lives here rather than in the core.
It's still a package target, just not shipped by `build.sh`:

```sh
swift build -c release --product mywords-stats
.build/release/mywords-stats --days 30
```

## Pattern: a daily automation

You can run something like `mywords-coach` on a schedule and deliver the result
however you like. The building blocks:

1. **Trigger** — a `launchd` agent, `cron`, or your assistant's scheduler runs
   the job daily.
2. **Gather** — `mywords-export --format text --days 1` (plaintext; keep it
   local or pipe it directly, don't leave it lying around).
3. **Analyze** — send it to an LLM of your choice.
4. **Deliver** — email it via your own MTA, post to a chat webhook, or write it
   into a notes app. Substitute your own endpoints; don't hard-code secrets in
   the script (read them from the environment or your keychain).

## Pattern: feed exercises into a study app

MyWords pairs well with a spaced-repetition/notes app. The idea: turn the
coaching output into flashcards and drop them into that app's store. Keep any
app-specific writer (file format, path) in *your* copy — it's personal glue, not
something every user wants. A minimal writer takes `{front, back}` items and
appends them in the target app's note/card format.

The goal of MyWords is to be the **secure, local capture layer**; these examples
are just illustrations of the kind of thing you can layer on top.
