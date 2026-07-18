# Product Requirements

## Vision

Audio you hear or speak on your Mac should be recoverable as text without you having to decide, in advance, to record it. A background daemon always holds the recent past; you pull transcripts and summaries out of it on demand or on automatic triggers. The system is a set of small, composable, well-logged command-line tools rather than a single application, so any stage can be run alone, scripted, replaced, or debugged.

## Users

The primary user is a technical macOS user comfortable on the command line who wants:

- to recover what was just said in a conversation, call, or spoken thought without having hit "record" first;
- automatic, cleaned-up notes and summaries from meetings;
- local-first processing with explicit control over where audio and text live and which models run;
- composable tools they can wire into their own scripts, editors, and note systems.

## Use cases

### UC-1 — Retroactive capture (primary)

Something was just said that matters. The user runs a command to transcribe the last N minutes of a given source (or all sources) out of the ring buffer, and the transcript is saved. Because the daemon is always recording, the audio is already there; the only cost paid is transcription, on demand.

### UC-2 — Meeting notes (primary)

A meeting application starts producing/consuming audio. A **session** opens automatically, capturing the relevant sources (the user's mic and the meeting app's system audio as separate streams). When the app stops, the session closes and an auto-trigger transcribes it, cleans it up, diarizes it, and produces a summary — filed as a dated Markdown note.

### UC-3 — Browser-routed audio

A browser plugin captures audio from a tab (e.g. a web call or media the OS won't otherwise expose per-app) and pushes it into the daemon as a named source over the control socket. From that point it behaves like any other source: ring-buffered, VAD-indexed, transcribable.

### UC-4 — Live streaming transcript

During a session the user wants the transcript as it happens — for live captions or note-taking. The transcriber runs in streaming mode against a live source, emitting finalised segments to stdout, appending to the session's transcript file, and publishing to a socket feed that multiple consumers can subscribe to.

## Goals

- **G-1** Always-on, low-overhead background capture of multiple audio sources, kept separate per source.
- **G-2** A bounded, disk-backed ring buffer per source with a configurable time cap (default 2 hours), compressed.
- **G-3** On-demand and auto-triggered transcription of arbitrary time ranges and sessions, plus a real-time streaming mode.
- **G-4** A composable model interface, shipping with NVIDIA Parakeet as the first backend.
- **G-5** LLM-based cleanup (with known-word/context lists) and configurable summarisation.
- **G-6** Source-level speaker attribution plus full within-stream diarization.
- **G-7** Human-first Markdown output with structured frontmatter, to a configurable location.
- **G-8** High-quality structured logging in every tool from day one.
- **G-9** Low memory footprint, fast start, robust process/memory management, native macOS APIs.

## Non-goals (v1)

- No text-to-speech, voice cloning, or audio generation. This is capture-and-transcribe only.
- No GUI, menu-bar app, or browser-plugin UI in the core suite. The socket feed and file outputs are designed to *support* such front-ends later; they are not in scope here.
- No cloud sync, multi-device, or hosted service. Everything is local; the only network calls are to whichever LLM the user configures.
- No non-macOS support. The suite targets Apple Silicon macOS and uses native APIs directly.
- No general-purpose audio editing or playback tooling beyond what the pipeline needs.

## Success criteria

- **Capture reliability:** with the daemon running, any moment within a source's time-cap window is recoverable as audio and transcribable. Measured by: no gaps in the ring buffer index during a running daemon outside of explicit pauses.
- **Footprint:** the idle daemon holds a low, stable resident memory footprint and negligible CPU when sources are silent (VAD-gated work only). Concrete budgets are set in the [capture-daemon spec](./specs/capture-daemon.md).
- **Composability:** every stage runs standalone from the command line against files on disk, with no dependency on any other tool being running (except that live capture requires the daemon). A transcript can be produced from ring-buffer audio using only `transcribe`.
- **Retroactive latency:** transcribing the last few minutes of a source completes in well under real time on Apple Silicon using the Parakeet backend.
- **Debuggability:** every tool emits structured logs sufficient to reconstruct what it did, why, and how long each stage took, without code changes.
- **Zero-config start:** installing the suite and starting the daemon captures the microphone with sensible defaults and no configuration file.

## Constraints and principles

- **One job per tool.** If a tool grows a second responsibility, it should become two tools.
- **Disk is the API.** Tools communicate results through the documented on-disk layout, not through each other. The daemon owns writes to the ring buffer; every other tool reads files directly.
- **Fail loud, log always.** Tools surface errors clearly and never silently degrade. Every run is traceable through logs.
- **Local and explicit.** Data locations, models, and any network egress (LLM calls) are user-configured and visible.
- **Composable models.** ASR and LLM backends are interfaces, not hard dependencies.
