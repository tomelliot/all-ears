# Docs

Two kinds of documents live here. Pick by what you're doing:

**Using All Ears** — how the system works and how to drive it:

- [Overview](./overview.md) — what the pieces are, how audio becomes notes, current status.
- [Configuration](./configuration.md) — the config file, environment variables, and flags.
- [Data formats](./data-formats.md) — the on-disk layout: ring buffer, index, sessions, transcripts. This is the contract your own scripts can rely on.
- [Logging](./logging.md) — where logs go and how to consume them.
- [Browser extension](./browser-extension.md) — per-participant meeting capture from Chrome/Firefox.
- [Capture soak-test runbook](./operations/capture-soak-runbook.md) — the manual multi-day procedure for validating capture reliability on real hardware.

**Implementation specs** — what each component must do, for anyone changing the code:

- [Architecture](./architecture.md) — system decomposition, the disk-as-API contract, concurrency model, module structure.
- [`earsd` + `ears`](./specs/capture-daemon.md) — the capture daemon and control client, including the control socket protocol as built.
- [`transcribe`](./specs/transcribe.md) — batch and streaming transcription.
- [`cleanup` + `summarize`](./specs/llm-stages.md) — the LLM stages.
- [Model interface](./specs/model-interface.md) — the ASR/diarization backend protocols.
- [Control protocol v2](./specs/control-protocol.md) — the redesigned daemon/frontend contract. **Designed, not yet implemented.**
- [Browser extension internals](./specs/browser/extension.md) and [ingest transport](./specs/browser/transport.md).
- [Engineering practices](./engineering-practices.md) — TDD, test tiers, commit discipline.
- [Distribution](./distribution.md) — how the suite is (and will be) packaged.

Brand assets live in [`brand/`](./brand/), with usage rules in [`brand-guidelines.html`](./brand-guidelines.html).

When code and a doc disagree, that's a bug in one of them — fix it, don't let it stand.
