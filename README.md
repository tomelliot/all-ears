<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/logo-horizontal-reversed.svg">
  <img src="docs/brand/logo-horizontal.svg" alt="All Ears" width="320">
</picture>

Local. Composable. Split by source (instead of untangled later).

All Ears runs a small daemon that records the audio sources you configure (microphone, system audio, per-app audio, meeting-tab audio) for the duration of each recording session, each source as its own local stream. It transcribes live while you're in the call, and transcribes, cleans up, and summarises when the session ends.

## Why All Ears

- **Small tools, not one app.** Capture, transcription, cleanup, and summarisation are separate command-line tools that read and write plain files, instead of one inscrutable binary. Script them, replace one, extend them.
- **Knows who said what, by name, on Google Meet.** The browser extension isolates each remote participant's audio into its own stream and reads their real display name straight off the call UI, without manual labelling or voice-print guessing. Zoom gets the same per-participant separation from the call's own tracks. Teams gets attributed `Speaker N` streams instead.
- **Sources are separated before transcription, not after.** Mic, system audio, each app, and each meeting participant are captured as distinct streams from the start. Transcription and diarization run on a clean single-speaker signal instead of untangling a blended recording after the fact, so accuracy and speaker attribution are both better for it.
- **Local-first.** Audio and transcripts stay on disk on your Mac; transcription runs on the Neural Engine. The only network calls are the one-time speech-model download and whichever LLM you configure for cleanup and summaries.

## Install

Requirements:

- **Apple Silicon, macOS 15+, and [Swift 6](https://www.swift.org/install/)** to build.
- **The [`llm` CLI](https://llm.datasette.io/)** (`brew install llm`) for the `cleanup` and `summarize` stages, which shell out to it by default. Capture and transcription work without it, and `[llm] backend = "command"` routes those stages to any other command instead — see [Your model, your prompts](#your-model-your-prompts).
- No model setup: the Parakeet speech model downloads automatically on the first transcription run.

```sh
git clone https://github.com/tomelliot/all-ears.git
cd all-ears
make install
```

`make install` builds the release binaries, signs them, installs the five tools
(`earsd`, `ears`, `transcribe`, `cleanup`, `summarize`) to `~/.local/bin`, and
registers `earsd` as a per-user launchd **LaunchAgent** — started at login, kept
alive, and restarted on crash. Check it's running:

```sh
ears status
```

- **Where things go.** Binaries → `$PREFIX/bin` (default `~/.local`; if that
  isn't on your `PATH`, `make install` prints the line to add). LaunchAgent →
  `~/Library/LaunchAgents/net.tomelliot.ears.earsd.plist`. Pre-logger crash
  output → `~/Library/Logs/ears/`. Your config lives under `~/.config/ears`,
  recordings and raw transcripts under `~/Library/Application Support/ears`,
  and published transcripts and summaries under `~/Documents/Transcripts`
  (configurable — see [Where things land](#where-things-land)).
- **System-wide install.** `make install PREFIX=/usr/local` puts the binaries on
  the default `PATH`; the copy elevates itself with `sudo` when needed. Run
  `make install` as your normal user, never under `sudo` — the agent must load
  into your GUI session.
- **Signing & permissions.** macOS ties the microphone / system-audio grant to
  the binary's code-signing identity. Pass a stable one so the grant survives
  reinstalls: `make install SIGN_IDENTITY="Developer ID Application: You (TEAMID)"`.
  Without it, the install signs ad-hoc and warns that macOS may re-prompt after
  an upgrade.
- **Upgrade.** Re-run `make install` (or `make reinstall`) after `git pull`; it
  rebuilds, re-signs, and reloads the agent onto the new binary.
- **Uninstall.** `make uninstall` stops and removes the agent and the binaries.
  Your recordings, config, and transcripts are left untouched.

### Build without installing

To run straight from the build directory instead:

```sh
cd daemon
swift build -c release
.build/release/earsd &          # start the daemon (captures your mic by default)
.build/release/ears status      # check what it's hearing
```

Add `daemon/.build/release` to your `PATH` and the commands below drop the
leading `.build/release/`.

## Usage

**Live transcription.** Start a session and watch the transcript arrive as people speak:

```sh
ears session start --source mic
transcribe --follow mic
```

`--follow` attaches to the live source and streams finalised segments to stdout until you stop it (add `--json` for JSON lines instead of plain text).

Live latency follows the daemon's chunk length: `--follow` reads finalised capture chunks, so segments trail speech by up to `chunk_seconds` (default 30) plus a moment of decoding. For live transcription, set a shorter chunk in `~/.config/ears/config.toml` and restart the daemon — 10 seconds puts the transcript ~5–15 s behind your speech, at the cost of more, smaller files in the buffer:

```toml
[earsd]
chunk_seconds = 10
```

```sh
launchctl kickstart -k gui/$UID/net.tomelliot.ears.earsd
ears config show | grep chunk    # confirm the resolved value
```

**Full pipeline.** When the call is over, end the session, then correct and summarise its transcript:

```sh
ears session end <session-id>
transcribe --session <session-id>   # raw transcript, into the session's store
cleanup --session <session-id>      # publishes the cleaned transcript
summarize --session <session-id> --preset action-items
```

The raw transcript is an intermediate: it stays in the data store, addressed
by session. The cleaned transcript and the summaries are what get published,
to `~/Documents/Transcripts/<year>/<month>/<day>/<date> - <title>.md` by
default — and to wherever you point them, since the path is a template. See
[Where things land](#where-things-land).

A summary preset is a prompt file you write, named in your config — see
[Your model, your prompts](#your-model-your-prompts).

**What's in the pipeline?** Bare `ears` (or `ears status`) is a dashboard:
live sessions with their sources grouped beneath them, and the last few ended
sessions with how far each got. `ears sessions` lists recent sessions one
line each with a pipeline outcome (`--all` for full history), and
`ears session show <ref>` walks one session stage by stage — capture,
transcribe, cleanup, summarize, note — resolving `<ref>` from a session-id
prefix, a title fragment, or today's start time (`15:01`):

```
Matt Silva — ended 17:32, 31m

  capture     ✓ 33 MB mic, 21 MB remote (1 of 3 tracks carried speech)
  transcribe  ✓ 177 segments, 5,745 words
  cleanup     ✓ 177 segments cleaned
  summarize   ✓ note published
  note        ✓ calls/2026-08-17 - Matt Silva
```

A session that published with attribution warnings is flagged (`⚠`);
`--warnings` prints them verbatim.

**A stage failed?** `ears session retry <ref>` reruns the pipeline from the first stage that did not finish and prints the result. A cleanup that timed out reruns cleanup and summarize over the transcript already on disk, without transcribing again. `--from <stage>` picks the stage.

**Meeting notes, hands-free.** The [browser extension](browser/) isolates each remote participant's audio in Google Meet, Zoom, and Teams tabs and streams it to the daemon as its own source — each captured track shows up as `browser:<platform>:<track>` alongside your other sources (the id is an opaque handle; who's speaking on it comes from the roster). It declares the call to the daemon as a session, and when the call ends the daemon transcribes the session automatically; `ears sessions` shows it with its pipeline outcome, `cleanup`/`summarize` run on the result.

## Your model, your prompts

`cleanup` and `summarize` call whatever LLM you configure in `~/.config/ears/config.toml` — no model is hard-coded:

```toml
[llm]
backend = "llm-cli"          # runs the `llm` CLI: any model it can reach, hosted or local
model   = "claude-sonnet-5"  # any `llm` model id; empty uses llm's own default

# Or route both stages to any command that reads a prompt on stdin and
# prints the completion on stdout — a local model, a wrapper script, anything:
# backend = "command"
# command = "ollama run llama3.2"

[cleanup]
prompt_file = ""             # empty = the built-in correction prompt; set a path to use yours

[[summarize.preset]]
name = "brief"
prompt_file = "prompts/brief.md"
[[summarize.preset]]
name = "action-items"
prompt_file = "prompts/action-items.md"
```

Summarisation prompts are entirely yours: each `[[summarize.preset]]` pairs a name with a prompt file you write, and `summarize --preset <name>` (or `--all-presets`) runs it over the transcript — one output file per preset. Give a preset a `when = "…"` description of the conversations it is for and `summarize --select-preset` picks the single preset that fits, which is what a session runs at the end of a call: a conversation has one type. Both tools take `--model` to override the configured model for a single run. The full option reference is in [`docs/configuration.md`](docs/configuration.md).

Transcription currently has one model: Parakeet, running locally on the Neural Engine via FluidAudio. A `[transcribe]` table arrives when there is more than one choice to make.

## Where things land

Published files go where you say. The destination is a path template with date, week, and title tokens, so transcripts file themselves into whatever tree you already keep:

```toml
[cleanup]
output = "~/obsidian/Transcripts/{year}/{month}/{day}/{date} - {title}.md"
```

A preset can go further — read the notes you jotted during the call, and write its output back over that same note:

```toml
[[summarize.preset]]
name = "meeting-notes"
prompt_file = "~/obsidian/prompts/meeting-notes.md"
notes = "~/obsidian/daily-notes/{year}/{month}/{week}/{date}/{date} - {title}.md"
out = "{notes}"
frontmatter = false     # the vault owns its own frontmatter
```

`{title}` is the meeting's real name — the browser extension reads it off the call, so a calendar meeting called "Kevin Weekly" files under that. Dates come from when the session started, so a call that runs past midnight still files under the day it began. Full token list in [`docs/configuration.md`](docs/configuration.md#path-templates).

## How it works

A single always-on daemon (`earsd`) owns the recording session lifecycle: it boots idle, records each session's sources into that session's own directory on disk (compressed, deleted shortly after the transcript lands), and nothing is transcribed until asked — except a browser call's session, which transcribes itself on end. Four small tools operate on that store and its output:

| Tool | Job |
|------|-----|
| `earsd` | Capture daemon: owns sessions, records their sources, exposes a control socket. |
| `ears` | Control client: status, sources, the session lifecycle. |
| `transcribe` | Turns a session's captured audio into a transcript, batch or live. |
| `cleanup` | Corrects a transcript with an LLM, guided by your vocabulary. |
| `summarize` | Produces summaries from a transcript using configurable prompts. |

Each is a separate binary sharing only the on-disk formats and the control socket. No tool depends on another running. See [`docs/overview.md`](docs/overview.md) for the full architecture, data formats, and configuration reference.

## Status

Active development. Capture and live transcription (mic, system audio, per-app, and browser-routed sources) are in daily use. The LLM cleanup/summary stages are in use; diarization is not built yet — see [current status](docs/overview.md#status). There is no signed, notarized build yet: build from source.

## Project layout

- [`daemon/`](daemon/): the Swift package holding `earsd`, `ears`, `transcribe`, `cleanup`, and `summarize`.
- [`browser/`](browser/): the Chrome/Firefox extension that routes meeting-tab audio to the daemon.
- [`docs/`](docs/): architecture, specs, configuration, and product docs.
