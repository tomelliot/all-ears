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
Turn a raw transcript into a clean, readable one, correcting mis-transcriptions and formatting with an LLM, guided by the known-word list.

### Behaviour
1. Read a `.transcript.md`.
2. Build the prompt: the built-in cleanup prompt (or `[cleanup].prompt_file`), plus the merged vocabulary (global + session) as an explicit correction list.
3. Correct homophones/mis-hearings against the vocabulary and fix punctuation/casing, **without** altering meaning, timestamps, or speaker turns.
4. Write `<...>.clean.md` atomically, frontmatter `kind: clean` with `derived_from` naming the source transcript.

### Guardrails
Cleanup must improve readability without hallucinating or over-editing:

- **Accept/fallback validation:** if a cleaned segment diverges from the source beyond bounds (length ratio, structural drift), reject it and keep the original rather than shipping a hallucination.
- **Minimal-change prompting:** the smallest edit that fixes errors; filler words are kept unless removal is configured.
- Timestamps and segment/turn structure are preserved; cleanup never invents or drops turns. Frontmatter records model + settings for reproducibility.

### CLI
```
cleanup <transcript.md> [--out <clean.md>] [--prompt <file>] [--vocab <path>] [--model <name>] [--no-vocab]
```

## `summarize`

### One job
Produce one or more summaries of one or more transcripts from configurable prompt presets.

### Behaviour
1. Read one or more transcripts (cleaned preferred if both exist).
2. For each selected preset (`[[summarize.preset]]`), run its prompt over the transcript(s).
3. Write `<...>.summary.md` (or `<...>.<preset>.summary.md` when multiple), frontmatter `kind: summary` with `preset` and `derived_from`.

Presets are named prompt files, so summary styles (brief, decisions, action items) are user configuration, not code.

### CLI
```
summarize <transcript.md> [more...] [--preset brief] [--preset actions] [--all-presets] [--out <path>] [--model <name>]
```

## Composition

The stages chain but never depend on each other at runtime — each reads and writes files:

```sh
transcribe --session "$SID" \
  && cleanup "$OUT/…standup.transcript.md" \
  && summarize "$OUT/…standup.clean.md" --preset brief --preset actions
```

A trigger's `on_close` list is exactly this chain expressed as config. Any stage can be run alone against an existing file.
