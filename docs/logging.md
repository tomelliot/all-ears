# Logging

Every tool must emit logs sufficient to reconstruct what it did, why, and how long each stage took — without code changes or a rebuild.

## Standard

Logs are **machine-first**. The primary sink is **structured JSON Lines** — one JSON object per event, written to a file. Every event is a typed record with a machine-readable `event` name and structured fields, never a prose string that has to be parsed.

The same events are mirrored into **Apple unified logging** (`os.Logger`) as a convenience for Console.app, `log stream`, and Instruments signposts. The JSON stream is authoritative; if the two disagree (e.g. os_log coalescing under load), the JSON file wins.

A human-readable pretty renderer is used for interactive runs (`--log-format=pretty`, or automatically on a TTY). It is a rendering of the JSON records, not a separate format.

## Output sinks

Every tool writes structured JSON to, in order of precedence:

1. `--log-file <path>` flag,
2. `EARS_LOG__FILE` env,
3. `[log].file` in config,
4. default `<data-root>/logs/<tool>.jsonl` (rotated).

When stderr is not a TTY (piped, under launchd), JSON is also written to stderr so a supervisor captures it; on a TTY, stderr gets the pretty rendering instead. The unified-logging mirror is emitted unless `[log].oslog = false`.

Log files rotate by size (`rotate_max_bytes` / `rotate_max_files`); rotation is itself logged (`event: "log.rotated"`).

## Subsystem and categories

- **Subsystem:** `net.tomelliot.ears` (configurable).
- **Category:** the tool/component name — `earsd`, `earsd.vad`, `earsd.socket`, `transcribe`, `cleanup`, `summarize`.

The same values appear as `subsystem`/`category` fields in the JSON records, so filters translate directly between `jq` and `log show --predicate`.

## Levels

| Level  | Use |
|--------|-----|
| `debug`  | Verbose developer detail (frame counts, per-chunk writes). Off in normal runs. |
| `info`   | Normal operational events (source opened, chunk written, session closed). |
| `notice` | Noteworthy but expected (eviction, coarse VAD state, config loaded). |
| `error`  | Failures. Always paired with actionable context and a non-zero exit for one-shot tools. |

Configured via `[log].level`; overridable with `--log-level` and `EARS_LOG__LEVEL`.

## Record schema

Baseline fields on every record:

| Field | Meaning |
|-------|---------|
| `ts` | ISO-8601 UTC timestamp, millisecond precision. |
| `level` | `debug` \| `info` \| `notice` \| `error`. |
| `tool` | Emitting binary. |
| `subsystem`, `category` | Mirror of the unified-logging identifiers. |
| `pid` | Process id. |
| `event` | Stable machine-readable event name (e.g. `chunk.written`, `session.closed`, `stage.start`, `stage.end`). |
| `msg` | Optional short human string; never the sole carrier of information. |

Context fields are added where relevant: `source`, `session`, `span_id`, and for bounded operations a `stage.start`/`stage.end` pair sharing a `span_id`, with `duration_ms` (and metrics like `rtf`) on the end record.

Consumers key off `event`, never off `msg`. New events are additive.

```jsonc
{"ts":"2026-07-17T10:30:00.012Z","level":"info","tool":"earsd","subsystem":"net.tomelliot.ears","category":"earsd","pid":4120,"event":"source.opened","source":"mic","sample_rate":16000,"codec":"aac"}
{"ts":"2026-07-17T11:02:14.220Z","level":"info","tool":"transcribe","category":"transcribe","pid":5330,"event":"stage.end","session":"...standup","span_id":"a1","stage":"asr","duration_ms":8140,"rtf":0.11}
```

Expensive stages (ASR decode, LLM calls, encode/flush) are additionally wrapped in `os_signpost` intervals so they appear in Instruments — but timing is always fully available from the JSON stream alone.

## Requirements per tool

- Log **startup**: resolved config path, effective log level, version, key parameters.
- Log **every state transition** and external interaction (device open, socket connect, file write, model load, LLM request/response with token counts and latency).
- Log **errors with cause and the action taken** (retry, reopen, abort). No silent catches.
- One-shot tools emit a final `run.summary` record (counts, durations, output paths) and exit non-zero on any error.
- Never log audio content or transcript/LLM bodies above `debug` — metadata and counts only, so logs stay shareable.
- Anything actionable lives in a **field**, so no consumer ever has to regex `msg`.

## Consuming logs

```sh
# live tail of the daemon
tail -f ~/Library/Application\ Support/ears/logs/earsd.jsonl | jq 'select(.level=="error")'

# every ASR stage timing across a day
jq 'select(.event=="stage.end" and .stage=="asr") | {ts, session, duration_ms, rtf}' logs/transcribe.jsonl

# the unified-logging mirror
log stream --predicate 'subsystem == "net.tomelliot.ears" && category == "earsd"' --level debug
```
