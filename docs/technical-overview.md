# Technical overview

All Ears is a macOS-native suite of small, composable command-line tools that continuously capture audio in the background and turn it into clean, summarised, searchable text. For the product pitch and everyday usage, see the [top-level README](../README.md).

The design follows the Unix philosophy: each tool does one thing well, tools compose through a documented on-disk layout and a control socket, and every stage is independently runnable, testable, and replaceable.

## How it works

A background daemon (`earsd`) captures audio from every configured source (microphone, system audio, per-application audio, and audio pushed in from the browser plugin) into a per-source **ring buffer** on disk, keeping the last 2 hours by default, compressed. Nothing is transcribed until asked. Separate tools then, on demand or on an automatic trigger, transcribe a time range or session, clean the transcript with an LLM, and summarise it. Output is human-first Markdown with YAML frontmatter, filed wherever you configure.

Two primary use cases drive the design:

- **Retroactive capture.** "That thing from 20 minutes ago: transcribe and keep it." The ring buffer is the safety net; transcription is pulled on demand.
- **Meeting notes.** A meeting app starts, a session opens automatically, and when it ends you get a cleaned, diarized, summarised transcript.

## The tools

| Tool | One job |
|------|---------|
| `earsd` | Capture daemon: record all sources into their ring buffers, maintain the VAD index, expose a control socket. |
| `ears` | Control client: query the daemon, manage sources and sessions, push audio in (browser plugin), mark ranges. |
| `transcribe` | Read audio for a time range or session from the ring buffer and produce a transcript (batch or streaming). |
| `cleanup` | Correct and format a transcript with an LLM, using the known-word list and context. |
| `summarize` | Produce one or more summaries of transcript(s) from configurable prompts. |

Each is a separate binary. They share nothing but the documented [data formats](./data-formats.md) and the control socket.

## Documents

- [Product Requirements (PRD)](./product/prd.md): vision, users, use cases, scope, non-goals, success criteria.
- [Architecture](./architecture.md): system decomposition, the disk-as-API contract, the control socket, data flow.
- [Data formats](./data-formats.md): ring buffer layout, transcript & summary schemas, vocabulary and session files.
- [Configuration](./configuration.md): the layered TOML + env + flags model.
- [Logging](./logging.md): the unified-logging standard every tool follows.
- [Engineering practices](./engineering-practices.md): mandatory TDD and small-incremental-commit discipline, test tiers, CI.
- [Distribution & packaging](./distribution.md): Developer ID + notarization, the launchd agent, model assets.
- [Capture soak-test runbook](./operations/capture-soak-runbook.md): the manual, multi-day procedure for checking the Phase 1 exit criterion no automated test can prove.
- [Brand guidelines](./brand-guidelines.html) and [brand assets](./brand/): logomark, logo lockups, colour, type.
- Specs:
  - [`earsd` + `ears`, capture daemon](./product/specs/capture-daemon.md)
  - [`transcribe`, transcription](./product/specs/transcribe.md)
  - [`cleanup` + `summarize`, LLM stages](./product/specs/llm-stages.md)
  - [Model interface](./product/specs/model-interface.md)
  - [Browser extension PRD](./product/browser/prd.md), [design brief](./product/browser/design-brief.md), [roadmap](./product/browser/roadmap.md)
- [Roadmap](./product/roadmap.md): phasing from MVP to full pipeline.

## Foundational decisions

These are settled and constrain everything downstream:

- **Language:** Swift. First-class Core Audio / AVAudioEngine / Core ML access, native binaries with a low memory footprint and fast start, and a Parakeet path via FluidAudio on the Apple Neural Engine / Metal.
- **Composition:** the ring buffer's on-disk layout *is* the read API. The daemon is never in the read path. It exposes a Unix domain socket for control and for audio ingestion only.
- **Storage:** per-source ring buffer, compressed, bounded by a configurable **time cap** (default 2 hours), stored **dual-rate** (a native-rate listenable copy plus the derived 16 kHz ASR feed). Record everything; a cheap VAD runs alongside and writes speech/silence markers to an index.
- **Runtime:** headless, **actor-based**, no `@MainActor` in the core; a lock-free RAM jitter ring feeds the disk ring, with generation-counter-guarded teardown for device hot-swaps.
- **Trigger model:** the daemon only records. Transcription runs on demand and via auto-triggers (app-signal sessions), with a real-time streaming mode.
- **Speakers:** source-level attribution (you vs. them, per app) for free from the architecture, plus full diarization within a stream.
- **LLM:** the `llm` CLI is the default backend for cleanup and summarisation; the stage is defined as an interface so a native SDK backend can be added later.
- **Config:** layered TOML file → environment → CLI flags, with zero-config defaults.
- **Logging:** machine-first structured JSON Lines as the source of truth (greppable, aggregatable, portable), mirrored into Apple unified logging (`os.Logger`) for native tooling and Instruments signposts.
