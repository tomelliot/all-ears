# Data formats

This document defines the on-disk contract. Because the storage layout *is* the read API, these formats are stable interfaces: tools depend on them, so they are versioned and changed deliberately.

## Directory layout

```
<data-root>/                         # default: ~/Library/Application Support/ears
  sessions/
    <uuid>/                          # one directory per session — audio is session-scoped
      session.toml                   # session record (schema 3: identity, state, intervals,
                                     #   roster, sources); kept forever, never evicted
      events.jsonl                   # append-only session timeline; kept forever
      attribution.jsonl              # browser attribution flight-recorder events
                                     #   (browser-extension sessions only); kept forever
      transcript.md                  # RAW TRANSCRIPT (from `transcribe --session`) — an
      transcript.json                #   intermediate; kept forever, never swept
      transcript.clean.json          # the cleaned transcript's JSON sidecar (from `cleanup`) —
                                     #   machine-facing, so it stays here, not in the vault
      mic.follow.transcript.md       # a `transcribe --follow` run's live transcript,
                                     #   one per followed source
      sources/                       # AUDIO — deleted as one unit by retention
        <source-id>/                 # e.g. mic, system, browser_meet_jane
          meta.toml                  # source descriptor (class, device, sample rate, codec)
          chunks/                    # native-rate listenable copy (default 48kHz mono)
            2026-07-17T10-30-00Z.<ext>   # time-stamped compressed audio chunk
            2026-07-17T10-30-30Z.<ext>
          asr/                       # derived 16kHz mono feed the transcriber consumes
            2026-07-17T10-30-00Z.<ext>
          chunks.jsonl               # structural index: chunk/gap events
          vad/                       # segmented VAD stream (speech/silence spans)
            2026-07-17T10-30-00Z.jsonl   # one size/time-rotated segment, named by first event
  sources/                           # legacy global ring — read-only fallback, never
    <source-id>/                     #   written by live capture any more
  vocab/
    global.txt                       # global known-word list
    <session-id>.txt                 # optional per-session vocabulary (session UUID)
  runs/                              # range runs (`--last`/`--from`/`--to`) have no session
    2026-07-17T10-30-00Z_mic.transcript.md    # …so their raw transcripts land here
    2026-07-17T10-30-00Z_mic.transcript.json
    2026-07-17T10-30-00Z_mic.transcript.clean.json   # cleaned sidecar for a range run
  runtime/
    earsd.sock                       # control socket (path configurable)
    earsd.pid

<output-root>/                       # default: ~/Documents/Transcripts — PUBLISHED output,
  2026/08/05/                        #   laid out by `[cleanup] output`'s path template
    2026-08-05 - Kevin Weekly.md          # cleaned transcript (from `cleanup`)
    2026-08-05 - Kevin Weekly.summary.md  # summary (from `summarize`)
```

**Two tiers.** Raw transcripts are **intermediates**: addressed by session (or range-run id) inside the data store, with no user-facing layout. The **published** artifacts — the cleaned transcript and the summaries — go wherever their path template resolves to, `output_root` by default. A preset can publish somewhere else entirely (an Obsidian daily note, say); see [configuration](./configuration.md#path-templates). Only Markdown publishes: the cleaned transcript's JSON sidecar is machine-facing and stays in the data store beside the input transcript (`transcript.clean.json`), so the published tree never collects stray `.json` files.

`<source-id>` is the source's stable id with characters unsafe for paths replaced by `_` (e.g. `app:us.zoom.xos` → `app_us.zoom.xos`). The id itself, as used on the socket and in metadata, keeps its natural form. **Source ids are opaque handles**: a browser source is `browser:<platform>:<track-slug>` where the slug (`t3`) names one captured track and never a person — whose voice it carries lives in `[[speaker]]`, derived from the roster (see "Roster and speaker map"). Older stores hold labels whose suffix was a platform or synthetic participant id (`browser:meet:spaces-x-devices-y`, `browser:meet:speaker-1`); the change is additive-compatible for every reader that treats the id as opaque — which transcription's assembly does, resolving labels only through the speaker map — so old and new sessions read identically.

Audio is **session-scoped**: a source records only while a session names it, and everything it writes lands under that session's own `sources/` tree. Two consequences:

- **Transcripts are never evicted**, in either tier. Raw transcripts in the data store are deliberately not swept: once the audio is gone they are the only route to re-running cleanup or summarize with a different prompt or model.
- **Retention is a per-session delete.** Once an ended session's transcript has been complete for `evict_after_transcript_seconds` (default 2 h) — or, if no transcript ever completed, once the session has been over for `max_audio_age_seconds` (default 7 days) — the daemon deletes the whole `sessions/<uuid>/sources/` directory. `session.toml`, `events.jsonl`, and `attribution.jsonl` survive as the session's record. See `[earsd.retention]` in [configuration](./configuration.md).

The daemon enforces a **single-active-session invariant**: a `session.start` for a new identity (or a manual start) supersedes any session still live, running the old one through its full end pipeline first. At most one active session means exactly one legal directory for any capture actor at any moment, so a source's audio can never land in the wrong session's directory.

**Legacy directories are ignored, not migrated.** Pre-2026 layouts left two dead formats on disk: `sessions/<timestamp-slug>/` directories holding a schema-1 `session.toml`, and a `meetings/<uuid>/` tree holding schema-2 `meeting.toml` records. Nothing reads either — the session scan skips any descriptor whose `schema` isn't 3, and the `meetings/` tree is never consulted. They can be deleted by hand at any time.

## Audio chunks

- Fixed-duration chunks (default 30 s), named by their UTC start instant, ISO-8601 with `:` replaced by `-`.
- Compressed: AAC in an M4A container, or Opus. Codec and bitrate are per-source config, recorded in `meta.toml`.
- Chunk boundaries are a storage detail, independent of speech. Speech spans live in the index and may cross chunk boundaries.
- Chunks are never deleted individually. A session's audio grows for the session's duration and is deleted as one directory by transcript-driven retention (see above).
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
created = "2026-07-17T10-30-00Z"
```

## The index (`chunks.jsonl` + `vad/`)

The index is split across two logs, both append-only JSON Lines (one event per line, ordered by time), because `vad` events outnumber the rest by roughly 50-to-1 yet are consulted only when reconstructing a specific range:

- **`chunks.jsonl` — the structural log.** `chunk`/`gap` events. Small, and read whole to recover the chunk set. Nothing else is needed to answer "which audio exists".
- **`vad/<timestamp>.jsonl` — the segmented VAD stream.** `vad` speech/silence spans, written to segments that roll over on a byte cap (~8 MB) or a wall-clock span (~1 h), each named by its first event's start. A range read opens only the segments overlapping the range.

It maps wall-clock time to audio and records speech activity so transcription can skip silence. Event types:

```jsonc
// a written chunk
{"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/2026-07-17T10-30-00Z.m4a","frames":480000}

// a VAD span (speech or silence), possibly spanning chunk boundaries
{"t":"vad","state":"speech","start":"2026-07-17T10:30:02.140Z","end":"2026-07-17T10:30:09.880Z"}
{"t":"vad","state":"silence","start":"2026-07-17T10:30:09.880Z","end":"2026-07-17T10:30:14.020Z"}

// a capture gap (daemon down, device lost, pause, stalled push delivery)
{"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}
{"t":"gap","start":"2026-07-17T10:32:00Z","end":"2026-07-17T10:32:41.5Z","reason":"delivery-stall"}
```

A reader reconstructs available audio for any range from `chunk` events, uses `vad` spans to skip silence, and honours `gap` events as known-missing. Both logs are append-only, so `tail -f chunks.jsonl` and `tail -f vad/*.jsonl` show live capture.

## Sessions (`sessions/<uuid>/`)

The daemon-owned [Session](./specs/control-protocol.md#session) entity — the one lifecycle record. `session.toml` (**schema 3**) carries the fields of the wire's session object — identity, title, state, transcription intervals, roster, sources, trigger, transcript-completion marker — written atomically on every mutation and reloaded at daemon start. Optional scalar fields use an empty string for "absent"; `rev` is deliberately not persisted (revisions are scoped to a daemon boot).

```toml
schema = 3
id = "0d5e7f6a-…"                      # daemon-assigned UUID
platform = "meet"                       # platform identity; "" for manual sessions
external_id = "abc-defg-hij"            # the platform's own meeting id; "" for manual
title = "Weekly sync"                   # renameable; defaults from identity or start time
state = "ended"                         # active | paused | ended
started = "2026-07-19T10:00:00Z"
ended = "2026-07-19T10:31:00Z"          # "" while active/paused
transcript_completed = "2026-07-19T10:31:12Z"  # "" until a transcript run succeeds;
                                        #   the marker retention keys off
trigger = "browser-extension"           # manual | browser-extension
sources = ["mic", "browser:meet:t3"]    # source ids are opaque handles: a browser
                                        #   source names a captured track, never a
                                        #   person (see "Roster and speaker map")
reconciler_version = 4                  # which reconciler derived [[speaker]] below;
                                        #   absent = 0 (a file from before versioning,
                                        #   or a session never reconciled) — see
                                        #   "Roster and speaker map"

[[interval]]                            # transcription marks over the recording;
start = "2026-07-19T10:00:00Z"          #   pause closes one, resume opens the next
end = "2026-07-19T10:12:30Z"
[[interval]]
start = "2026-07-19T10:20:05Z"
end = ""                                # "" = currently marked

[[pipeline_issue]]                      # what the last on-end chain reported; replaced
stage = "summarize"                     #   by each run, absent = none
kind = "failed"                         # failed | warning
message = "LLM call failed for preset 'meeting': LLM backend call timed out"
exit_class = "retryable-upstream"       # "" for a warning

published_notes = [                     # what the last successful summarize wrote;
  "/vault/daily-notes/2026-07-19 - Jane Doe.md",  # never matched as another call's notes
]                                       #   absent = none; session.toml only, not on the wire

[[attendee]]                            # roster, upserted by whoever knows it
id = "spaces/x/devices/y"               #   (the extension's DOM layer today)
display_name = "Jane Doe"
joined = "2026-07-19T10:00:12Z"
left = ""
source = "browser:meet:t3"              # optional link to the source carrying
                                        #   this attendee's audio (the identity
                                        #   link — how a name reaches a track)
origin = "platform"                     # where `id` was minted: "platform" (the
                                        #   platform's own id) | "synthetic" (a
                                        #   capture track handle like t3 that
                                        #   names a track, not a person); "" or
                                        #   absent = unknown (files from before
                                        #   the field existed)
self = false                            # true on the local participant — you

[[speaker]]                             # the *reconciled* source → name map,
source = "browser:meet:t3"              #   derived from the roster at session end
name = "Jane Doe"                       #   (see "Roster and speaker map" below)
confidence = "correlated"               # correlated | inferred
```

`warnings = [...]` (a top-level array, omitted when empty) records what
reconciliation could not resolve or resolved by inference. It travels into the
transcript's frontmatter and from there into the note itself.

`events.jsonl` is the append-only per-session timeline — one line per domain event: `started`, `interval_opened`/`interval_closed`, `attendee_joined`/`attendee_left`, `renamed`, `capture_failed` (a browser source's capture died mid-call — carries `source` and the client's stated `reason`, so a gap in the audio is attributable rather than reading as silence), and `ended` with `reason = "client"` (explicit `session.end`), `"ingest-idle"` (the orphan grace timer), `"superseded"` (a new `session.start` displaced it), or `"orphaned"` (swept at daemon boot). Written for disk consumers (`summarize`, humans, `jq`), never used for protocol sync.

Tools reject a `schema` other than 3 rather than guessing — which is exactly how the legacy schema-1 and schema-2 descriptors (above) stay inert on disk.

### `attribution.jsonl` (attribution flight recorder)

Every input the browser extension's speaker-attribution decision consumed, and every decision it took, as an append-only JSON Lines stream beside `events.jsonl` — present only on sessions fed by the browser extension, and only for the stretches a daemon session existed. The extension records events per call in a bounded in-page ring, ships them in batches over the ingest WebSocket (`ingest.attribution`, [transport](./specs/browser/transport.md#wire-protocol)), and the daemon appends the lines **verbatim** — what is on disk is byte-for-byte what the browser recorded, so the file replays against the same code that consumed the evidence live.

The vocabulary is owned by the browser (`browser/lib/attribution-log.ts`), versioned by a per-line `schema` integer (currently 1). One JSON object per line, discriminated by `type`, with `t` = epoch ms at observation:

- **track lifecycle** — `track-appeared` (track id, seam, muted-at-dispatch, provenance origin/root), `track-unmuted`, `track-muted`, `track-ended`
- **admission decisions** — `admitted`, `deferred`, `adopted`, `retired`, `escalated`, each with the admission policy's reason
- **identity evidence** — `collections-edge` (parsed device id and mic state plus the raw payload bytes, base64), `dom-burst` (tile speaking-ring onset per device), `audio-onset` (decoded-audio speaking edge per track)
- **roster observations** — `roster-delta` (id → display name, with the `(You)`-marker evidence as `isLocal`)
- **binding events** — `provisional-binding` (track ↔ device, which correlator, how many confirming turns, and the outcome — bound or refused and why), and `identity-link` (the identity actually forwarded to the daemon: capture handle ↔ platform id, with the track id joining it back to the binding that caused it)

Best-effort by contract: batches arriving before the session is declared, or while the daemon is down, are dropped server-side or never sent — the in-page ring (exported on demand via `window.__earsExportAttribution()` in the meeting tab's console) is the recovery path. The daemon skips any line that would break JSONL framing; it never interprets the events. Like `events.jsonl`, the file survives audio retention. Contains device-id paths and display names — treat exports as private, and commit only sanitized/synthetic fixtures.

## Transcript format

Human-first Markdown with YAML frontmatter. This is the canonical human artifact; an optional `.transcript.json` sidecar carries full word-level timings/confidence for tooling.

```markdown
---
schema: 1
kind: transcript
session: 0d5e7f6a-…         # the session UUID this transcript unions the
                            # intervals of (`transcribe --session`)
# range_run: 2026-07-17T10-30-00Z_mic
                            # instead of `session:` on a raw range run
                            # (`--last`/`--from`/`--to`) — a synthesized
                            # <start-timestamp>_<slug> identifier
title: Weekly standup       # the session's display title, and `{title}` in a
                            # downstream path template; absent with no session
note: "[[daily-notes/2026/07/29/2026-07-17 - Weekly standup.md]]"
                            # the note `summarize` wrote from this transcript —
                            # the inverse of that note's own `transcript:` link.
                            # Stamped in after the summary lands, since that is
                            # the only point both paths are known; absent until
                            # a preset has summarized this transcript
attendees:                  # everyone the roster named, `(me)` marking the
- Tom Elliot (me)           # local participant. Independent of whether any
- Jane Doe                  # audio was matched to them — see "Roster and
                            # speaker map"; absent with no session context
started: 2026-07-17T10:30:00Z
                            # when the session began, as distinct from `range`
                            # below (a --from/--to rerun narrows the range but
                            # not the session). The date tokens key on this, so
                            # a call that ran past midnight always files under
                            # the day it started
sources:
- mic
- "app:us.zoom.xos"
range:
  start: 2026-07-17T10:30:00Z
  end: 2026-07-17T11:02:00Z
model:
  name: parakeet
  backend: fluidaudio
  version: "0.x"
diarization:
  enabled: false
generated: 2026-07-17T11:02:14Z
duration_seconds: 1920
speech_seconds: 1440
word_count: 3120
vocab:
- global
- standup
# audio_stores:             # present on `transcribe --session` output only —
# - "mic=ring"              # which store each source was read from (`session` =
# - "app:us.zoom.xos=session"
#                           # per-session copy, `ring` = legacy global buffer),
                            # so a wrong-store read is visible
# warnings:                 # what was degraded or inferred about this
# - "speaker attribution: …"
#                           # transcript; omitted when there is nothing to say.
                            # `summarize` renders these into the note as a
                            # callout, because a warning only in a log is a
                            # warning nobody reads
---

**[10:30:04] You**
Morning — let's keep this quick. Any blockers?

**[10:30:11] app:us.zoom.xos**
Nothing from me, the deploy went out last night.
> [10:30:14] You: Nice.
```

Rules:

- **Frontmatter is YAML, written in block style.** The suite emits and parses it with a real YAML implementation (Yams): what it writes is the block-style shape above, and what it reads back is any valid YAML mapping with these fields — including older flow-style files this suite wrote (`sources: [mic]`), and frontmatter a vault linter has reformatted. Free-form scalars that could be misread as another type (leading digit, reserved word, `:` and friends) are double-quoted.
- Segments are grouped by speaker turn, each labelled with a timestamp and a speaker name. The label is **bold text, not a heading**: a speaker name is metadata, not document structure, and an `##` per turn rendered a one-word "Yeah." at display size while buying an outline of a thousand entries named after two people. Readers of transcripts written before this change are unaffected — the parser still accepts the old `## [HH:MM:SS] speaker` form.
- **A turn is never split.** Turns are emitted whole in start order, even when two people overlap. Splitting a turn wherever another speaker intrudes is faithful to the audio and unreadable as a document — it shreds both sentences into alternating single words. Nor are a speaker's consecutive segments merged: an ASR pause is a paragraph break a reader wants.
- **Backchannels are demoted.** A turn of at most four words falling entirely inside another speaker's turn — "Yeah.", "Right." — renders as a `> [HH:MM:SS] speaker: text` blockquote line attached beneath the turn it interrupted, instead of breaking that turn in two. It stays a full segment in the JSON sidecar, so nothing is lost; only the Markdown demotes it.
- **Turns with no text are dropped.** A heading with no words tells a reader nothing.
- **Speaker labels** resolve through the session's `[[speaker]]` map: a mapped source renders as its speaker's name, `mic` → `You`, and an unmapped source falls back to its raw (opaque) source id. Within-stream diarization — stable `Speaker N` labels inside a multi-speaker source — ships as the offline refinement pass.
- **The path-template context travels here, not on the command line.** `title:` and `started:` are what a publishing stage expands `{title}`/`{date}`/`{week}` against, so a manual rerun files exactly where the daemon-spawned run did.
- `cleanup` and `summarize` outputs use the same frontmatter convention with `kind: clean` / `kind: summary` and a `derived_from` field naming the source transcript. A summary also carries a `preset` field naming the `[[summarize.preset]]` it was generated from.
- A `[[summarize.preset]]` with `frontmatter = false` writes its body alone — no YAML block and no JSON sidecar. That output is plain Markdown, not an ears document, which is what a destination owning its own frontmatter (an Obsidian vault) needs.

### Canonical JSON sidecar (optional)

```jsonc
{
  "schema": 1,
  "diarization": { "enabled": false },        // { enabled, backend? } — mirrors the frontmatter
  "speakers": [                               // the speaker map this run's turns were labelled
    { "source": "browser:meet:t3",            //   with — the session's stored [[speaker]] map, or
      "name": "Jane Doe",                     //   the fresh re-derivation a --session run computed
      "confidence": "correlated" }            //   (which session.toml never sees, making this its
  ],                                          //   one durable record); omitted with no session map
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

Sidecars live in the data store, beside the transcript they describe: `transcript.json` for the raw intermediate, `transcript.clean.json` for the cleaned run over it (range runs follow the same pattern under `runs/`). The published cleaned Markdown gets no sidecar neighbour.

## Roster and speaker map

Two different things, kept apart on purpose.

The **roster** (`[[attendee]]`) is observed: the platform names its own participants, and it is right from the moment they join. The **speaker map** (`[[speaker]]`) is derived: which audio track carries whose voice. Deriving it is a guess — the capture client pairs a track to a participant by temporal coincidence — and guesses fail.

Storing only the derived answer meant a failed derivation *erased* a name the session had known all along: the transcript, the note's title and its attendee list all read the binding, so a correlation miss lost the participant entirely. Keeping the roster whole means a total attribution failure still yields the right attendees and the right note title.

At `session.end` the daemon reconciles one into the other, applying invariants a binding must satisfy:

1. **A browser-captured track is never the local participant.** You are captured on `mic`; the browser taps remote streams. A `browser:*` source bound to the attendee marked `self` is impossible, not merely unlikely, and is dropped — the source returns to the unassigned pool. When that `self` flag is itself contradicted on both fronts — the flagged attendee is bound to remote audio *and* join order singles out a different attendee as the one whose arrival started the session — the flag is revised rather than the binding dropped, and the evidence for the revision is recorded in `warnings`.
2. **A one-remote call is settled by counting.** With exactly one named non-local attendee, every remote track is theirs, including the several source ids one participant accumulates through an identity upgrade (they share a name, so they coalesce into one speaker label). Only rows the platform itself named can be people: a named attendee whose `origin` is `"synthetic"` is a stand-in for a track and never counts as a remote participant (or appears in the derived title), so a junk synthetic row cannot block this inference. Rows with unknown origin (old files) count exactly as they did before the field existed.
3. **A source carries at most one name.** Competing claims on one source resolve deterministically — the first claimant wins, identically on every re-run — with the losing claim recorded in `warnings` rather than left to a dictionary insertion race downstream.

Beside the roster's own `source` links, reconciliation consumes the **binding hints** in the session's `attribution.jsonl` (the `identity-link` events, each joined to the `provisional-binding` decision that caused it): a hint claims a source for a named attendee under the same invariants, after the roster's claims. Hints cover what the roster's single `source` field per attendee cannot — one participant owning several track-handle sources across a call (a rejoin, a seam swap), and an identity confirmed after the row's link was overwritten. A session with no attribution log reconciles from the roster alone, exactly as before.

Reconciliation also consumes the log's **speech evidence**: a browser source whose capture produced no `audio-onset` events was captured but silent, so it draws no inferred speaker row and no warning — silence is unremarkable (Meet routinely allocates decoder tracks that never carry audio). The named-but-unmatched warning survives only for its real purpose, lost audio: it fires when unmatched speech-carrying sources exist, or when the platform's own speaking ring showed the attendee demonstrably talking yet nothing matched. Without a log, every warning behaves as before — absence of proof is not proof of silence.

With two or more remote participants and an unresolved track, nothing is forced and nothing is assigned: an unlabelled turn is recoverable, a confidently mislabelled one is not. Each entry records `confidence` — `correlated` (the client's binding, having survived the invariants) or `inferred` (assigned by elimination).

The derivation is a pure function of the roster, so it also runs on demand — and it is versioned: `reconciler_version` in `session.toml` records which reconciler wrote the stored map, and a file without the field is version 0 (written before versioning existed, and read fine — the field's absence is never an error). `transcribe --session` re-derives the map when none is stored *or* when the stored one carries an older version than the current reconciler, so a reconciler fix repairs past sessions on their next transcription rather than only future ones; `transcribe --rereconcile` forces the re-derivation even for a current-version map. The re-derived map labels that run's transcript — `session.toml` keeps the daemon's own record.

## Speaker attribution

Two independent layers:

1. **Source-level (implemented):** every segment carries its originating source. `mic` maps to you; each `app:`/`system` source maps to the other side; each `browser:<platform>:<track-slug>` source carries exactly one participant's audio, named through the reconciled `[[speaker]]` map. Keeping sources separate through capture and transcription is what makes this attribution free and reliable.
2. **Diarization (offline pass implemented):** an opt-in diarization stage (`[diarize].backend = "sortformer"`) assigns stable `Speaker N` labels within a multi-speaker source, rendered as `<source> · Speaker N` so source attribution stays primary. An optional per-session name map (`Speaker 2` → `Priya`) applied at or after `cleanup`, never mutating timings, remains future work; the live (streaming) pass is a follow-up to the offline pass that ships today.

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
