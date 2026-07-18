# Logging

High-quality logging is a day-one requirement, not an afterthought. Every tool must emit logs sufficient to reconstruct what it did, why, and how long each stage took — without code changes or a rebuild.

## Standard

Logs are **machine-first**. The primary sink is **structured JSON Lines** — one JSON object per event, written to a file (and to stderr when attached to a non-TTY). This is the source of truth: greppable with `jq`, aggregatable, portable, and stable across macOS versions. Every event is a typed record with a machine-readable `event` name and structured fields, never a prose string that has to be parsed.

Alongside it, the same events are mirrored into **Apple unified logging** (`os.Logger` / `OSLog`) as a convenience for native tooling — Console.app, `log stream`/`log show`, and `os_signpost` performance intervals in Instruments. Unified logging is a secondary view; the JSON stream is authoritative. If the two ever disagree (e.g. os_log coalescing under load), the JSON file wins.

A human-readable pretty renderer is available for interactive use (`--log-format=pretty` or automatically on a TTY), but it is a rendering of the JSON records, not a separate format.

> Why this way: the brief calls for logging that enables debugging, monitoring, and improvement — all of which mean consuming logs programmatically (grep, `jq`, ship to a collector, diff runs). A binary, macOS-only store can't be the foundation for that, so JSON Lines is primary. Unified logging still earns its place for live tailing and Instruments signposts, so we emit both from one call site.

## Output sinks

Every tool writes structured JSON to, in order of precedence:

1. `--log-file <path>` flag,
2. `EARS_LOG__FILE` env,
3. `[log].file` in config,
4. default `<data-root>/logs/<tool>.jsonl` (rotated).

When stderr is **not** a TTY (piped, under launchd), JSON is also written to stderr so a supervisor captures it. When stderr **is** a TTY, stderr gets the pretty rendering instead and the JSON file still receives full records. The unified-logging mirror is always emitted unless `[log].oslog = false`.

Log files rotate by size/age (configurable); rotation is itself logged (`event: "log.rotated"`).

## Subsystem and categories

For the unified-logging mirror:

- **Subsystem:** one per suite, default `net.tomelliot.ears` (configurable).
- **Category:** the tool/component name — `earsd`, `earsd.vad`, `earsd.socket`, `transcribe`, `cleanup`, `summarize`, `trigger`.

The same values appear as `subsystem`/`category` fields in the JSON records, so filters translate directly between `jq` and `log show --predicate`.

## Levels

| Level  | Use |
|--------|-----|
| `debug`  | Verbose developer detail (frame counts, per-chunk writes). Off in normal runs. |
| `info`   | Normal operational events (source opened, chunk written, session closed). |
| `notice` | Noteworthy but expected (eviction, coarse VAD state, config loaded). |
| `error`  | Failures. Always paired with actionable context and a non-zero exit for one-shot tools. |

Each JSON record carries `level`; the mirror maps it to the matching `OSLogType`. Configured via `[log].level`; overridable with `--log-level` and `EARS_LOG__LEVEL`.

## Record schema

Every line is one JSON object. Baseline fields present on all records:

| Field | Meaning |
|-------|---------|
| `ts` | ISO-8601 UTC timestamp with millisecond precision. |
| `level` | `debug` \| `info` \| `notice` \| `error`. |
| `tool` | Emitting binary (`earsd`, `transcribe`, …). |
| `subsystem`, `category` | Mirror of the unified-logging identifiers. |
| `pid` | Process id. |
| `event` | Stable machine-readable event name (e.g. `chunk.written`, `session.closed`, `stage.start`, `stage.end`, `log.rotated`). |
| `msg` | Optional short human string; never the sole carrier of information — everything actionable is also a field. |

Context fields added where relevant: `source`, `session`, `span_id`, and for bounded operations a `stage.start`/`stage.end` pair sharing a `span_id` with `duration_ms` (and metrics like `rtf`) on the end record.

The `event` namespace is a documented, stable vocabulary — consumers key off `event`, not off `msg`. New events are additive; renames are schema-versioned.

```jsonc
{"ts":"2026-07-17T10:30:00.012Z","level":"info","tool":"earsd","subsystem":"net.tomelliot.ears","category":"earsd","pid":4120,"event":"source.opened","source":"mic","sample_rate":16000,"codec":"aac"}
{"ts":"2026-07-17T10:30:30.004Z","level":"info","tool":"earsd","category":"earsd","pid":4120,"event":"chunk.written","source":"mic","file":"chunks/2026-07-17T10-30-00Z.m4a","frames":480000}
{"ts":"2026-07-17T10:31:12.881Z","level":"error","tool":"earsd","category":"earsd","pid":4120,"event":"device.lost","source":"mic","reason":"default input changed","action":"reopening","msg":"mic device lost, reopening"}
{"ts":"2026-07-17T11:02:14.220Z","level":"info","tool":"transcribe","category":"transcribe","pid":5330,"event":"stage.end","session":"...standup","span_id":"a1","stage":"asr","duration_ms":8140,"rtf":0.11}
```

## Performance signposts

Wrap expensive stages (ASR decode, diarization, LLM calls, encode/flush) in `os_signpost` intervals so they appear in Instruments and `log show` timelines. Each interval also emits the `stage.start`/`stage.end` JSON records above, so timing is fully available from the JSON stream alone — Instruments is an optional convenience, not a requirement for measurement.

## Requirements per tool

- Log **startup**: resolved config path, effective log level, version, key parameters.
- Log **every state transition** and external interaction (device open, socket connect, file write, model load, LLM request/response with token counts and latency — never prompt/response bodies unless `debug`).
- Log **errors with cause and the action taken** (retry, reopen, abort). No silent catches.
- One-shot tools emit a final `run.summary` record (counts, durations, output paths) and exit non-zero on any error.
- Never log audio content or full transcript/LLM bodies above `debug`. Metadata and counts only, so logs stay shareable.
- Anything actionable lives in a **field**, so no consumer ever has to regex `msg`.

## Consuming logs

```sh
# live tail of the daemon, machine-first
tail -f ~/Library/Application\ Support/ears/logs/earsd.jsonl | jq 'select(.level=="error")'

# every ASR stage timing across a day
jq 'select(.event=="stage.end" and .stage=="asr") | {ts, session, duration_ms, rtf}' logs/transcribe.jsonl

# ship to a collector
tail -F logs/*.jsonl | your-log-shipper

# the unified-logging mirror, for live native tooling / Instruments
log stream --predicate 'subsystem == "net.tomelliot.ears" && category == "earsd"' --level debug
```
