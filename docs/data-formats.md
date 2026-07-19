# Data formats

This document defines the on-disk contract. Because the ring buffer layout *is* the read API, these formats are stable interfaces: tools depend on them, so they are versioned and changed deliberately.

## Directory layout

```
<data-root>/                         # default: ~/Library/Application Support/ears
  sources/
    <source-id>/                     # e.g. mic, system, app_us.zoom.xos, browser_meet
      meta.toml                      # source descriptor (class, device, sample rate, codec)
      chunks/                        # native-rate listenable copy (default 48kHz mono)
        2026-07-17T10-30-00Z.<ext>   # time-stamped compressed audio chunk
        2026-07-17T10-30-30Z.<ext>
        ...
      asr/                           # derived 16kHz mono feed the transcriber consumes
        2026-07-17T10-30-00Z.<ext>
        ...
      index.jsonl                    # append-only VAD + chunk index (speech/silence spans)
  sessions/
    2026-07-17T10-30-00Z_standup/    # session id: start-timestamp + slug
      session.toml                   # session descriptor (sources, range, trigger, state)
  vocab/
    global.txt                       # global known-word list
    <session-id>.txt                 # optional per-session vocabulary
  runtime/
    earsd.sock                       # control socket (path configurable)
    earsd.pid

<output-root>/                       # default: ~/Documents/Transcripts (configurable)
  2026-07-17/
    10-30-00_standup.transcript.md   # transcript (from `transcribe`)
    10-30-00_standup.clean.md        # cleaned transcript (from `cleanup`)
    10-30-00_standup.summary.md      # summary (from `summarize`)
    10-30-00_standup.transcript.json # optional canonical sidecar (word timings, confidence)
```

`<source-id>` is the source's stable id with characters unsafe for paths replaced by `_` (e.g. `app:us.zoom.xos` → `app_us.zoom.xos`). The id itself, as used on the socket and in metadata, keeps its natural form.

## Audio chunks

- Fixed-duration chunks (default 30 s; configurable) named by their UTC start instant, ISO-8601 with `:` replaced by `-`.
- Compressed by default (AAC in a CAF/M4A container, or Opus). Codec and bitrate are per-source config; recorded in `meta.toml`.
- Chunk boundaries are independent of speech: chunks are a storage detail. Speech spans live in the index and may cross chunk boundaries.
- Chunks older than the source's time cap are deleted oldest-first. Deletion is logged.
- Written atomically (temp + rename); on flush, `fsync` both the file and its directory; on encode failure, keep the partial chunk.

### Dual-rate audio storage

Each source stores **two feeds**, because 16 kHz mono is what ASR wants but is telephone-bandwidth and unpleasant to re-listen to:

- **`chunks/`** — a **native-rate** (default 48 kHz) mono, listenable copy. This is the durable retained audio.
- **`asr/`** — the derived **16 kHz** mono feed the transcriber consumes.

The 16 kHz feed is derived from the native-rate copy, so it can be regenerated and need not be retained as long. Both share the same chunk-naming and index. Storing the listenable copy is the pattern the best references converged on; a single 16 kHz-only feed loses re-listenability for a small disk saving. Dual-rate is the default and can be turned off per source (`store_native = false`) when disk matters more than playback — see [configuration](./configuration.md).

For long sessions and constant-memory reads, the transcriber accesses audio through a **memory-mapped, disk-backed audio source** rather than loading a range into RAM. A session's pre-roll is sourced by **prepending from the on-disk ring** at session open (not from a separate RAM pre-roll buffer).

### `meta.toml` (source descriptor)

```toml
schema = 1
id = "app:us.zoom.xos"
class = "app"            # mic | system | app | browser | device
label = "Zoom"
device_uid = ""          # for device/mic sources
native_sample_rate = 48000  # rate of the listenable chunks/ feed
asr_sample_rate = 16000     # rate of the derived asr/ feed
store_native = true         # keep the listenable copy; false => asr feed only
channels = 1
codec = "aac"
bitrate = 64000
time_cap_seconds = 7200  # this source's ring-buffer window (default 2h)
created = "2026-07-17T10-30-00Z"
```

## The index (`index.jsonl`)

Append-only JSON Lines, one event per line, ordered by time. It is the map from wall-clock time to audio, and the record of speech activity so transcription can skip silence. Event types:

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

A reader reconstructs available audio for any time range from `chunk` events, uses `vad` spans to skip silence, and honours `gap` events as known-missing. Because it is append-only, `tail -f index.jsonl` shows live capture.

## Sessions (`session.toml`)

A session is metadata over the ring buffer — a named time range across one or more sources — not a separate recording.

```toml
schema = 1
id = "2026-07-17T10-30-00Z_standup"
slug = "standup"
sources = ["mic", "app:us.zoom.xos"]
start = "2026-07-17T10:30:00Z"
end   = "2026-07-17T11:02:00Z"   # empty while open
state = "closed"                  # open | closed
trigger = "app-signal"            # app-signal | manual
trigger_detail = "us.zoom.xos"
vocab = "vocab/2026-07-17T10-30-00Z_standup.txt"  # optional
pre_roll_seconds = 0              # seconds of already-buffered ring audio a
                                   # `transcribe --session` read widens this
                                   # session's range backward by; never
                                   # shifts `start` itself. 0 = no widening.
```

## Transcript format

Human-first Markdown with YAML frontmatter. This is the canonical human artifact; an optional `.transcript.json` sidecar carries full word-level timings/confidence for tooling.

```markdown
---
schema: 1
kind: transcript
session: 2026-07-17T10-30-00Z_standup
sources: [mic, "app:us.zoom.xos"]
range: { start: 2026-07-17T10:30:00Z, end: 2026-07-17T11:02:00Z }
model: { name: parakeet, backend: fluidaudio, version: "0.x" }
diarization: { enabled: true, backend: pyannote }
generated: 2026-07-17T11:02:14Z
duration_seconds: 1920
speech_seconds: 1440
word_count: 3120
vocab: [global, standup]
---

## [10:30:04] You
Morning — let's keep this quick. Any blockers?

## [10:30:11] Speaker 2  <!-- source: app:us.zoom.xos -->
Nothing from me, the deploy went out last night.

## [10:30:19] Speaker 3  <!-- source: app:us.zoom.xos -->
I'm blocked on the API key rotation.
```

Rules:

- Segments are grouped by speaker turn, each headed by a timestamp and a speaker label.
- **Speaker labels** derive first from the source (`mic` → `You`); within a multi-speaker source, diarization assigns stable `Speaker N` labels, and a source comment records provenance. Labels can be remapped to real names later without changing timestamps (see [speaker attribution](#speaker-attribution)).
- `cleanup` and `summarize` outputs use the same frontmatter convention with `kind: clean` / `kind: summary` and a `derived_from` field naming the source transcript. A `kind: summary` document also carries a `preset` field (the `[[summarize.preset]].name` it was generated from), rendered between `kind` and `derived_from`.

### Canonical JSON sidecar (optional)

```jsonc
{
  "schema": 1,
  "segments": [
    {
      "start": 604.14, "end": 611.88,          // seconds from range start
      "source": "app:us.zoom.xos",
      "speaker": "Speaker 2",
      "text": "Nothing from me, the deploy went out last night.",
      "words": [ {"w":"Nothing","start":604.14,"end":604.51,"conf":0.98}, /* ... */ ]
    }
  ]
}
```

The Markdown is rendered from the same data the sidecar holds, so the two never disagree for a given run.

## Speaker attribution

Attribution has two independent layers:

1. **Source-level (free):** every segment carries its originating source. `mic` maps to the user; each `app:`/`system`/`browser:` source maps to "the other side". This alone gives you-vs-them.
2. **Diarization (within a stream):** a diarization stage assigns `Speaker N` labels within a multi-speaker source. Labels are stable within a transcript.

A separate name map (per session, optional) can rename labels to real people:

```toml
# in session.toml or a sidecar
[speakers]
"Speaker 2" = "Priya"
"Speaker 3" = "Marcus"
```

Renaming is a formatting concern applied at/after `cleanup`; it never mutates timings.

## Vocabulary / known-word lists

Plain-text, one term or phrase per line; `#` comments allowed. A global list plus optional per-session lists (merged, session wins on conflict). Used in **both** pipeline stages: fed to the ASR model as biasing hints where the backend supports it, and passed to the `cleanup` LLM prompt as a correction backstop. See the [model interface](./specs/model-interface.md) and [LLM stages](./specs/llm-stages.md).

```
# global.txt
Parakeet
FluidAudio
Anthropic
Priya Raman
kubectl
```

## Schema versioning

Every structured file carries a `schema` integer. Tools reject a `schema` they don't understand with a clear error rather than guessing. Bumps are documented in the roadmap/changelog.
