# Configuration

## Model

Layered, highest wins:

1. **Built-in defaults** — every setting has one; the suite runs with no config file.
2. **Config file** — TOML at a standard path.
3. **Environment variables** — prefix `EARS_`, nested keys joined by `__` (e.g. `EARS_LOG__LEVEL`).
4. **CLI flags** — per-invocation overrides: the typed flags (`--log-level`, `--log-file`), then the generic `--set`/`--set-string` on top.

Example for the data root: default `~/Library/Application Support/ears` → `data_root` in TOML → `EARS_DATA_ROOT` → `--set data_root=/path`.

## Overriding any setting from the CLI

Every tool accepts `--set <dotted.key>=<value>` (repeatable) to override any config setting for one invocation, without a dedicated flag per key — the CLI-side twin of the `EARS_*` environment variables, and the highest-precedence layer:

```
transcribe --set transcribe.backend=parakeet --set diarize.backend=sortformer
earsd --set earsd.vad.min_silence_ms=500 --set log.level=debug
cleanup notes.transcript.md --set llm.model=claude-opus-4-8
```

- **Typed values.** `true`/`false`, integers, and floats are coerced to their type, matching the `EARS_*` layer. Use `--set-string <key>=<value>` to force a literal string (a version like `1.0`, a numeric id).
- **The value may contain `=`.** Only the first `=` splits key from value, so `--set llm.command='llm -m gpt'` works.
- **Validated.** An override is merged then checked against the schema, so a typo'd key or a wrong-typed value is rejected with a precise message, never silently dropped. A malformed `--set` (no `=`) fails the invocation.
- **Arrays replace wholesale.** Setting an array-valued key replaces the whole array; there is no element-wise patch.

The typed convenience flags (`--log-level`, `--log-file`, and `cleanup`'s `--model`/`--prompt`/`--vocab`/`--no-vocab`) remain; `--set` reaches everything else.

## Discovering settings

`ears config describe` lists every setting across all tools — dotted key, type, default, and a one-line description — rendered from the schema itself, so it never drifts from the code:

```
ears config describe
```

Two companions show the resolved values rather than the reference: `ears config show` (or any tool's `--print-config`) prints the merged config as TOML, and `ears config path` (or `--config-path`) reports which file was loaded.

## File location

Resolved in order:

1. `--config <path>` flag.
2. `EARS_CONFIG` env var.
3. `$XDG_CONFIG_HOME/ears/config.toml` if set.
4. `~/.config/ears/config.toml`.

All tools read the same file. Tool-specific settings live in their own tables.

## Reference

```toml
schema = 1

# --- Shared paths ---
data_root   = "~/Library/Application Support/ears"  # sessions (records, audio, raw transcripts), vocab, runtime
output_root = "~/Documents/Transcripts"             # published artifacts: cleaned transcripts, summaries
socket_path = ""   # empty => <data_root>/runtime/earsd.sock

# Which week-of-year convention a path template's {week} renders.
# "us"  — weeks start Sunday, week 1 holds Jan 1 (Obsidian's `ww` default)
# "iso" — ISO-8601: weeks start Monday, week 1 holds the first Thursday
week_numbering = "us"

# --- Logging (see logging.md) ---
[log]
level     = "info"        # debug | info | notice | error
file      = ""            # JSON Lines sink (primary); empty => <data_root>/logs/<tool>.jsonl
format    = "auto"        # auto | json | pretty  (auto: pretty on a TTY, json otherwise)
oslog     = true          # also mirror events into Apple unified logging
subsystem = "net.tomelliot.ears"
rotate_max_bytes = 52428800   # rotate the JSON log at ~50MB
rotate_max_files = 5

# --- Capture daemon ---
[earsd]
chunk_seconds            = 30     # bounds live-transcription latency; use ~10 for `transcribe --follow`
codec                    = "aac"  # aac | opus
bitrate                  = 64000
native_sample_rate       = 48000  # listenable chunks/ feed
asr_sample_rate          = 16000  # derived asr/ feed for transcription
store_native             = true   # keep the listenable copy alongside the ASR feed
channels                 = 1

# Transcript-driven retention. A session's audio (sessions/<id>/sources/) is
# deleted once its transcript has been complete for evict_after_transcript_seconds;
# a session whose transcript never completed keeps its audio until
# max_audio_age_seconds after it ended (so a failed run can be retried), then
# it is deleted regardless. session.toml/events.jsonl and transcripts are
# never deleted.
[earsd.retention]
evict_after_transcript_seconds = 7200    # 2h after a successful transcript
max_audio_age_seconds          = 604800  # 7d hard cap for never-transcribed sessions

[earsd.vad]
backend        = "silero"  # currently ignored: an energy-threshold VAD is always used
speech_pad_ms  = 300       # pad around detected speech spans
min_silence_ms = 700       # gap before declaring silence

[earsd.sessions]
# How long a browser session's last ingest stream may stay closed before the
# daemon ends the session on its own (events.jsonl reason "ingest-idle").
# Manual sessions are never auto-ended.
ingest_close_grace_s = 120
# How long a browser-ended session waits before its pipeline runs. If the same
# meeting is declared again within it (a drop and rejoin), the session
# continues instead of a second one starting. 0 ends at once.
rejoin_hold_s = 60
# Locally-captured sources folded into every browser session, so your own side
# is transcribed alongside the extension's per-participant streams. Each id is
# included only if the daemon is actually capturing it. Set to [] to disable.
local_sources = ["mic"]
# Pipeline stages auto-run when a browser session ends, in chain order:
# transcribe writes the transcript, cleanup corrects it with the [llm] backend,
# summarize renders the one [[summarize.preset]] this conversation is for,
# chosen by classifying the transcript against each preset's `when` description
# (`summarize --select-preset`). cleanup/summarize require
# transcribe (they consume its output); an invalid entry is dropped with a
# logged warning. Set to ["transcribe"] to skip the LLM stages, [] to disable
# the chain entirely.
on_end_stages = ["transcribe", "cleanup", "summarize"]
# The empty-transcript gate. After transcribe, the chain reads the fresh
# transcript's own word_count and speech_seconds; if either falls below its
# threshold the session recorded nothing anyone said, and cleanup and summarize
# are skipped rather than spent inventing a note from silence. The transcript is
# still written and still stamps transcript-completion, so audio retention is
# unaffected. Set either to 0 to disable that half of the test; both 0 runs the
# whole chain unconditionally.
min_words          = 10
min_speech_seconds = 5

# Audio ingestion from the browser extension (binary PCM). Off by default.
[earsd.ingest_ws]
enabled         = false
port            = 47811   # loopback only
allowed_origins = []      # e.g. ["chrome-extension://<id>", "moz-extension://<uuid>"];
                          # empty rejects every connection (fail closed)

# Control plane for the browser extension (session lifecycle, status). Off by default.
[earsd.control_ws]
enabled         = false
port            = 47812   # loopback only
allowed_origins = []      # same fail-closed allowlist as ingest_ws

# Sources enabled at startup. Each may override capture params.
[[earsd.source]]
id    = "mic"
class = "mic"
device_uid = ""           # empty => default input

[[earsd.source]]
id    = "system"
class = "system"
enabled = false           # opt-in: needs the system-audio-recording permission

[[earsd.source]]
id    = "app:us.zoom.xos"
class = "app"
label = "Zoom"

# --- LLM stages ---
[llm]
backend = "llm-cli"           # llm-cli | command — both run a subprocess:
model   = "claude-sonnet-5"   #   llm-cli runs `llm -m <model>`; command runs the line below
# command = "my-llm-wrapper --fast"   # prompt on stdin, completion on stdout
timeout_seconds = 120         # per LLM call, cleanup and summarize; on expiry the
                              #   stage exits 5 (retryable). <= 0 uses 120

[cleanup]
prompt_file = ""              # empty => built-in cleanup prompt
model       = "claude-haiku-4-5"  # overrides [llm] model here; "" falls back to it
chunk_seconds = 300           # spoken seconds of transcript per LLM call
use_vocab   = true
# Where the cleaned transcript is published (a path template, see below).
output = "{output_root}/{year}/{month}/{day}/{date} - {title}.md"

[[summarize.preset]]
name = "brief"
prompt_file = "prompts/brief.md"
# `when` describes, in plain language, the conversations this preset is for. A
# session gets exactly one preset: the daemon's on-end chain runs
# `summarize --select-preset`, which classifies the transcript against these
# descriptions in one short LLM call and renders only the preset that matches.
# A conversation has one type, and running every preset over it both costs a
# call per preset and lets two presets writing to the same note overwrite each
# other. A preset with no `when` is never selected automatically; it stays
# available to `summarize --preset <name>` and `--all-presets`, which run
# exactly what you name whatever the descriptions say.
when = "a call with an external person: user research, sales, investor"
[[summarize.preset]]
name = "actions"
prompt_file = "prompts/action-items.md"
when = "a working session with an advisor coaching me"
# A preset may read a companion notes file, write anywhere, and skip the
# ears frontmatter — enough to fold a call into an Obsidian daily note:
# [[summarize.preset]]
# name = "meeting-notes"
# prompt_file = "~/vault/prompts/meeting-notes.md"
# notes = "~/vault/daily-notes/{year}/{month}/{week}/{date}/{date} - {title}.md"
# out = "{notes}"          # write the result back over that same note
# frontmatter = false      # body only — the vault owns its own frontmatter
# A call with no note waiting at that path still summarizes — the jotted-notes
# section comes through empty and the missing file is warned about on stderr.
# If a run does end up with two presets resolving to one path (`--all-presets`
# over presets that share an `out`), the first keeps the path and each later
# one is written to `<name>.<preset>.<ext>` — no note is overwritten by a
# summary the same run just produced.

# --- Vocabulary ---
[vocab]
global = ""   # relative to data_root; empty (the default) => no global list. e.g. "vocab/global.txt"
```

Transcription uses Parakeet via FluidAudio on the Apple Neural Engine, with VAD silence-skipping on. The `[transcribe]` table selects the backend/model/compute (all optional — the defaults above are assumed):

```toml
# --- Transcription ---
[transcribe]
backend = "fluidaudio"   # ASR backend
model = ""               # optional model id (e.g. "parakeet-tdt-v3"); empty = backend default
compute = "automatic"    # "ane" | "gpu" | "cpu" | "automatic"
```

**Diarization** (splitting a multi-speaker far-end source into `Speaker N`) is a separate, opt-in stage — off by default, since it downloads a model and costs ANE time:

```toml
# --- Diarization ---
[diarize]
backend = "none"         # "none" (default) | "sortformer"
model = ""               # optional model id override; empty = backend default
compute = "automatic"    # "ane" | "gpu" | "cpu" | "automatic"
```

With `backend = "sortformer"`, `transcribe` runs NVIDIA Sortformer (via FluidAudio) as an offline pass and refines multi-speaker turns into `<source> · Speaker N`. Source-of-origin stays the primary label; the diarizer only adds the within-source split. A diarizer that fails to load or run is non-fatal: the transcript falls back to source-only labels. The Sortformer model downloads automatically on first use.

- **Captured audio** (`--last`/`--from`/`--to`, `--session`): only multi-speaker far-end sources are diarized — `system`, `app:*`, `device:*`, and `browser:teams:*` — never the `mic` or the per-participant `browser:meet:*` / `browser:zoom:*` streams (each already a single speaker). Teams is the exception among browser sources because it delivers one mixed track carrying every remote participant; splitting a per-participant stream would trade a real name for two invented ones.
- **Standalone files** (`--file`): the whole file is treated as one multi-speaker source and always diarized when a backend is configured, since a file carries no source-of-origin separation. Example: `transcribe --file memo.m4a`.

## Two tiers of artifact

The pipeline writes two kinds of file, and they live in different places.

**Intermediates** — the raw `.transcript.md`, its JSON sidecar, and the cleaned run's `transcript.clean.json` sidecar — live in the hidden data store under `data_root`, addressed by session (`sessions/<uuid>/transcript.md`) or by range-run id (`runs/<id>.transcript.md`). They have no user-facing layout, and nothing sweeps them: once the audio is evicted they are the only route to re-running cleanup or summarize with a different prompt or model.

**Published output** — the cleaned transcript and the summaries — lands wherever its path template resolves to, under `output_root` by default. This is the tier you open, sync, and file. It is Markdown only: the cleaned transcript's JSON sidecar stays in the data store, never beside a published note.

## Path templates

`[cleanup] output` and a preset's `notes`/`out` are path templates: a full path with `{token}` placeholders.

| Token | Expands to |
|---|---|
| `{output_root}` | the configured `output_root` |
| `{year}` `{month}` `{day}` | the session's start date, zero-padded |
| `{date}` | `YYYY-MM-DD` |
| `{time}` | `HH-MM-SS` |
| `{week}` | week of year, zero-padded, per `week_numbering` |
| `{session}` | the session id |
| `{slug}` | the path-safe source list, e.g. `mic_app_us.zoom.xos` |
| `{title}` | the session title, sanitised for a path |
| `{notes}` | a preset's expanded `notes` path — in `out` only |

- **Dates come from the session start, not the wall clock.** A call that runs past midnight files under the day it started, and re-cleaning it a week later lands on the same path.
- **Missing context degrades.** No title falls back to `{slug}`; no slug falls back to the input file's basename. A `--file` transcript's slug *is* its basename, so `{title}` resolves sensibly there too.
- **An unknown token is a config error**, reported with its key path like any other invalid value — never a literal `{titel}` in a filename.
- Parent directories are created as needed, and writes are atomic.

## Conventions

- **Paths** support `~` expansion and resolve relative to `data_root` when not absolute (except `data_root`/`output_root`, and the path templates above, which get `~` expansion only — their base is a token, not the cwd).
- **Zero-config:** with no file present, the daemon captures `mic` with the defaults above and the LLM stages use the `llm` CLI.
- **Validation:** each tool validates its config at startup and exits non-zero with a precise message (key path + reason) on any unknown key or invalid value. No silent fallback.
- **Discovery:** every tool prints the resolved, merged config and reports which file was loaded. The single-purpose tools spell it `--print-config` / `--config-path`; `ears` spells it `ears config show` / `ears config path`. `ears config describe` lists every setting with its type, default, and description (see "Discovering settings").
- **Overrides:** every setting can be overridden per-invocation with `--set <dotted.key>=<value>` (typed) or `--set-string` (literal), the highest-precedence layer (see "Overriding any setting from the CLI").
