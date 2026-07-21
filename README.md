<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/brand/logo-horizontal-reversed.svg">
  <img src="docs/brand/logo-horizontal.svg" alt="All Ears" width="320">
</picture>

Local. Composable. Split by source (instead of untangled later).

All Ears runs a small daemon that continuously records every audio source you configure (microphone, system audio, per-app audio, meeting-tab audio) into a rolling local buffer. It transcribes, cleans up, and summarises on demand or automatically when a meeting ends.

## Why All Ears

- **Small tools, not one app.** Capture, transcription, cleanup, and summarisation are separate command-line tools that read and write plain files, instead of one inscrutable binary. Script them, replace one, extend them.
- **Knows who said what, by name, on Google Meet.** The browser extension isolates each remote participant's audio into its own stream and reads their real display name straight off the call UI, without manual labelling or voice-print guessing. Zoom gets the same per-participant separation from the call's own tracks. Teams gets attributed `Speaker N` streams instead.
- **Sources are separated before transcription, not after.** Mic, system audio, each app, and each meeting participant are captured as distinct streams from the start. Transcription and diarization run on a clean single-speaker signal instead of untangling a blended recording after the fact, so accuracy and speaker attribution are both better for it.
- **Local-first.** Audio and transcripts stay on disk on your Mac. The only network calls are to whichever LLM you configure for cleanup and summaries.
- **Retroactive capture.** The daemon is always recording into a bounded local buffer (2 hours by default). Realise ten minutes in that you should've been taking notes? The audio is already there. Just ask for a transcript of the last 30 minutes.

## Install

Requires Apple Silicon, macOS 15+, and [Swift 6](https://www.swift.org/install/).

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
  output → `~/Library/Logs/ears/`. Your config, recordings, and transcripts live
  under `~/.config/ears`, `~/Library/Application Support/ears`, and
  `~/Documents/Transcripts` respectively.
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

**Retroactive capture.** Something worth keeping just happened:

```sh
transcribe --last 20m --source mic --out standup.transcript.md
```

**Full pipeline.** Transcribe, correct, and summarise:

```sh
transcribe --last 45m --source mic --out call.transcript.md
cleanup call.transcript.md --out call.clean.md
summarize call.clean.md --preset action-items --out call.summary.md
```

**Meeting notes, hands-free.** Open a session around a call so it's transcribed as a unit instead of a raw time range:

```sh
ears session open --slug weekly-sync --source mic --source browser:meet
# ... take the call ...
ears session close <session-id>
transcribe --session <session-id> --out weekly-sync.md
```

**Retroactively mark a range** you didn't think to open a session for:

```sh
ears mark --last 30m --slug hallway-conversation --source mic
```

**Live transcript** while a source is running:

```sh
transcribe --follow mic
```

**Browser-captured meeting audio.** The [browser extension](browser/) isolates each remote participant's audio in Google Meet, Zoom, and Teams tabs and streams it to the daemon as its own source. Install it once, join a call, and it shows up as `browser:<platform>:<participant>` alongside your other sources.

## How it works

A single always-on daemon (`earsd`) owns every audio source and writes it into a per-source ring buffer on disk: compressed, time-capped, and nothing is transcribed until asked. Four small tools operate on that buffer and its output:

| Tool | Job |
|------|-----|
| `earsd` | Capture daemon: records every source, exposes a control socket. |
| `ears` | Control client: status, sources, sessions, marking ranges. |
| `transcribe` | Turns ring-buffer audio into a transcript, batch or live. |
| `cleanup` | Corrects a transcript with an LLM, guided by your vocabulary. |
| `summarize` | Produces summaries from a transcript using configurable prompts. |

Each is a separate binary sharing only the on-disk formats and the control socket. No tool depends on another running. See [`docs/overview.md`](docs/overview.md) for the full architecture, data formats, and configuration reference.

## Status

Active development. Retroactive capture and transcription (mic, system audio, per-app, and browser-routed sources) are in daily use. The LLM cleanup/summary stages are in use; diarization is not built yet — see [current status](docs/overview.md#status). There is no signed, notarized build yet: build from source.

## Project layout

- [`daemon/`](daemon/): the Swift package holding `earsd`, `ears`, `transcribe`, `cleanup`, and `summarize`.
- [`browser/`](browser/): the Chrome/Firefox extension that routes meeting-tab audio to the daemon.
- [`docs/`](docs/): architecture, specs, configuration, and product docs.
