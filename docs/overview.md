# Overview

All Ears is a suite of small macOS command-line tools that capture a session's audio in the background and turn it into clean, summarised text — on demand, or automatically when a browser call ends. For the pitch and quick start, see the [top-level README](../README.md).

The design follows the Unix philosophy: each tool does one job, tools compose through a documented on-disk layout and a control socket, and every stage runs, tests, and gets replaced independently.

## The tools

| Tool | One job |
|------|---------|
| `earsd` | Capture daemon: own the session lifecycle, record each session's sources under the session's own directory, maintain the VAD index, expose the control socket. |
| `ears` | Control client: status, sources, the session lifecycle, watching the live feed. |
| `transcribe` | Turn captured audio for a session (or a raw time range) into a transcript, batch or live. |
| `cleanup` | Correct a transcript with an LLM, guided by your vocabulary list. |
| `summarize` | Produce summaries from transcripts using configurable prompt presets. |

Each is a separate binary. They share nothing but the [data formats](./data-formats.md) on disk and the control socket.

## How it works

`earsd` runs in the background and records only while a session is active. When one starts, it captures the session's sources — microphone, system audio, a single app's audio, or per-participant call audio pushed in by the [browser extension](./browser-extension.md) — into that session's own directory on disk, compressed. A cheap voice-activity detector runs alongside and writes speech/silence spans to an index. Once the session's transcript lands, the audio is deleted a couple of hours later (7 days if transcription failed, so it can be retried); the transcript is the durable artifact.

Artifacts come in two tiers. The **raw transcript** is an intermediate: it stays in the session's own directory in the data store, addressed by session id, with no user-facing layout — and it is never swept, because once the audio is gone it is the only way to re-run the LLM stages with a different prompt or model. The **cleaned transcript and summaries** are what get published, to a path you configure with a template: date and week folders, the meeting's real name in the filename, an Obsidian daily note, whatever fits your setup. See [configuration](./configuration.md#path-templates).

Two use cases drive everything:

- **Meeting notes, hands-free.** The browser extension detects a call starting in a tab, declares a session, and streams each participant's audio in; when the call ends, the daemon transcribes the session automatically and files a dated Markdown note with no manual step.
- **Deliberate recording.** `ears session start --source mic` before a conversation, `ears session end` after — the session is transcribed as a unit, with a title, pause marks, and a roster.

The CLI is session-first: bare `ears` is a dashboard of the live session and the last few pipeline outcomes, `ears sessions` lists recent sessions one line each, and `ears session show <ref>` walks one session's pipeline — capture → transcribe → cleanup → summarize → note — reconstructed from disk, so "did my 2pm call make it into a note?" is one command.

Sources are kept **separate end to end** — separate buffers, separate indices, separate transcripts merged only at output. Your mic and the call's audio never mix, which is what gives you-vs-them speaker attribution for free, and per-participant browser sources extend that to real names on Google Meet.

A **session** is the one lifecycle entity: a daemon-owned record (UUID, title, state, pause/resume marks, attendee roster) whose lifetime bounds capture. Browser-detected calls carry the platform's own meeting id as the session's identity, which makes the extension's `session.start` idempotent — a flaky service worker re-declares instead of duplicating.

## Principles

- **One job per tool.** If a tool grows a second responsibility, it becomes two tools.
- **Disk is the API.** Tools communicate through the documented on-disk layout, never through each other. The daemon owns writes to the audio store; everything else reads files directly, so `ls`, `jq`, and `tail -f` are first-class debugging tools and a daemon crash never makes captured audio unreadable.
- **Local and explicit.** Audio and transcripts stay on your Mac. The only network calls are to whichever LLM you configure for cleanup and summaries.
- **Fail loud, log always.** Non-zero exits, precise errors, structured logs sufficient to reconstruct every run.
- **Zero-config start.** With no config file, the daemon captures the mic with sensible defaults.

## Status

Built and in use:

- Capture: mic, system audio, per-app audio (Core Audio process taps), and browser-pushed per-participant audio; dual-rate storage; transcript-driven retention; sleep/wake and restart gap recording.
- The daemon-owned session lifecycle ([control protocol v2](./specs/control-protocol.md)): idempotent start, pause/resume marks, attendee roster, orphan grace, and the session-end pipeline (transcribe → cleanup → summarize) for browser calls.
- Transcription: batch and live (`--follow`) via Parakeet/FluidAudio on the Apple Neural Engine, with VAD silence-skipping and natural-pause segmentation.
- LLM cleanup (with validation guardrails) and preset-based summaries via a subprocess backend (the `llm` CLI by default).
- Browser extension: per-participant capture and real-name identity on Google Meet, Zoom web, and Jitsi Meet (Jitsi not yet live-verified); `Speaker N` attribution on Teams.

Not built yet:

- Within-stream diarization (`Speaker N` labels inside a multi-speaker source). Labels currently come from the source alone: `mic` → `You`, other sources → the source id.
- Vocabulary biasing at the ASR decoder — vocabulary currently applies at `cleanup` only.
- A configurable VAD backend (an energy-threshold VAD is always used) and a configurable ASR backend (Parakeet/FluidAudio is fixed).
- Signed, notarized builds and automatic launchd registration — build from source, see [distribution](./distribution.md).
- Live-verified Firefox support for the extension (it builds; the Meet capture path needs a Firefox-specific investigation).
