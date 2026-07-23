# Overview

All Ears is a suite of small macOS command-line tools that continuously capture audio in the background and turn it into clean, summarised text — on demand, or automatically when a meeting ends. For the pitch and quick start, see the [top-level README](../README.md).

The design follows the Unix philosophy: each tool does one job, tools compose through a documented on-disk layout and a control socket, and every stage runs, tests, and gets replaced independently.

## The tools

| Tool | One job |
|------|---------|
| `earsd` | Capture daemon: record each meeting's sources under the meeting's own directory, maintain the VAD index, expose the control socket. |
| `ears` | Control client: status, sources, sessions, marking ranges, watching the live feed. |
| `transcribe` | Turn captured audio for a meeting or session into a transcript, batch or live. |
| `cleanup` | Correct a transcript with an LLM, guided by your vocabulary list. |
| `summarize` | Produce summaries from transcripts using configurable prompt presets. |

Each is a separate binary. They share nothing but the [data formats](./data-formats.md) on disk and the control socket.

## How it works

`earsd` runs in the background and records only while a meeting is active. When one starts, it captures the meeting's sources — microphone, system audio, a single app's audio, or per-participant meeting audio pushed in by the [browser extension](./browser-extension.md) — into that meeting's own directory on disk, compressed. A cheap voice-activity detector runs alongside and writes speech/silence spans to an index. Once the meeting's transcript lands, the audio is deleted a couple of hours later (7 days if transcription failed, so it can be retried); the transcript is the durable artifact.

Two use cases drive everything:

- **Retroactive capture.** "That conversation 20 minutes ago — keep it." The audio is already in the buffer; `transcribe --last 20m` pulls it out.
- **Meeting notes.** A configured meeting app starts producing audio, a session opens automatically, and when it ends the trigger runs `transcribe → cleanup → summarize` and files a dated Markdown note with no manual step.

Sources are kept **separate end to end** — separate buffers, separate indices, separate transcripts merged only at output. Your mic and the meeting's audio never mix, which is what gives you-vs-them speaker attribution for free, and per-participant browser sources extend that to real names on Google Meet.

A **session** is a named time range over one or more sources — metadata, not a separate recording. Sessions open and close by trigger or by hand (`ears session open`, `ears mark --last 30m` for ranges you didn't think to mark at the time). Browser-detected meetings additionally get a stable daemon-issued meeting id, so rejoining the same call correlates across sessions.

## Principles

- **One job per tool.** If a tool grows a second responsibility, it becomes two tools.
- **Disk is the API.** Tools communicate through the documented on-disk layout, never through each other. The daemon owns writes to the audio store; everything else reads files directly, so `ls`, `jq`, and `tail -f` are first-class debugging tools and a daemon crash never makes captured audio unreadable.
- **Local and explicit.** Audio and transcripts stay on your Mac. The only network calls are to whichever LLM you configure for cleanup and summaries.
- **Fail loud, log always.** Non-zero exits, precise errors, structured logs sufficient to reconstruct every run.
- **Zero-config start.** With no config file, the daemon captures the mic with sensible defaults.

## Status

Built and in use:

- Capture: mic, system audio, per-app audio (Core Audio process taps), and browser-pushed per-participant audio; dual-rate storage; time-cap and total-size eviction; sleep/wake and restart gap recording.
- Sessions, retroactive marking, app-signal auto-triggers with an `on_close` pipeline, and meeting identity for browser calls.
- Transcription: batch and live (`--follow`) via Parakeet/FluidAudio on the Apple Neural Engine, with VAD silence-skipping and natural-pause segmentation.
- LLM cleanup (with validation guardrails) and preset-based summaries via a subprocess backend (the `llm` CLI by default).
- Browser extension: per-participant capture and real-name identity on Google Meet, Zoom web; `Speaker N` attribution on Teams.

Not built yet:

- Within-stream diarization (`Speaker N` labels inside a multi-speaker source). Labels currently come from the source alone: `mic` → `You`, other sources → the source id.
- Vocabulary biasing at the ASR decoder — vocabulary currently applies at `cleanup` only.
- [Control protocol v2](./specs/control-protocol.md) (daemon-owned meeting lifecycle, correlated requests, snapshot-on-subscribe).
- A configurable VAD backend (an energy-threshold VAD is always used) and a configurable ASR backend (Parakeet/FluidAudio is fixed).
- Signed, notarized builds and automatic launchd registration — build from source, see [distribution](./distribution.md).
- Live-verified Firefox support for the extension (it builds; the Meet capture path needs a Firefox-specific investigation).
