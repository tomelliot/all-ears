# Spec: capture extension

## One job

Intercept the meeting page's `RTCPeerConnection`s, isolate each remote participant's audio into its own 16 kHz mono PCM stream tagged with a stable participant id, and forward those streams to the background context, which streams them to `earsd`. Identity resolution is the only platform-specific part; everything else is shared.

### Responsibilities

- Install an `RTCPeerConnection` constructor wrapper in the page's main world **before the page constructs its first connection**.
- Capture every remote audio track (added at join or mid-call), one isolated pipeline per track, surviving mute/replace/re-subscribe.
- Resolve each track to a stable participant id via the active platform adapter, degrading to `speaker-<n>` rather than blocking audio.
- Convert each stream to 16 kHz mono `pcm_s16le` off the main thread, without ever playing it back.
- Relay tagged PCM frames and participant lifecycle events to the background context, which owns the sockets to `earsd`.

### Explicit non-responsibilities

- Does **not** speak `earsd`'s protocols — that is [`transport.md`](./transport.md).
- Does **not** transcribe, diarize, or run models.
- Does **not** mutate SDP, transceiver direction, or any peer-connection state — it is a passive listener.
- Does **not** capture the local user's mic or the mixed tab.

## Architecture

Four contexts, one direction of audio flow:

```
 page main world            isolated world        background            local daemon
┌────────────────────┐     ┌──────────────┐     ┌──────────────┐     ┌───────────────┐
│ hook.content.ts    │     │ content.ts   │     │ background.ts│     │ earsd         │
│  RTCPeerConnection │ ──► │  (relay)     │ ──► │  WebSocket   │ ──► │ ws://127.0.0.1│
│  hook + audio tap  │ win │ postMessage  │ rt  │ owner +      │ ws  │  /ingest      │
│  platform adapter  │     │  ⇄ runtime   │     │ meeting ctl  │     │  /control     │
└────────────────────┘     └──────────────┘     └──────────────┘     └───────────────┘
```

The main world is the only place that can patch page globals; the isolated world is the only place with `chrome.runtime`; `content.ts` exists solely to bridge them via `window.postMessage`. The MV3 service worker holds the WebSockets directly (WebSocket activity keeps it alive, Chrome 116+) — there is no offscreen document, so Chrome and Firefox share one code path.

Layout (WXT project in `browser/`): entrypoints `hook.content.ts` (MAIN world, `document_start`), `content.ts` (isolated relay), `background.ts` (socket owner), `popup/`; libraries `lib/rtc-hook.ts`, `audio-tap.ts`, `transport.ts`, `control-transport.ts`, `meeting-tracker.ts`, `session-state.ts`, `capture-toggle.ts`, `pcm-port.ts`, `protocol.ts`, `epoch.ts`, and `lib/identity/` (the adapters). Build with `bun run build` / `bun run build:firefox`.

## Injection & timing

The hook is a `world: "MAIN"`, `runAt: "document_start"` content script — the browser guarantees it runs before page scripts, with no fetch race (an injected `<script src>` loses that race; verified empirically). Zoom is the strictest case: it caches the constructor at bootstrap, so a late wrapper catches nothing.

- **Idempotent install guard** (`lib/epoch.ts`): the hook no-ops on a second install.
- **Capture epoch:** each hook instance claims a monotonically higher epoch; only the newest emits PCM, and superseded instances tear down while the successor adopts the live-track registry. This is what makes SPA navigations and extension reloads safe against duplicated audio.
- The hook installs unconditionally (it must win the `document_start` race regardless), but defers capture start until the capture-toggle state arrives from the isolated world; toggling OFF supersedes the live epoch through the same teardown path.

## RTCPeerConnection hook contract

`lib/rtc-hook.ts` wraps the constructor preserving native behaviour: construct the real PC inside the wrapper and return it, `Wrapped.prototype = Original.prototype` (so `instanceof` holds), `Object.setPrototypeOf(Wrapped, Original)` (so statics inherit). Per connection it attaches `addEventListener("track")` **and** wraps the `ontrack` setter so a page handler can't shadow the hook. Audio tracks resolve to `event.streams[0] ?? new MediaStream([event.track])`.

**MUST NOT** in this layer: never enumerate `getReceivers()`/`getTransceivers()` for track discovery (breaks when the page wraps tracks — use the `track` event); never mutate `transceiver.direction` or munge SDP (a documented crash class that severs calls — we are passive).

## Track isolation & lifecycle

`lib/audio-tap.ts` owns a map keyed on the live `MediaStreamTrack` object — N tracks, N independent pipelines — plus a per-participant generation counter:

- **Start** (on `track`): resolve identity, bump the participant's generation, build the frame source, store it. A gone-and-back participant starts a fresh segment under the same id — never mutate a live pipeline across a drop.
- **Stop:** on `track.onended`, delete from the map before stopping, so a late frame can't resurrect a dead entry.
- **Mute/replace:** `onmute`/`onunmute` gate emission. Teams delivers tracks `muted=true` until first speech — accept enabled-but-muted tracks.
- An async identity upgrade (see Meet below) restarts the track's pipeline as a new segment under the upgraded id rather than renaming in place.
- An identity that confirms **after its track has ended** can't restart anything; it is sent as a `participant-renamed` message instead (adapter `onRename`). The background upserts the dead track's source label onto the *named* attendee (`meeting.attendee` with `id=<device>` + `source=browser:<platform>:<fallback>`), so audio already recorded under a `speaker-<n>` source is still transcript-labeled by the participant's name.

## Platform adapters

Identity is the fragile part; it lives entirely behind `lib/identity/adapter.ts`, selected by hostname. The capture spine never branches on platform.

```ts
export interface PlatformAdapter {
  readonly platform: "meet" | "zoom" | "teams";
  /** Best-effort stable id for a remote track. null → caller assigns speaker-<n>. */
  identify(track: MediaStreamTrack, stream: MediaStream, transceiver: RTCRtpTransceiver): ParticipantId | null;
  displayName?(id: ParticipantId): string | undefined;
  /** Called on every track's decoded-audio speaking edge. */
  onTrackSpeaking?(track: MediaStreamTrack, speaking: boolean): void;
  /** Register a callback for a later async identity upgrade of an already-resolved track. */
  onIdentify?(cb: (track: MediaStreamTrack, id: ParticipantId) => void): void;
  dispose?(): void;
}
```

- **Zoom** — the participant id is parsed from the track's MSID (`decodeURIComponent(streamId).match(/^(\d+)\+/)`, then `>> 10 << 10`, gated on `+CS+`). Intrinsic to the track, stable across mute/re-subscribe.
- **Meet** — no synchronous mechanism exists on the current build: tiles expose no per-participant media elements, and CSRC/SSRC values don't bridge to tiles (all verified dead live). `identify()` therefore returns `null`, and identity arrives **asynchronously by speaking-onset correlation**: Meet's `collections` `RTCDataChannel` carries a gzip+protobuf message on every speaking-state transition embedding the participant's stable `spaces/<space>/devices/<device>` id and a start/stop flag (`lib/identity/meet-collections.ts`, field paths `1.2.3.2.6` and `1.2.3.2.10.1`). `meet-correlator.ts` pairs a device id's speaking onset with the one live track whose decoded audio onset falls within ~200 ms; after one confirming turn the adapter pushes the upgraded id via `onIdentify`. There is no way to resolve a participant before their first speaking turn.
- **Teams** — one mixed track, no usable CSRCs. Buffered frames are attributed to the app's reported dominant speaker, emitting `Speaker N`. This is attribution, not isolation — never presented as per-participant fidelity.
- **Universal fallback:** on `null`, assign a stable `speaker-<n>` keyed to the track. Identity is best-effort; audio is not.

### The collections exception

Decoding an app's private protobuf/Redux internals is prohibited in general (versioned, undocumented wire formats — the biggest maintenance sink). The Meet `collections` parser is the one narrow exception, bounded by these guardrails:

- Only the two documented fields (device id, speaking flag) are decoded; nothing depends on any other field.
- Parsing is defensive: any shape mismatch degrades to `speaker-<n>`, never throws or blocks audio, and a schema self-check warns when real traffic stops matching the expected shape (plus a debug-gated structure dump for diagnosing drift).
- Tests carry real captured wire-byte fixtures, not just synthetic ones.

This does not license decoding anything else on `collections`, or Zoom's `__reduxStore`, or any other private store.

## Audio extraction

Two capture mechanisms, selected per platform, both terminating in the same downmix → resample (streaming, phase-continuous, native rate → 16 kHz mono) → bounded circular buffer pipeline in `audio-tap.ts`. Only the frame source differs.

- **Standard path (Zoom, Teams):** `MediaStreamTrackProcessor` reads decoded `AudioData` directly off each remote track. Construction is deferred to the track's first `unmute` — a processor built on a muted track never delivers frames, and a track allows only one processor ever. (`pcm-worklet.ts` survives as an unwired legacy fallback; don't build new capture against it.)
- **Meet path (`createEncodedStreams` tee):** Meet's client calls `receiver.createEncodedStreams()` on every audio receiver and decodes the RTP in its own WASM pipeline, so **no `MediaStreamTrack`-based mechanism ever produces audio on Meet** — worklet, processor, and `<audio>` taps all read pure silence (confirmed via `getStats()`: `decoderImplementation=undefined`, `jitterBufferEmittedCount=0` through live speech). The fix: wrap `createEncodedStreams` in the same MAIN-world hook, `.tee()` the pre-decode readable on audio receivers (Meet's own branch passes through untouched — verified transparent in live calls), and decode our branch with the native WebCodecs `AudioDecoder` (`{codec:"opus", sampleRate:48000, numberOfChannels:1}`; every Opus chunk is `"key"`). The decoder outputs the same `AudioData` interface the standard path yields, so downstream is shared. A registry keyed on the `MediaStreamTrack` connects the tee (which fires on the receiver) to the pipeline (built on the `track` event).
  - Gate the tee on `location.host === "meet.google.com"` at hook-install time — applied elsewhere it would double-capture platforms where the standard path works.
  - Do not attempt to reach Meet's own WASM decoder (it doesn't instantiate in the page's main-world realm) — unnecessary anyway, since native `AudioDecoder` covers Opus.
  - **Decoder recovery (restart-in-place):** a single bad Opus chunk puts the whole `AudioDecoder` into a permanent error state, so `MeetDecodeSource` rebuilds it in place and keeps capturing instead of dropping the participant. It distinguishes an *isolated* error after a healthy run (≥ `DECODER_HEALTHY_FRAMES` decoded — rebuild immediately, near-zero audio loss, and reset the restart budget) from a *barren* one (a rebuilt decoder that dies before decoding anything — Meet changing bitrate/DTX mid-stream feeds a burst of frames that won't decode from a cold start). Barren restarts don't re-feed the failed window: the source cools down for `DECODER_RESTART_COOLDOWN_MS`, dropping frames, then rebuilds on the next live frame ("resume at the next decodable boundary"), which paces them at most one per cooldown so a single poisoned burst can't burn the whole budget in under a second. Only after `DECODER_MAX_RESTARTS` barren restarts within a sliding `DECODER_RESTART_WINDOW_MS` does it give up, logging a per-track summary and emitting a `capture-failed` event (relayed to the background) so the audio gap is attributable rather than looking like the source merely went quiet.

**Shared constraints:** never connect any capture path to `AudioContext.destination` and never let a normalization `<audio>` element play — double-playback and echo into the user's mic are the failures this prevents. Output format is declared to `earsd` verbatim as `{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}`. Backpressure is a bounded per-participant circular buffer, drop-oldest, with a logged counter.

## Messaging & state

- **Main → isolated:** `window.postMessage({ __ears: true, ... })`, filtered on the marker and `event.source === window`. PCM frames carry `participantId`, `seq`, and the payload.
- **Isolated → main:** `{ __earsCtl: true, ... }` — mirrors the capture toggle (and every change) into the page realm as `capture-state` messages.
- **Isolated → background:** PCM rides a dedicated long-lived `runtime.connect` port (`lib/pcm-port.ts`), reconnected **lazily** on the next post after a disconnect so an idle tab never traps a suspended worker in a wake loop. Control events use typed runtime messaging.
- **Respawn replay:** the content relay keeps the durable copy of what the worker holds only in memory — the live meeting and current participants — and replays `meeting-started` + `joined` into every *fresh* port ahead of the message that triggered the reconnect. A respawned worker therefore re-learns which meeting the tab's audio belongs to (both verbs are idempotent daemon-side), so it can tag `ingest.open` with the meeting identity and send `meeting.end` when the tab goes away. Without the replay, an evicted-mid-call worker forwards PCM it can't attribute and has nothing to end — the stranded-active-meeting bug.
- **Meeting lifecycle:** `meeting-tracker.ts` (in the background) resolves DOM-detected meetings via `meeting.resolve` and opens/closes daemon sessions over the `/control` WebSocket — including pause/resume emulated as session close/re-open under the same meeting id. ([Control protocol v2](../control-protocol.md) moves this state machine into the daemon when it lands.)
- **Persisted state:** `storage.local` holds the user-facing capture toggle (explicit privacy intent — survives browser restart; missing/corrupt values default to ON so a failed read can't silently kill capture). `storage.session` holds worker-respawn recovery (active-session flag re-arms the `chrome.alarms` keepalive; session area so a fresh browser start can't resurrect a stale alarm). The keepalive is armed only while ≥1 participant is live — an idle extension schedules zero wakes.

## Constraints & MUST-NOT

1. No whole-tab/display capture (`tabCapture`, `getDisplayMedia`) — post-mix audio can't be separated per participant.
2. No mixing sources into one destination node.
3. No caption/transcript DOM scraping as an audio source.
4. No mutating `transceiver.direction` or SDP — the crash class that severs calls. We are passive.
5. No `getReceivers`/`getTransceivers` enumeration for track discovery — use the `track` event.
6. No decoding private protobuf/Redux internals for identity, except the bounded Meet `collections` exception above.
7. No trusting dominant-speaker as isolation (Teams degrades to `Speaker N`, labeled as such).
8. No routing captured audio to `AudioContext.destination`.
9. No `Object.keys` static copy on the constructor — use `Object.setPrototypeOf`.
10. No install without the idempotent guard and capture epoch.
11. No swallowing injection-order errors — a silent failure records zero audio while reporting success.
12. No `ScriptProcessorNode`/`MediaRecorder` for PCM, and no `MediaStreamTrack`-based capture on Meet — the tee is the only mechanism that works there.
13. No unbounded PCM queues — bounded circular buffer, drop-oldest, logged counter.
