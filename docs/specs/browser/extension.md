# Spec: capture extension

## One job

Intercept the meeting page's `RTCPeerConnection`s, isolate each remote participant's audio into its own 16 kHz mono PCM stream tagged with a stable per-track handle, and forward those streams to the background context, which streams them to `earsd`. Whose voice a handle carries is resolved separately — platform identities flow as attendee upserts linking the handle's source, never into the source id itself. Identity resolution is the only platform-specific part; everything else is shared.

### Responsibilities

- Install an `RTCPeerConnection` constructor wrapper in the page's main world **before the page constructs its first connection**.
- Capture every remote audio track (added at join or mid-call), one isolated pipeline per track, surviving mute/replace/re-subscribe.
- Mint each admitted track a stable, opaque source handle (`t<n>`), and resolve its owner's platform identity via the active platform adapter — at admission when the platform allows it, by speaking-onset correlation later otherwise, or never; audio flows under the handle regardless.
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
│  platform adapter  │     │  ⇄ runtime   │     │ session ctl  │     │  /control     │
└────────────────────┘     └──────────────┘     └──────────────┘     └───────────────┘
```

The main world is the only place that can patch page globals; the isolated world is the only place with `chrome.runtime`; `content.ts` exists solely to bridge them via `window.postMessage`. The MV3 service worker holds the WebSockets directly (WebSocket activity keeps it alive, Chrome 116+) — there is no offscreen document, so Chrome and Firefox share one code path.

Layout (WXT project in `browser/`): entrypoints `hook.content.ts` (MAIN world, `document_start`), `content.ts` (isolated relay), `background.ts` (socket owner), `popup/`; libraries `lib/rtc-hook.ts`, `audio-tap.ts`, `transport.ts`, `control-transport.ts`, `session-tracker.ts`, `keepalive.ts`, `capture-toggle.ts`, `pcm-port.ts`, `protocol.ts`, `epoch.ts`, and `lib/identity/` (the adapters). Build with `bun run build` / `bun run build:firefox`.

## Injection & timing

The hook is a `world: "MAIN"`, `runAt: "document_start"` content script — the browser guarantees it runs before page scripts, with no fetch race (an injected `<script src>` loses that race; verified empirically). Zoom is the strictest case: it caches the constructor at bootstrap, so a late wrapper catches nothing.

- **Idempotent install guard** (`lib/epoch.ts`): the hook no-ops on a second install.
- **Capture epoch:** each hook instance claims a monotonically higher epoch; only the newest emits PCM, and superseded instances tear down while the successor adopts the live-track registry. This is what makes SPA navigations and extension reloads safe against duplicated audio.
- The hook installs unconditionally (it must win the `document_start` race regardless), but defers capture start until the capture-toggle state arrives from the isolated world; toggling OFF supersedes the live epoch through the same teardown path.

## RTCPeerConnection hook contract

`lib/rtc-hook.ts` wraps the constructor preserving native behaviour: construct the real PC inside the wrapper and return it, `Wrapped.prototype = Original.prototype` (so `instanceof` holds), `Object.setPrototypeOf(Wrapped, Original)` (so statics inherit). Per connection it attaches `addEventListener("track")` **and** wraps the `ontrack` setter so a page handler can't shadow the hook. Audio tracks resolve to `event.streams[0] ?? new MediaStream([event.track])`. On `jitsi` and `web` pages it also watches for the Jitsi bridge channel: a `datachannel` listener, and a per-connection `createDataChannel` wrap that calls the native method with the same arguments and returns its channel untouched. A channel labelled `JVB data channel` gets one added `message` listener (see Jitsi below); no other channel is touched.

**MUST NOT** in this layer: never enumerate `getReceivers()`/`getTransceivers()` for track discovery (breaks when the page wraps tracks — use the `track` event); never mutate `transceiver.direction` or munge SDP (a documented crash class that severs calls — we are passive).

## Track isolation & lifecycle

`lib/audio-tap.ts` owns a map keyed on the live `MediaStreamTrack` object — N tracks, N independent pipelines — plus a per-handle generation counter:

- **Start** (on `track`): mint (or re-use) the track's source handle, bump its generation, build the frame source, store it. A gone-and-back track starts a fresh segment under the same handle — never mutate a live pipeline across a drop.
- **Reassign:** when the adapter reports that a track now carries another person (`onTrackReassigned`, a reused Jitsi slot), the track's source ends and a fresh handle continues the same pipeline. This is the only case where a live track changes handle.
- **Stop:** on `track.onended`, delete from the map before stopping, so a late frame can't resurrect a dead entry.
- **Mute/replace:** `onmute`/`onunmute` gate emission. Teams delivers tracks `muted=true` until first speech — accept enabled-but-muted tracks.
- A platform identity — resolved at admission (`identify()`) or confirmed later by correlation (adapter `onIdentity`) — is forwarded as a `participant-identified` message: a `session.attendee` upsert with `id=<platform id>`, the display name when resolved, and `source=browser:<platform>:<handle>`. The pipeline is never restarted for an identity, no frames are lost, and the message is identical whether the track is live or already ended — late identity is just another upsert.

## Platform adapters

Identity is the fragile part; it lives entirely behind `lib/identity/adapter.ts`, selected by hostname. The capture spine never branches on platform.

```ts
export interface PlatformAdapter {
  readonly platform: Platform; // "meet" | "zoom" | "teams" | "daily" | "jitsi" | "web"
  /** Best-effort platform id for a remote track at admission. null → the source stays anonymous until (unless) a later identity confirms. */
  identify(track: MediaStreamTrack, stream: MediaStream): PlatformParticipantId | null;
  displayName?(id: PlatformParticipantId): string | undefined;
  /** Called on every track's decoded-audio speaking edge. */
  onTrackSpeaking?(track: MediaStreamTrack, speaking: boolean): void;
  /** Called on every track's "unmute" (RTP resumed). */
  onTrackUnmute?(track: MediaStreamTrack): void;
  /** A platform-DOM speaking indicator fired for a device id. */
  onDeviceSpeaking?(deviceId: string, at: number): void;
  /** Register a callback for a platform identity confirmed asynchronously for a captured track — forwarded as an attendee upsert linking the track's source handle; nothing restarts, and it may fire after the track ended. */
  onIdentity?(cb: (trackId: string, id: PlatformParticipantId) => void): void;
  /** Register a callback for batches of (id → display name) resolved from the platform roster/UI. */
  onRoster?(cb: (entries: RosterEntry[]) => void): void;
  /** Re-scan the identity source (called by the periodic capture reconciler). */
  pollIdentities?(): void;
  dispose?(): void;
}
```

- **Zoom** — the participant id is parsed from the track's MSID (`decodeURIComponent(streamId).match(/^(\d+)\+/)`, then `>> 10 << 10`, gated on `+CS+`). Intrinsic to the track, stable across mute/re-subscribe.
- **Meet** — `identify()`'s tile-media correlation is opportunistic (the tile attributes vanished once and returned — see `lib/identity/meet.ts`'s dated addenda) and usually returns `null`; identity arrives **asynchronously by correlation**. Meet's `collections` `RTCDataChannel` carries a gzip+protobuf message embedding the participant's stable `spaces/<space>/devices/<device>` id and a mute flag (`lib/identity/meet-collections.ts`, field paths `1.2.3.2.6` and `1.2.3.2.10.1`). That flag is a **mute-state edge, not a per-turn speaking indicator** — re-interpreted 2026-07-24 (`meet-collections.ts`): the channel emits nothing during normal turn-taking, one message per deliberate mute/unmute. `MeetIdentityEngine` (`meet-identity-engine.ts`, three `meet-correlator.ts` pairings) correlates device ids to tracks: the mic-open edge against the track-level `unmute` event (~2 s window — the pairing current builds actually support); the tile speaking-ring burst (`meet-speaking-dom.ts`, the only per-turn per-device signal left) against the decoded-audio speaking onset (~1 s); and the original mic-open ↔ audio-onset pairing (~200 ms), dormant on current builds and kept in case per-turn events return. After the confirming pairings the adapter pushes the confirmed id via `onIdentity`, and it lands as an attendee upsert linking the track's source. A participant cannot resolve by correlation before their first unmute or speaking turn.
- **Jitsi** (`lib/identity/jitsi.ts`; meet.jit.si and 8x8.vc) — remote audio arrives in one of two shapes, told apart by the stream id. Live meet.jit.si call, 2026-11-22, three people:
  - **Endpoint-named tracks** (`<endpointId>-audio-<index>[-<pcId>]`): lib-jitsi-meet rewrites every local MSID to this, and it reaches the receiver as `MediaStream.id`. The P2P connection (two people) always uses it, and the bridge does when SSRC rewriting is off. The participant id is parsed from the stream id, Zoom-style.
  - **SSRC-rewriting slots** (`remote-audio-<n>`): on at meet.jit.si. The bridge forwards audio over a pool of reused slot tracks, and the owner is in no id. The adapter resolves it in two steps: slot → SSRC from the bridge connection's remote SDP (`a=ssrc:<ssrc> msid:remote-audio-<n> …`, read only; `getSynchronizationSources()` returns nothing for these tracks), then SSRC → endpoint id from the bridge channel's `AudioSourcesMap` message. The bridge sends that map only when assignments change, including the initial map when the channel opens. A slot whose owner is not known yet stays anonymous and is named by `onIdentity` when the owner arrives. When the bridge gives a slot to someone else, the adapter calls `onTrackReassigned`: `audio-tap.ts` ends the track's source (`participant-left`) and continues the same pipeline under a fresh handle (`participant-joined`), then re-identifies it. Each source therefore carries one person, which the daemon requires (`RosterReconciler` keeps the first claim on a source). The pipeline is retargeted, not rebuilt, because a track allows one `MediaStreamTrackProcessor` ever.
  - The bridge's own `mixedmslabel` stream sends no audio and never becomes a source.
  - Names come from `#participant_<endpointId>_name`. The adapter does not read Jitsi's Redux store (`APP.store`), per MUST-NOT #6.
  - **The bridge channel** (`lib/identity/jitsi-colibri.ts`) is the videobridge's Colibri JSON protocol, not a private store. On meet.jit.si it is an `RTCDataChannel` labelled `JVB data channel` on the bridge connection (`config.openBridgeChannel` unset); deployments set to `websocket` use `…/colibri-ws/<server>/<conference>/<endpointId>?pwd=…`. Both transports feed one parser. Only `AudioSourcesMap` and `SenderSourceConstraints` are parsed; every other message is skipped before parsing. State is bounded (one local id, at most 64 slot owners), and the socket URL and its password are never kept. Observers are added `message` listeners, installed at document_start on `jitsi` and `web` pages so the initial map is not missed. They never consume or change an event.
  - **You.** The MSID rewrite happens only in the SDP lib-jitsi-meet signals, so our own peer connection does not name us, and no DOM attribute carries the local endpoint id. It comes from the bridge channel: a `SenderSourceConstraints` message (`sourceName: "<endpointId>-v0"`), which the bridge sends only to that source's sender, or the colibri-ws URL. `SenderSourceConstraints` is only sent while you send video, so with the camera off on a data-channel deployment there may be no local id, and then nothing is flagged `isLocal`. The local id is never inferred from dominant-speaker or stats traffic. The name is `#localDisplayName` without its ` (me)` suffix. A remote tile, track or slot that names the local endpoint id is never bound.
  - The meeting is declared from the URL (`<host>[/<tenant>]/<room>`, lower-cased) once a peer connection is live: the pre-join screen and the lobby share the room's URL, and Jicofo opens no media session for someone alone in the room.
  - **Self-hosted Jitsi** is recognised by fingerprint, not hostname (`lib/identity/jitsi-detect.ts`). A `web` page (a site enabled from the popup) watches for any one of: lib-jitsi-meet's `JitsiMeetJS` global (existence only), a `lib-jitsi-meet*.js` script, a resource-timing entry for that script or for Jicofo's `/conference-request/v1`, or a remote audio stream id in Jitsi's MSID shape (`<8 hex>-audio-<n>-<pc>`, `mixedmslabel`). The first hit upgrades the page to `jitsi` and restarts the epoch with the Jitsi adapter and meeting watch. This chooses *what* a hooked page is, never *where* to hook: injection must happen at document_start, so it is still decided from the URL, and fingerprinting every site would need `<all_urls>`. The popup runs the same check (scripts and resource timing, via activeTab) on an un-enabled tab and says when it looks like Jitsi. Opening the popup also sends `recheck-platform` to every hooked frame of the active tab (`tabs.sendMessage` → content.ts → MAIN), which runs one full detection pass with a fresh budget. That catches a page whose signal appeared after the page-load scans, or whose watcher gave up. The popup lists every enabled site, each with a Remove button that also revokes its host permission.
    - **Cost is bounded, and nothing can block the page.** Detection is event-driven, never a polling loop. A `PerformanceObserver` delivers only new resource entries, batched by the browser. The script list and global are read once at `DOMContentLoaded` and once at `load`, in idle callbacks. Stream ids arrive with their tracks. `JitsiDetector` caps total CPU time at 25 ms per page load, resource URLs at 3,000 and scripts at 300 per scan, and skips URLs over 2,048 characters. Past its budget it gives up and the page stays `web`. The network observer also stops two minutes after `load`. The global is read through property descriptors, so a page-defined getter never runs. Nothing awaits, fetches or loops over unbounded data, and every callback is wrapped in `try/catch`. Measured: a worst-case scan (3,300 URLs) takes about 2 ms, a matching page matches in under 0.5 ms, and a 3,000-resource page with a hanging `JitsiMeetJS` getter loads in the same time with hooks on as off.
- **Teams** — one mixed track, no usable CSRCs. Buffered frames are attributed to the app's reported dominant speaker, emitting `Speaker N`. This is attribution, not isolation — never presented as per-participant fidelity.
- **Universal fallback is the default:** every source is already a stable anonymous handle, so an identity that never resolves costs nothing but the name. Identity is best-effort; audio is not.

### The collections exception

Decoding an app's private protobuf/Redux internals is prohibited in general (versioned, undocumented wire formats — the biggest maintenance sink). The Meet `collections` parser is the one narrow exception, bounded by these guardrails:

- Only the two documented fields (device id, speaking flag) are decoded; nothing depends on any other field.
- Parsing is defensive: any shape mismatch degrades to an unnamed source, never throws or blocks audio, and a schema self-check warns when real traffic stops matching the expected shape (plus a debug-gated structure dump for diagnosing drift).
- Tests carry real captured wire-byte fixtures, not just synthetic ones.

This does not license decoding anything else on `collections`, or Zoom's `__reduxStore`, or any other private store.

## Audio extraction

Several capture **seams**, all terminating in the same downmix → resample (streaming, phase-continuous, native rate → 16 kHz mono) → bounded circular buffer pipeline in `audio-tap.ts`. Only the frame source differs.

### Seam arbitration

Meet's internal audio path moved four times in twelve days (journal #31, #73, #82, #103) — `createEncodedStreams` tee → NetEQ SAB WASM → off the RTP receiver path → no neteq worklet at all. Each previous fix hardcoded one seam and broke on the next migration, so the seam is chosen at **runtime**, per call. Journal #82 is why per call and not per build: Meet migrates individual calls.

`capture-seams.ts` holds the pure half — the per-platform seam order and the escalation state machine (`SeamArbiter`), clock-free with timestamps injected. `audio-tap.ts` holds the DOM half.

- **Order:** `receiver-track` leads on every platform, because it is the only seam whose tracks carry identity directly. Meet then falls back `webaudio-track` → `meet-encoded-tee`. Zoom and Teams have the one seam that works; speculative fallbacks there would risk double-capture.
- **Escalation:** an `unmute` arms a grace window (`SEAM_ESCALATION_GRACE_MS`) — the platform asserting audio is flowing, so a frame must follow. No frame before it expires means the *seam* is wrong, not that the participant is quiet, and the call escalates. Waiting on `unmute` rather than on pipeline start is what stops a silent call from escalating through every seam before anyone speaks.
- **Locking:** the first decoded frame proves the seam permanently. A proven seam falling quiet is participants stopping talking, never breakage, so it must never churn.
- **Identity:** seams built on the receiver track reach the adapter's `identify()` at admission — both `receiver-track` and `meet-encoded-tee`, since the tee only supplies *frames* while its pipeline is still keyed on the receiver. Other seams' track ids never match a hooked receiver (`rtc-hook.ts`'s `installMeetWebAudioProbe`, the ids-never-match finding), so there is nothing for `identify()` to match on; their sources simply stay anonymous under their `t<n>` handles until the speaking-onset correlation names their owner. Guessing a mapping would attach a confidently-wrong name to real audio, which is worse than an anonymous handle.
- **Cloning:** non-receiver seams capture a `clone()` of the page's track. A `MediaStreamTrackProcessor` consumes the track it is given; cloning keeps the page's own playback whole.

### Seams

- **`receiver-track` (Zoom, Teams, and Meet builds that keep audio on the receiver path):** `MediaStreamTrackProcessor` reads decoded `AudioData` directly off each remote track. Construction is deferred to the track's first `unmute` — a processor built on a muted track never delivers frames, and a track allows only one processor ever.
- **`webaudio-track` (Meet):** the tracks Meet passes to `createMediaStreamSource`, registered by the passive prototype wrap in `rtc-hook.ts` and exposed as `webAudioTracks()`. On builds where the receiver tracks are live-but-silent decoys, these carry the real decoded audio, per participant, readable by the same `MediaStreamTrackProcessor` the receiver seam uses — verified live at exactly real-time (50 frames / 24000 samples in 498 ms at 48 kHz), with energy envelopes across six concurrent tracks separating into one speaker, two idle-but-live, and three at digital zero (journal #105, #106). Reuses `TrackProcessorSource` unchanged; the seam adds discovery and cloning, not a new frame source.
- **`meet-encoded-tee` (Meet, `createEncodedStreams`):** Meet's client calls `receiver.createEncodedStreams()` on every audio receiver and decodes the RTP in its own WASM pipeline, so **no `MediaStreamTrack`-based mechanism ever produces audio on Meet** — worklet, processor, and `<audio>` taps all read pure silence (confirmed via `getStats()`: `decoderImplementation=undefined`, `jitterBufferEmittedCount=0` through live speech). The fix: wrap `createEncodedStreams` in the same MAIN-world hook, `.tee()` the pre-decode readable on audio receivers (Meet's own branch passes through untouched — verified transparent in live calls), and decode our branch with the native WebCodecs `AudioDecoder` (`{codec:"opus", sampleRate:48000, numberOfChannels:1}`; every Opus chunk is `"key"`). The decoder outputs the same `AudioData` interface the standard path yields, so downstream is shared. A registry keyed on the `MediaStreamTrack` connects the tee (which fires on the receiver) to the pipeline (built on the `track` event).
  - Gate the tee on `location.host === "meet.google.com"` at hook-install time — applied elsewhere it would double-capture platforms where the standard path works.
  - Do not attempt to reach Meet's own WASM decoder (it doesn't instantiate in the page's main-world realm) — unnecessary anyway, since native `AudioDecoder` covers Opus.
  - **Decoder recovery (restart-in-place):** a single bad Opus chunk puts the whole `AudioDecoder` into a permanent error state, so `MeetDecodeSource` rebuilds it in place and keeps capturing instead of dropping the participant. It distinguishes an *isolated* error after a healthy run (≥ `DECODER_HEALTHY_FRAMES` decoded — rebuild immediately, near-zero audio loss, and reset the restart budget) from a *barren* one (a rebuilt decoder that dies before decoding anything — Meet changing bitrate/DTX mid-stream feeds a burst of frames that won't decode from a cold start). Barren restarts don't re-feed the failed window: the source cools down for `DECODER_RESTART_COOLDOWN_MS`, dropping frames, then rebuilds on the next live frame ("resume at the next decodable boundary"), which paces them at most one per cooldown so a single poisoned burst can't burn the whole budget in under a second. Only after `DECODER_MAX_RESTARTS` barren restarts within a sliding `DECODER_RESTART_WINDOW_MS` does it give up, logging a per-track summary and emitting a `capture-failed` event (relayed to the background) so the audio gap is attributable rather than looking like the source merely went quiet.

**Shared constraints:** never connect any capture path to `AudioContext.destination` and never let a normalization `<audio>` element play — double-playback and echo into the user's mic are the failures this prevents. Output format is declared to `earsd` verbatim as `{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}`. Backpressure is a bounded per-participant circular buffer, drop-oldest, with a logged counter.

## Messaging & state

- **Main → isolated:** `window.postMessage({ __ears: true, ... })`, filtered on the marker and `event.source === window`. PCM frames carry `participantId`, `seq`, `sentAt`, and the payload. `seq`/`sentAt` ride all the way to earsd on the extended ingest frame, which is what lets the daemon tell a silent speaker from a stalled extension.
- **Isolated → main:** `{ __earsCtl: true, ... }` — mirrors the capture toggle (and every change) into the page realm as `capture-state` messages.
- **Isolated → background:** PCM rides a dedicated long-lived `runtime.connect` port (`lib/pcm-port.ts`), reconnected **lazily** on the next post after a disconnect so an idle tab never traps a suspended worker in a wake loop. Control events use typed runtime messaging.
- **Respawn replay:** the content relay keeps the durable copy of what the worker holds only in memory — the live call and current participants — and replays `meeting-started` + `joined` into every *fresh* port ahead of the message that triggered the reconnect. A respawned worker therefore re-learns which session the tab's audio belongs to (the daemon-side verbs are idempotent), so it can tag `ingest.open` with the session identity and send `session.end` when the tab goes away. Without the replay, an evicted-mid-call worker forwards PCM it can't attribute and has nothing to end — the stranded-active-session bug.
- **Session lifecycle:** `session-tracker.ts` (in the background) is a signal forwarder — the daemon owns the session state machine ([control protocol v2](../control-protocol.md)). It translates what the tabs' DOM layers observe into daemon verbs over the `/control` WebSocket: the platform's `meeting-started` signal → `session.start` (idempotent on platform + external meeting id), a scraped meeting name → `session.rename`, participant join/leave and ingest-stream opens → `session.attendee` upserts, the popup's pause toggle → `session.pause`/`session.resume` (marks, never capture), `meeting-ended` or the tab going away → `session.end`. Recovery after worker eviction or daemon restart is re-declaration through the same idempotent `session.start`.

### Meeting name

The session's title is what the daemon files the transcript under (`{title}` in a path template, see [configuration](../../configuration.md#path-templates)), so a calendar-created call should carry its real name rather than a UUID.

`lib/identity/meet-meeting-title.ts` reads it, on the same poll the meeting-id watcher runs on:

- **`document.title`** is the load-bearing surface. `stripProductName` handles both orderings ("Meet – X", "X - Google Meet") and the "(3) " notification prefix rather than pinning one exact spelling.
- **The in-call details heading** is a fallback. Its selectors are **unverified against a live Meet build**; a miss costs nothing, since the title path already covers the common case.
- A **meeting-code-shaped string** (`xxx-yyyy-zzz`) counts as *no name found*. Filing a transcript under the join code is worse than the daemon's own default (identity → Meet id), which at least stays stable.

A name known at declare time rides along on `session.start` as `title`. Calendar names usually resolve a few seconds after join, so a late one goes out as `session.rename` with `if_rev` — a compare-and-set, so a rename the user made by hand is never clobbered, and a lost compare-and-set is never retried. At most one rename per session. Teams and Jitsi read the tab title the same way (Jitsi prefers the conference-info subject, `.subject-text--content`, and drops the ` | <app name>` suffix). Zoom (`lib/identity/zoom-dom.ts`) sends a title only for a real meeting topic: the web client's own screen names ("Zoom meeting on web"), host-named default topics, the meeting id and the local user's name are refused, and the daemon's roster title stands. Its attendees come from the tile name overlays as `zoom-name:<lowercase name>`; the local user is flagged only from the participants panel's "(me)" marker or the pre-join name field, and stays unflagged without one.
- **Persisted state:** `storage.local` holds the user-facing capture toggle (explicit privacy intent — survives browser restart; missing/corrupt values default to ON so a failed read can't silently kill capture). `storage.session` holds worker-respawn recovery (active-session flag re-arms the `chrome.alarms` keepalive; session area so a fresh browser start can't resurrect a stale alarm). The keepalive is armed only while ≥1 participant is live — an idle extension schedules zero wakes.

## Performance instrumentation

Everything the capture path does runs in the MAIN world, on the same thread the
meeting UI renders video on. These metrics exist to say whether that costs the
user anything, and if so which stage. They land in their own IndexedDB ring
(never the console ring, which would evict a call's log history) and export
from the popup as `ears-perf-*.jsonl`.

| Metric group | Fields | Tier |
|--------------|--------|------|
| `video` | `frames_dropped`, `frames_decoded`, `fps`, `freeze_count`, `freeze_ms`, `packets_lost`, `jitter_buffer_ms` | 1 |
| `longtask` | `task_n`/`task_p95`/`task_max`, `blocking_ms` | 1 |
| `capture` | per-stage histograms (`downmix`, `speaking`, `debuglog`, `resample`, `accumulate`, `post`, `frame`), `frames`, `posted`, `tracks`, `decode_queue` | stage timing is tier 2 |
| `relay` | `encode` (base64 histogram), `frames`, `bytes`, `dropped` | 1, timing tier 2 |
| `transport` | `buffered_bytes`, `frames_sent`, `frames_dropped`, `frames_queued` | 1 |
| `heap` | `used_bytes`, `allocated_bytes`, `reclaimed_bytes`, `collections` | 2 |

- **Tier 1** is on by default (`perfLogging`, defaults ON): one timer per
  context plus a `getStats()` poll every 5s.
- **Tier 2** (`perfDetail`, defaults OFF) adds `performance.now()` pairs inside
  the per-audio-frame path and heap sampling. Cheap per call, but it runs ~50×/s
  per active speaker on the render thread, so it stays opt-in.
- Perf records **must not** go through the console tap (`debug-log.ts`), whose
  synchronous serialization runs on the thread being measured. They travel as
  structured objects on their own message kind.
- Hot-path instruments **must not** allocate per observation — histograms are
  preallocated typed arrays and objects are built only at flush.

Records carry `platform` and `meeting` tags, and the daemon labels its
own capture events with the same `browser:<platform>:<participant>` source, so
the two log streams join on timestamp and source. See `docs/logging.md` for the
daemon half.

## Meet audio-graph probe

Meet builds (rolled out per call, 2026-07-24 capture) decode participant Opus
inside WASM (NetEQ over SharedArrayBuffer) and play out through
`AudioWorkletNode(processor="neteq-processor")` — encoded frames never enter
JS, the `createEncodedStreams` tee reads nothing, and the receiver tracks stay
live-but-silent. The graph probe (`lib/rtc-hook.ts` §graph probe +
`lib/meet-audio-graph.ts`) instruments the WebAudio graph those builds actually
use, to answer one question: **is the decoded audio still per participant
(capturable) or already mixed before anything tappable?**

Hard constraint (journal #93, live-verified 2026-07-29): adding an output edge
to Meet's `neteq-processor` worklet — an `AnalyserNode`, a destination node,
anything — trips a Chromium `CHECK` on the realtime audio-worklet thread and
kills the renderer within seconds. No attach ordering makes it safe, and no
page-side `try/catch` can contain it. **Nothing in the extension may ever
connect anything to an `AudioWorkletNode` it did not create.**

- **Graph mapping** (`localStorage.__earsDebugAudio = "1"`): pass-through wraps
  on `AudioNode.prototype.connect`/`disconnect` and the `AudioWorkletNode`
  constructor feed a bounded registry (`GRAPH_MAX_NODES`) of node types,
  worklet processor names, `createMediaStreamSource` input track ids, and
  fan-in/out. The native call always runs first and its result is returned
  untouched; all bookkeeping is try/caught and pure JS — it never touches the
  render graph, so it cannot crash a call. A 15 s timer emits
  `meet_graph_summary` (counts) and, every other tick, `meet_graph_topology`
  (the graph as flat fields) into the IndexedDB perf ring, which survives
  Meet's post-call redirect. Counters surface in the popup's debug report
  (`hookDebugState().graph`, `webaudio.netEqWorkletNodes`). Track-level peak
  meters run in the probe's **own** `AudioContext` (never Meet's graph).
- **Capture bridge** (`localStorage.__earsGraphBridge = "1"`, OFF by default,
  independent of the probe flag): when Meet connects a `neteq-processor`
  worklet to a **native** node, that downstream node is branched into a
  `MediaStreamAudioDestinationNode` and its stream fed through the REAL
  capture pipeline (`__devCaptureStream`) under `graphtap-<n>` ids — one tap
  per distinct target, capped at `GRAPH_BRIDGE_MAX_NODES`. The worklet keeps
  exactly the edges Meet gave it. If the graph is per-participant the daemon
  records separate streams; if it is mixed, the recordings prove that — either
  way the verdict is ground truth from audio, not inferred from envelopes. An
  audio-kind `MediaStreamTrackGenerator` — a `MediaStreamTrack` already —
  bridges directly as `graphgen-<n>` with no graph mutation at all. A
  sink-shaped downstream target (zero outputs) is recorded as
  `untappable-sink` rather than branched. Capture-off severs every bridge
  branch (`stopMeetGraphProbe`) so an idle extension never keeps Meet's graph
  pulled.
- Probe output carries node ids, track ids, processor names, and counts only —
  never participant display names.

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
12. No `ScriptProcessorNode`/`MediaRecorder` for PCM. (This rule previously also banned `MediaStreamTrack`-based capture on Meet, on the grounds that the tee was the only mechanism that worked there. Journal #105 disproves it: on current builds the receiver tracks are silent but the `createMediaStreamSource` tracks carry real per-participant audio to an ordinary `MediaStreamTrackProcessor`. Which mechanism works on Meet is now decided at runtime — see Seam arbitration — not fixed by this spec.)
13. No unbounded PCM queues — bounded circular buffer, drop-oldest, logged counter.
14. No connecting anything to an `AudioWorkletNode` the extension did not create — an extra output edge on Meet's neteq worklet crashes the renderer from the realtime audio thread (journal #93). Tap the native node downstream instead.
