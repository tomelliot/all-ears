# Data formats

This document defines the on-disk contract. Because the ring buffer layout *is* the read API, these formats are stable interfaces: tools depend on them, so they are versioned and changed deliberately.

## Directory layout

```
<data-root>/                         # default: ~/Library/Application Support/ears
  sources/
    <source-id>/                     # e.g. mic, system, app_us.zoom.xos, browser_meet_jane
      meta.toml                      # source descriptor (class, device, sample rate, codec)
      chunks/                        # native-rate listenable copy (default 48kHz mono)
        2026-07-17T10-30-00Z.<ext>   # time-stamped compressed audio chunk
        2026-07-17T10-30-30Z.<ext>
      asr/                           # derived 16kHz mono feed the transcriber consumes
        2026-07-17T10-30-00Z.<ext>
      index.jsonl                    # append-only VAD + chunk index (speech/silence spans)
  sessions/
    2026-07-17T10-30-00Z_standup/    # session id: start-timestamp + slug
      session.toml                   # session descriptor (sources, range, trigger, state)
  meetings/
    <uuid>/
      meeting.toml                   # meeting identity (platform, external id)
  vocab/
    global.txt                       # global known-word list
    <session-id>.txt                 # optional per-session vocabulary
  runtime/
    earsd.sock                       # control socket (path configurable)
    earsd.pid

<output-root>/                       # default: ~/Documents/Transcripts
  2026-07-17/
    10-30-00_standup.transcript.md   # transcript (from `transcribe`)
    10-30-00_standup.clean.md        # cleaned transcript (from `cleanup`)
    10-30-00_standup.summary.md      # summary (from `summarize`)
    10-30-00_standup.transcript.json # optional canonical sidecar (word timings, confidence)
```

`<source-id>` is the source's stable id with characters unsafe for paths replaced by `_` (e.g. `app:us.zoom.xos` → `app_us.zoom.xos`). The id itself, as used on the socket and in metadata, keeps its natural form.

## Audio chunks

- Fixed-duration chunks (default 30 s), named by their UTC start instant, ISO-8601 with `:` replaced by `-`.
- Compressed: AAC in an M4A container, or Opus. Codec and bitrate are per-source config, recorded in `meta.toml`.
- Chunk boundaries are a storage detail, independent of speech. Speech spans live in the index and may cross chunk boundaries.
- Chunks older than the source's time cap are deleted oldest-first; deletion is logged and indexed.
- Written atomically (temp + rename); on flush, `fsync` both the file and its directory.

### Dual-rate storage

Each source stores **two feeds**, because 16 kHz mono is what the ASR model wants but is unpleasant to re-listen to:

- **`chunks/`** — a native-rate (default 48 kHz) mono, listenable copy. This is the durable retained audio.
- **`asr/`** — the derived 16 kHz mono feed the transcriber consumes.

Both share the same chunk naming and index. Set `store_native = false` per source to keep only the ASR feed when disk matters more than playback.

### `meta.toml` (source descriptor)

```toml
schema = 1
id = "app:us.zoom.xos"
class = "app"            # mic | system | app | browser | device
label = "Zoom"
device_uid = ""          # for device/mic sources
native_sample_rate = 48000
asr_sample_rate = 16000
store_native = true
channels = 1
codec = "aac"
bitrate = 64000
time_cap_seconds = 7200  # this source's ring-buffer window
created = "2026-07-17T10-30-00Z"
```

## The index (`index.jsonl`)

Append-only JSON Lines, one event per line, ordered by time. It maps wall-clock time to audio and records speech activity so transcription can skip silence. Event types:

```jsonc
// a written chunk
{"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/2026-07-17T10-30-00Z.m4a","frames":480000}

// a VAD span (speech or silence), possibly spanning chunk boundaries
{"t":"vad","state":"speech","start":"2026-07-17T10:30:02.140Z","end":"2026-07-17T10:30:09.880Z"}
{"t":"vad","state":"silence","start":"2026-07-17T10:30:09.880Z","end":"2026-07-17T10:30:14.020Z"}

// a capture gap (daemon down, device lost, pause)
{"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}

// eviction of an aged-out chunk
{"t":"evict","file":"chunks/2026-07-17T08-30-00Z.m4a","start":"2026-07-17T08:30:00Z"}
```

A reader reconstructs available audio for any range from `chunk` events, uses `vad` spans to skip silence, and honours `gap` events as known-missing. Because it is append-only, `tail -f index.jsonl` shows live capture.

## Sessions (`session.toml`)

A session is metadata over the ring buffer — a named time range across one or more sources — not a separate recording.


```toml
schema = 1
id = "2026-07-17T10-30-00Z_standup"
slug = "standup"
sources = ["mic", "app:us.zoom.xos"]
start = "2026-07-17T10:30:00Z"
end   = "2026-07-17T11:02:00Z"   # absent while open
state = "closed"                  # open | closed
trigger = "app-signal"            # app-signal | manual | browser-extension
trigger_detail = "us.zoom.xos"
vocab = "vocab/2026-07-17T10-30-00Z_standup.txt"  # optional
pre_roll_seconds = 0              # seconds of already-buffered ring audio a
                                   # `transcribe --session` read widens this
                                   # session's range backward by; never
                                   # shifts `start` itself. 0 = no widening.

[speakers]                        # optional name map (see speaker attribution);
"browser:meet:jane-a1b2" = "Jane Doe"  # written by the daemon at meeting.end
                                   # from the meeting's roster
```

## Meetings (`meetings/<uuid>/`)

The daemon-owned [Meeting](./specs/control-protocol.md#meeting) entity, layered above
sessions. `meeting.toml` (schema 2) carries the fields of the wire's meeting object — identity,
title, state, transcription intervals, roster, sources, trigger — written atomically on every
mutation and reloaded at daemon start. `events.jsonl` is the append-only per-meeting timeline
(`started`, `interval_opened`/`interval_closed`, `attendee_joined`/`attendee_left`, `renamed`,
`ended` with `reason = "client" | "ingest-idle"`), written for disk consumers, never used for
protocol sync. On `meeting.end` the daemon materializes one closed session per interval
(slug = the meeting UUID) with the roster written into each session's `[speakers]` map.

## Transcript format

Human-first Markdown with YAML frontmatter. This is the canonical human artifact; an optional `.transcript.json` sidecar carries full word-level timings/confidence for tooling.

```markdown
---
schema: 1
kind: transcript
session: 2026-07-17T10-30-00Z_standup
# meeting: 0d5e…            # present on `transcribe --meeting` output — the
                            # interval union of one daemon-owned meeting
sources: [mic, "app:us.zoom.xos"]
range: { start: 2026-07-17T10:30:00Z, end: 2026-07-17T11:02:00Z }
model: { name: parakeet, backend: fluidaudio, version: "0.x" }
diarization: { enabled: false }
generated: 2026-07-17T11:02:14Z
duration_seconds: 1920
speech_seconds: 1440
word_count: 3120
vocab: [global, standup]
---

## [10:30:04] You
Morning — let's keep this quick. Any blockers?

## [10:30:11] app:us.zoom.xos
Nothing from me, the deploy went out last night.
```

Rules:

- Segments are grouped by speaker turn, each headed by a timestamp and a speaker label.
- **Speaker labels** derive from the source: `mic` → `You`, every other source → its source id (a per-participant browser source is therefore already a per-person label). Within-stream diarization — stable `Speaker N` labels inside a multi-speaker source — is designed but not yet implemented.
- `cleanup` and `summarize` outputs use the same frontmatter convention with `kind: clean` / `kind: summary` and a `derived_from` field naming the source transcript. A summary also carries a `preset` field naming the `[[summarize.preset]]` it was generated from.

### Canonical JSON sidecar (optional)

```jsonc
{
  "schema": 1,
  "segments": [
    {
      "start": 604.14, "end": 611.88,          // seconds from range start
      "source": "app:us.zoom.xos",
      "speaker": "app:us.zoom.xos",
      "text": "Nothing from me, the deploy went out last night.",
      "words": [ {"w":"Nothing","start":604.14,"end":604.51,"conf":0.98} ]
    }
  ]
}
```

The Markdown is rendered from the same data the sidecar holds, so the two never disagree for a given run.

## Speaker attribution

Two independent layers:

1. **Source-level (implemented):** every segment carries its originating source. `mic` maps to you; each `app:`/`system` source maps to the other side; each `browser:<platform>:<participant>` source maps to one named participant. Keeping sources separate through capture and transcription is what makes this attribution free and reliable.
2. **Diarization (not yet implemented):** a diarization stage will assign stable `Speaker N` labels within a multi-speaker source, with an optional per-session name map (`Speaker 2` → `Priya`) applied at or after `cleanup`, never mutating timings.

## Vocabulary / known-word lists

Plain text, one term or phrase per line; `#` comments allowed. A global list plus optional per-session lists (merged, session wins on conflict). The merged list is passed to the `cleanup` LLM prompt as a correction backstop and recorded in transcript frontmatter. Feeding it to the ASR decoder as biasing hints is designed (see the [model interface](./specs/model-interface.md)) but not wired up yet.

```
# global.txt
Parakeet
FluidAudio
Anthropic
kubectl
```

## Schema versioning

Every structured file carries a `schema` integer. Tools reject a `schema` they don't understand with a clear error rather than guessing.
