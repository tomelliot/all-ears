# Spec: `cleanup` + `summarize` (LLM stages)

Two separate tools, each one job, both built on a shared LLM backend interface.

## Shared LLM backend

- Default backend: the **`llm` CLI** (`backend = "llm-cli"`), model chosen via `[llm].model` and passed as `llm -m <model>`. This gives model selection, key management, and local-model support for free and matches the composable-CLI philosophy.
- The stage is defined as an **interface** so alternatives slot in without touching the tools:
  - `command` — any shell command taking the prompt on stdin and returning the completion on stdout.
  - `anthropic-sdk` — a future native backend for tighter control (streaming, caching, retries).
- The backend is responsible only for prompt-in → completion-out. Prompt construction, chunking, and output writing belong to the tools.
- Logging: request/response metadata only (model, token counts, latency, retries) — never prompt/response bodies above `debug`. Failures are loud and non-zero.
- Long transcripts are chunked with overlap; the tool stitches results. Chunking parameters are configurable and logged.
- **Split a stable prompt prefix from the dynamic input** (system prompt + vocabulary + instructions as the prefix; the transcript as the suffix) so a caching backend can reuse the KV-cache/prompt cache across chunks and runs.
- For a local model, running it as a **JSON-over-stdio sidecar subprocess** (a `command` backend) keeps the integration composable and language-agnostic, consistent with the [subprocess discipline](./model-interface.md#backend-2--subprocess-adapter) (stdout=JSON, stderr=logs, drain-before-wait, supervised).

## `cleanup`

### One job
Turn a raw transcript into a clean, readable one using an LLM, correcting mis-transcriptions and formatting, guided by the known-word list and context.

### Behaviour
1. Read a `.transcript.md` (+ sidecar if present).
2. Build the cleanup prompt: the built-in prompt (or `[cleanup].prompt_file`), plus the merged vocabulary (global + session) as an explicit correction list, plus any session context.
3. Correct homophones/mis-hearings against the vocabulary, fix punctuation/casing, remove filler where configured, **without** altering meaning, timestamps, or speaker turns.
4. Optionally apply a speaker name map (`Speaker 2` → real name) if present in the session.
5. Write `<...>.clean.md` atomically, with frontmatter `kind: clean` and `derived_from` pointing at the source transcript.

### Refinement guardrails
Cleanup must improve readability without hallucinating or over-editing. The corpus's validated guardrails (Detto's `RefinementValidator` and peers):

- **Accept/fallback validator:** if the cleaned output diverges from the source beyond a bound (length ratio, entity drift), reject it and keep the original segment rather than shipping a hallucination.
- **Skip high-confidence utterances:** don't send already-clean, high-ASR-confidence text to the LLM at all — saves cost and avoids needless drift.
- **Minimal-change prompt:** instruct for the smallest edit that fixes errors; **keep filler words** unless removal is explicitly configured.

### Guarantees
- Timestamps and segment/turn structure are preserved; cleanup never invents or drops turns.
- Deterministic-enough: same input + same model/settings yields stable structure (frontmatter records model + settings for reproducibility).

### CLI
```
cleanup <transcript.md> [--out <clean.md>] [--prompt <file>] [--vocab <name|path>] [--model <name>] [--no-vocab]
```

## `summarize`

### One job
Produce one or more summaries of one or more transcripts from configurable prompts.

### Behaviour
1. Read one or more transcripts (raw or cleaned; cleaned preferred if both exist).
2. For each selected **preset** (`[[summarize.preset]]` — e.g. `brief`, `actions`), run its prompt over the transcript(s).
3. Write `<...>.summary.md` (or `<...>.<preset>.summary.md` when multiple), frontmatter `kind: summary`, `preset`, and `derived_from`.

Presets are named prompt files, so summary styles (brief, decisions, action items, per-speaker) are user-defined config, not code.

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

A trigger's `on_close` list is exactly this chain expressed as config. Any stage can also be run alone against an existing file.
