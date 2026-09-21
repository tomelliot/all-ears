# Spec: `cleanup` + `summarize` (LLM stages)

Two separate tools, each one job, built on a shared LLM backend interface.

## Shared LLM backend

- The backend interface is prompt-in → completion-out; prompt construction, chunking, and output writing belong to the tools.
- One implementation exists: a **subprocess backend** that runs a command with the prompt on stdin and reads the completion from stdout, with a timeout. Both config spellings resolve to it: `backend = "llm-cli"` runs `llm -m <model>` (the [`llm` CLI](https://llm.datasette.io) brings model selection, key management, and local-model support for free); `backend = "command"` runs an arbitrary `[llm].command` line, which is also how a local model runs as a sidecar.
- A native SDK backend (streaming, caching, retries) can be added behind the same interface later.
- Logging: request/response metadata only (model, latency, sizes) — never prompt/response bodies above `debug`. Failures are loud and non-zero.
- Long transcripts are chunked with overlap and stitched; parameters are configurable and logged. Prompts keep a stable prefix (system prompt + vocabulary + instructions) ahead of the dynamic transcript so caching backends can reuse it.

## `cleanup`

### One job
Turn a raw transcript into a clean, readable one, correcting mis-transcriptions and formatting with an LLM, guided by the known-word list — and **publish** it: this is the stage that turns a hidden intermediate into the file you open.

### Behaviour
1. Read a `.transcript.md` — a path, or `--session <id>` to resolve the session's stored transcript from the data store.
2. Batch turns into chunks of `[cleanup] chunk_seconds` **spoken** seconds (300 by default), one LLM call each.
3. Build the prompt: the built-in cleanup prompt (or `[cleanup].prompt_file`), plus the merged vocabulary (global + session) as an explicit correction list, plus the chunk's turns rendered one per line behind a `[[n|Speaker]]` marker.
4. Correct homophones/mis-hearings against the vocabulary and fix punctuation/casing, **without** altering meaning, timestamps, or speaker turns.
5. Write the result atomically to wherever `[cleanup] output`'s path template resolves to — by default `{output_root}/{year}/{month}/{day}/{date} - {title}.md` — with frontmatter `kind: clean` and `derived_from` naming the source transcript. Only the Markdown publishes; the cleaned JSON sidecar stays in the data store beside the input transcript (`transcript.md` → `transcript.clean.json`), keeping the published tree free of machine-facing files.

The template expands against the **input document's own frontmatter** (`title:`, `started:`, `session:`, `sources:`), not against flags, so a manual rerun files exactly where the daemon-spawned run did. See [configuration](../configuration.md#path-templates).

### Guardrails
Cleanup must improve readability without hallucinating or over-editing:

- **Accept/fallback validation:** if a cleaned segment diverges from the source beyond bounds (length ratio, structural drift), reject it and keep the original rather than shipping a hallucination. Validation is **per turn even though the call is batched**, so a response that merges, reorders, or invents turns degrades to per-turn fallbacks instead of shifting one speaker's words onto another.
- **Turn-for-turn correspondence:** a chunk's response is matched back by marker number, and a turn the model dropped keeps its original text. Cleanup starts from the originals and overwrites only what both parses and validates, so turn count, order, timings, and speakers cannot be disturbed by a bad response.
- **Minimal-change prompting:** the smallest edit that fixes errors; filler words are kept unless removal is configured.
- Timestamps and segment/turn structure are preserved; cleanup never invents or drops turns. Frontmatter records model + settings for reproducibility.

### Why batch
Per-turn calls made the stage both slow and context-free: a 42-minute meeting is ~2,500 VAD-bounded turns, which at a few seconds per call runs for hours while the daemon's on-end chain (and so `summarize`) waits behind it — and each turn was corrected with no sight of the conversation around it, which is exactly what resolves a homophone or a name. Batching by *spoken* time keeps a chunk's context comparable across transcripts; turn count varies with VAD aggressiveness and character count tracks speaking rate. `[cleanup] model` defaults to a cheap model for the same reason: this is bulk mechanical correction over every turn of every recording, and it should not share `summarize`'s model choice.

### CLI
```
cleanup (<transcript.md> | --session <id>) [--out <path>] [--prompt <file>] [--vocab <path>] [--model <name>] [--no-vocab]
```

## `summarize`

### One job
Produce one or more summaries of one or more transcripts from configurable prompt presets.

### Behaviour
1. Read the transcripts named — explicit paths, or `--session <id>` to resolve the session's *cleaned* transcript (falling back to its raw one if none was published). No sibling redirection: the caller names its input, and the daemon chain passes cleanup's output forward.

   An input that doesn't parse as an ears document is **summarized anyway**, from its text, with a warning. The stage's job is "summarize the transcript at this path", and a vault holds plenty of Markdown transcripts this pipeline never produced — exports from other tools, hand-written notes of a call. The parse exists to recover metadata a foreign transcript simply lacks, so what its absence costs is the header (no title, start or speaker roll-call), not the summary. A `frontmatter = true` preset's summary then records `model: { name: unknown, … }` and a zero range: ignorance stated, rather than this pipeline's ASR claimed for a transcript it never touched.
2. Read each selected preset's companion `notes` file, if it configures one — as plain Markdown, no frontmatter parsing, no sidecar. Every input is read before any write. The template's own path is used when it exists; otherwise the note is **searched for** (see "Finding the notes" below).
3. For each selected preset (`[[summarize.preset]]`), run its prompt over the result. With notes present the LLM input is labelled — `## Jotted notes` then `## Transcript` — so a prompt can address each; with no notes the transcript is sent bare.

   Each transcript is rendered as a short `title:` / `started:` / `transcript:` / `speakers:` header followed by one `[HH:MM:SS] Speaker: text` line per turn. The header is not decoration: without it a preset asked to date the conversation or link its transcript has nothing to date or link it *from*, and answers by flagging the note or inventing a path. `speakers:` marks every speaker captured on `mic` as `(me)`, which is how a prompt tells the note's author from its subject — a display name cannot, as a mislabelled remote track will happily carry the local participant's name. Nobody is marked when *every* speaker resolves to the mic, since that is equally the shape of a single-source room recording and of a Markdown parse with no sidecar to separate them.
4. Write `<...>.summary.md` (or `<...>.<preset>.summary.md` when multiple), frontmatter `kind: summary` with `preset` and `derived_from`.
5. Stamp `note:` into each input transcript's frontmatter, naming the summary just written — the inverse of the `transcript:` link the summary carries, so the pair is navigable from either end.

   This is the one place `summarize` writes to its own input, and it happens only after that input is fully read and the summary is on disk, so the read-before-write ordering `out = "{notes}"` depends on still holds. The edit is a text splice into the YAML block (`TranscriptFrontmatterEditor`), not a parse/render round trip: a transcript's turns are never rewritten to add a link. A multi-preset run leaves the last preset's destination there. Failure to write it is a warning, never the preset's failure — the summary exists and is correct, and losing it over an unwritable source file would be the worse outcome.

   A transcript with no frontmatter block at all gets one holding just this field. Adding a link is not the same act as inventing capture metadata: it is a fact about the file, known for certain at the moment it is written, and a foreign transcript is the case that most needs it — nothing else in the file records where its summary went.

   Link targets are vault-relative when the destination sits inside an Obsidian vault and absolute otherwise (`VaultPath`, which detects a vault by its `.obsidian` marker rather than taking a config key — the fact is already on disk, and a stale key would produce links resolving to nothing). The absolute fallback is deliberately still a path: a bare filename would *look* like a working wikilink while resolving to nothing, or to an unrelated note sharing the name.

Presets are named prompt files, so summary styles (brief, decisions, action items) are user configuration, not code. Three optional keys let a preset publish on its own terms:

- **`notes`** — a path template for a companion notes file, treated as the ideal location rather than the only one (see "Finding the notes"). A configured notes file that is neither there nor findable is **a warning, not a failure**: the preset runs with an empty `## Jotted notes` section, so a call with nothing jotted still gets summarized from its transcript. (This failed the preset until it turned out the common case is the opposite one — most captured calls have no note waiting at the templated path, and failing there left every such session with a transcript and no summary.)
- **`out`** — a path template for this preset's destination, overriding the default sibling naming. It may reference `{notes}` to write back over the notes file; overwrite is the intended semantics, and the prompt is responsible for carrying the jotted notes forward into its output. Safe because every input is read first and writes are atomic. There is no append or section-merge mode. `--out` on the command line outranks this template (as `--notes` outranks `notes`), which is how a one-off run redirects a `{notes}` preset away from the note it would otherwise overwrite.
- **`frontmatter = false`** — emit the summary body alone: no YAML block, and no JSON sidecar either. The artifact is then plain Markdown rather than an ears document, which is what writing into a vault that owns its own frontmatter needs.

### Finding the notes

A path template is a good way to write a file and a poor way to find one, and `notes` is doing the second job: an exact-match lookup for a file a human created and named, keyed on a string a machine generated on the other side of the call. Anything that moves either side misses — a session whose title never resolved past the platform's meeting id, a vault whose filing convention grew a directory level, a note named "Matt Barras" for an attendee the roster calls "Matthew Barras" — and the miss is silent: the fold-in prompt runs with an empty notes section and the jottings are absent from the note that replaces them.

So when the template's path isn't there, `NotesLocator` searches its directory and one level below, scoring each `.md` file on the signals a person would use to recognise their own note:

- **filed under the right day** — in the filename or in a directory component. A precondition, not a score: a note from another day is not this call's notes however well it scores otherwise.
- **names someone who was on the call** — matched against the transcript's `attendees:` (excluding the local participant, since a note is named after the other person), token by token, so "Matt" finds "Matthew".
- **edited while the call was running** — measured against the daemon's recorded intervals for the session (paused stretches excluded), with no grace period after the end. A store-less manual run falls back to the transcript's `range`. A grace period used to stretch the window, and summaries are written in exactly that period: on 2026-09-21 one call's published note read as edited during the next call, and the next call's summary overwrote it.

Two kinds of file are never candidates, because ears wrote them and their change time says nothing about a person taking notes:

- a note another session **claimed**: its `published_notes` in `session.toml`, recorded by earsd after summarize succeeds;
- a note whose frontmatter `transcript:` links a transcript this run is not summarizing, compared by filename stem so an Obsidian short link still matches. This covers manual runs, which record no claim.

A candidate with no positive signal is not returned, and a tie between the top two returns nothing: an unmatched note leaves the run where it was, while a wrongly matched one overwrites a note about something else. A match that names a participant is used as notes and is the `{notes}` destination. A match on edit time alone is used as notes only: `{notes}` stays the template's path, so a wrong match adds a file instead of replacing one. A match found this way is reported, and the note says so.

### Overwrite safety

Any destination that already exists is copied to `~/.local/state/ears-note-backups/<stem>.handnotes.md` before it is written. The fold-in pattern reads hand-typed jottings and replaces them with a summary; when that goes wrong — a prompt needing another pass, a transcript whose speakers were mislabelled — the input is gone, and hand-typed notes exist nowhere else. An existing backup is never replaced, only numbered past, so the *original* jottings survive however many times a preset is re-run while a prompt is iterated on. A backup that fails stops the write: losing a summary is recoverable, losing the note is not.

### Warnings reach the note

A degraded run puts an Obsidian `> [!warning]` callout at the top of the note's prose (after its own frontmatter, which must stay first in the file) listing the transcript's `warnings:` plus anything `summarize` itself had to say — jottings that could not be found, or that were matched by search rather than by name. The transcript's warnings also go into the prompt header verbatim, so the model can hedge the specific claims a degraded run undermines rather than the note as a whole.

This exists because every failure behind a mislabelled note was already being detected and reported — to a log nobody reads. A false positive costs one line in a note; a false negative costs the note.

### CLI
```
summarize (<transcript.md> [more...] | --session <id>) [--preset brief] [--all-presets] [--select-preset] [--out <path>] [--notes <path>] [--model <name>]
```

`--notes` applies to a single-preset run, like `--out`; selecting more than one preset with it is a usage error.

`--select-preset` runs the one preset the conversation is for: a single LLM call classifies the transcript against each preset's `when` description and the preset that matches is the only one rendered. It is what the daemon's session-end chain spawns, since a conversation has one type and two presets writing to one note destroy each other's work. Combining it with `--preset` or `--all-presets` is a usage error, and a config where no preset declares a `when` is a config error naming the gap. An answer that names no configured preset falls back to the first one and says so on stderr — a note filed under the wrong shape can be rerun with `--preset`, where a failed chain leaves the session with no note at all.

Whatever selects the presets, no two of them share a destination: presets resolving to one path are disambiguated in run order (`<name>.<preset>.<ext>` for each later collider), so nothing overwrites a note the same run just wrote.

## Composition

The stages chain but never depend on each other at runtime — each reads and writes files:

```sh
transcribe --session "$SESSION_ID" \
  && cleanup --session "$SESSION_ID" \
  && summarize --session "$SESSION_ID" --preset brief --preset actions
```

Or by path, since each stage prints where it wrote:

```sh
summarize "$(cleanup "$(transcribe --session "$SESSION_ID")")" --select-preset
```

The daemon runs this chain itself when a browser session ends (`[earsd.sessions] on_end_stages`, default all three stages — see [capture-daemon](capture-daemon.md)). Any stage can still be run alone against an existing file.

### Output-path contract (stdout)

Two result surfaces share one rule: **empty stdout means no result.** Plain mode is the frozen surface for humans and `$(…)` scripts; the `--json` envelope is the versioned surface for machines. The daemon's session-end chain speaks only the envelope — it spawns every stage with `--json` (see [capture-daemon](capture-daemon.md#session-end-pipeline)).

**The plain promise, frozen (issue #62):** On exit 0 in default mode, stdout is exactly one line: the absolute path of the primary output. All other output goes to stderr. This will not change.

`transcribe` (batch mode) prints the raw transcript's path in the data store; `cleanup` prints the published path. `summarize` writes one file per preset and currently prints no path — its result surface is the `--json` envelope below; a plain result line for the single-preset case is deferred until something needs it. Script use: `` cleanup "$(transcribe --session "$SESSION_ID")" ``.

Failure ⇒ empty stdout: a run that exits non-zero writes **nothing** to stdout, in default and `--verbose` mode alike. `--verbose` (shorthand for `--log-level debug`) only widens what reaches stderr and the log file — it never changes stdout. Enforced structurally by `EarsCLISupport.ResultChannel`'s fd swap (the process's real stdout descriptor is reserved for the result; every other write in the process lands on stderr — `--follow`'s segment stream routes through the saved descriptor deliberately), stated verbatim in each stage binary's `--help` (`EarsCLISupport.PlainModeContract`), and pinned end to end by `Tests/CLISmokeTests/PlainModeContractSmokeTests.swift`.

Rejected designs, recorded so they stay rejected:

- **No last-line parsing.** "The path is the final stdout line" (or the last non-empty one) turns any stray print into silent corruption — the consumer reads a plausible wrong string instead of failing.
- **No second stdout line, ever.** It would break every `$(…)` consumer and any strict one-line parse in the same release.
- **No TTY detection for the data format.** `cmd > file` must equal what the terminal showed; a shape that depends on who is watching cannot be scripted against.
- **No `key=value` mode.** Anything richer than the one path line needs escaping and multiline-injection gymnastics on stdout — that is the `--json` surface's job, on its own flag, never a mutation of plain mode.

### Result envelopes (`--json`)

The plain contract is frozen, so all growth happens in the opt-in `--json` envelope (issue #63): versioned, additive-friendly, and loud on pollution — a stray stdout byte makes the document unparseable instead of producing a plausible wrong string. All three batch stages carry the flag.

On `transcribe`, `--json` reuses the existing flag: under `--follow` it still means JSON *segment lines*; in batch mode it means the result envelope. The modes are mutually exclusive, so the two meanings can never collide in one run.

**Success (exit 0):** stdout is exactly one JSON document, emitted through `EarsCLISupport.ResultChannel` (the plain path line is withheld — the envelope is the whole stdout):

```json
{"schema":"allears.transcribe/v1","ok":true,"output":"/abs/….transcript.md","outputs":["/abs/….transcript.md","/abs/….transcript.json"],"warnings":[],"stats":{"duration_s":412,"segments":87,"words":1042}}
```

**Failure (non-zero exit):** stdout stays **byte-empty** — "empty stdout ⇒ no result" holds in both modes — and the **last line of stderr** is an error envelope with the same `schema` field, `ok: false`, `exit_class` (the taxonomy label below), and `message`. Usage rejections that stop the invocation before a run starts (ArgumentParser validation) keep their plain usage error: stdout is still empty, but no envelope is emitted for a run that never began.

**`output` semantics:** present when exactly one primary artifact exists — `transcribe`: the raw transcript; `cleanup`: the published cleaned transcript; `summarize` single preset: that summary file. A multi-preset `summarize` run has no single primary artifact, so `output` is absent and `outputs[]` carries per-preset entries `{preset, path, ok}` — which also makes partial success ("2 of 3 presets") expressible: presets run independently, each outcome is reported, and the exit is 0 only when all presets succeeded (a failed run's stderr envelope still carries `outputs[]`, naming what was written).

**`stats`** starts minimal — whatever `run.summary` already computes per tool (`transcribe`: `duration_s`/`segments`/`words`; `cleanup`: `segments`/`accepted`/`fallback`/`skipped`/`chunks`; `summarize`: `presets`).

**Versioning.** The `schema` field, `allears.<tool>/v<major>`, carries only the major:

- Additive keys are non-breaking. The schemas deliberately leave `additionalProperties` permissive, so consumers must ignore unknown keys — that *is* the minor-version policy, and the daemon's decoder ignores them by construction.
- Removing or renaming a key, or changing a key's meaning, bumps the major in `schema`.
- A consumer fails a stage only on a major mismatch, naming both identifiers — expected and received — so the log states exactly which side moved.

The cross-repo contract is one JSON Schema per stage checked into `shared/stage-envelopes/<tool>.v1.schema.json` (the same home pattern as `shared/protocol-fixtures/`), with example fixtures beside them that the Swift suite decodes and round-trips (`StageEnvelopeFixtureTests`). The envelope structs are `Codable` types owned by each tool; the daemon decodes with its own `EarsDaemonKit.StageResultEnvelope`. Pinned end to end by `Tests/CLISmokeTests/JSONEnvelopeContractSmokeTests.swift` across every stage, success and failure, with and without `--verbose`.

### Exit codes

One taxonomy across all three stages (`EarsCLISupport.ExitClass`, issue #61), documented in each binary's `--help` epilogue. Codes carry the failure's *class*, never data states; anything an operator needs beyond the class goes to stderr and the structured log. The daemon logs the class label next to the raw code (`cleanup failed (exit 5, retryable-upstream)`) and labels any code outside the taxonomy `unclassified` rather than guessing.

| Code | Class | Meaning |
|-----:|-------|---------|
| 0 | `success` | The run succeeded. |
| 3 | `input-missing` | The named input doesn't resolve: unknown `--session` id, unreadable or unparseable input file. |
| 4 | `stage-failed` | The stage itself failed: model error, output write failure, unusable config, every cleanup candidate rejected. |
| 5 | `retryable-upstream` | A retry-worthy upstream outage: LLM command timeout or network-shaped failure. |
| 64 | `usage` | Invalid arguments or flag combinations — swift-argument-parser's default (`EX_USAGE`), adopted rather than overridden so hand-rolled guards and ArgumentParser's own validation exits agree on one code. |

### Held in reserve (phase 3)

Two channels are designed but deliberately unbuilt, with their trigger conditions recorded so they are recognised when they arrive:

- **`--out-manifest PATH`** — the same result envelope written to a file (atomic temp + rename), written even on failure with `ok: false`. Build it when crash-recoverable state needs to *drive daemon behavior* — a retry policy resuming from a stage that died mid-run, or per-preset partial success steering a re-run — rather than be logged. Until then, the stdout envelope plus the exit code carry everything the daemon acts on.
- **JSONL progress events on stderr** — deferred until something consumes progress. The extension badge, the one live consumer today, already gets progress via the daemon's `job.publish` feed.
