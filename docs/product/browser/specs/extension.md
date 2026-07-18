# Spec: capture extension

## One job

Intercept the meeting page's `RTCPeerConnection`s, isolate each remote participant's audio track into its own 16 kHz mono PCM stream tagged with a stable participant id, and forward those streams to the background context, which streams them to earsd's loopback WebSocket. Identity resolution is the only platform-specific part; everything else is shared.

### Responsibilities

- Install a `RTCPeerConnection` constructor wrapper in the page's main world **before the page constructs its first connection**.
- Capture every remote audio track (added at join or mid-call), one isolated pipeline per track, surviving mute/replace/re-subscribe.
- Resolve each track to a stable participant id via the active platform adapter, degrading to `Speaker N` rather than blocking audio.
- Convert each isolated stream to 16 kHz mono `pcm_s16le` off the main thread, without playing it back.
- Relay tagged PCM frames and participant lifecycle events to the background context, which owns the WebSocket to earsd.

### Explicit non-responsibilities

- Does **not** open the socket to earsd or speak its protocol — that is [`transport.md`](transport.md).
- Does **not** transcribe, diarize, or run models.
- Does **not** mutate SDP, transceiver direction, or any peer-connection state — it is a passive listener (see [MUST-NOT](#constraints--must-not)).
- Does **not** capture the local user's mic or the mixed tab.

## Architecture

Four contexts, one direction of audio flow:

```
 page main world            isolated world        background            local daemon
┌────────────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ injected.ts        │     │ content.ts   │     │ background.ts│     │ earsd        │
│  RTCPeerConnection │     │  (relay)     │     │  WebSocket   │     │ ws://127.0.0.1│
│  hook + track tap  │ ──► │ postMessage  │ ──► │ owner +      │ ──► │  /ingest      │
│  AudioWorklet→PCM  │ win │  ⇄ runtime   │ rt  │ control plane│ ws  │ (loopback)    │
│  platform adapter  │     │              │     │              │     │              │
└────────────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
   generates PCM             CSP-safe bridge      holds the socket     defined in
                                                                       transport.md
```

- **win** = `window.postMessage` (only channel across the main/isolated world boundary).
- **rt** = `chrome.runtime` messaging (`browser.*` under WXT).
- **ws** = WebSocket to loopback earsd (`ws://127.0.0.1:<port>/ingest`).

The main world is the only place that can patch page globals; the isolated world is the only place with `chrome.runtime`. The hop through `content.ts` exists solely to cross that boundary. There is **no offscreen document** — an MV3 service worker holds the WebSocket directly (WebSocket activity keeps it alive, Chrome 116+), so no CSP-free context is needed, and Chrome and Firefox stay on one code path.

## WXT project layout

```
browser/
  wxt.config.ts
  package.json
  tsconfig.json
  entrypoints/
    hook.content.ts    # MAIN world content script (world:"MAIN", document_start). Hook + tap + adapters.
    content.ts         # ISOLATED world, runAt document_start. postMessage ⇄ runtime relay.
    background.ts       # WebSocket owner (earsd ingest) + typed control plane.
    popup/              # on/off toggle + connection indicator.
    pcm-worklet.ts      # AudioWorkletProcessor. Emitted as a web-accessible asset.
  lib/
    rtc-hook.ts         # constructor/track interception + RTCRtpReceiver.createEncodedStreams
                        # tee (Meet audio path — see §Audio extraction). Imported by hook.content.ts.
    audio-tap.ts        # per-track pipeline + N→N map. Frame source is platform-dependent:
                        # MediaStreamTrackProcessor (standard) or the tee'd/decoded encoded
                        # stream (Meet) — see §Audio extraction.
    identity/
      adapter.ts        # PlatformAdapter interface + registry/detection.
      meet.ts  zoom.ts  teams.ts
    protocol.ts         # message types shared across contexts (one source of truth).
    epoch.ts            # idempotent-install guard + capture epoch.
```

`wxt.config.ts` declares both targets and the manifest surface:

```ts
export default defineConfig({
  manifest: {
    name: "ears capture",
    permissions: ["storage", "alarms"],
    host_permissions: [
      "https://meet.google.com/*",
      "https://*.zoom.us/*",
      "https://teams.microsoft.com/*",
      "ws://127.0.0.1/*",   // background WebSocket to loopback earsd (add if the browser requires it)
    ],
    web_accessible_resources: [
      { resources: ["pcm-worklet.js"], matches: ["<all_urls>"] },
    ],
  },
});
```

Build both browsers with `wxt build` / `wxt build -b firefox --mv3`. WXT generates MV3 for both; the only per-browser code is the transport-host lifetime in `background.ts` (§Messaging).

Patterns lifted from WXT examples: `web-worker-setup` (Vite worker/worklet bundling — **but see the AudioWorklet caveat in §Audio**), `background-message-forwarder` (runtime relay shape), `content-script-session-storage` (`storage` session state), `basic-messaging` (typed control plane).

## Injection & timing

The MAIN-world hook is registered as a `world: "MAIN"` content script at `document_start` (`hook.content.ts`); the isolated-world `content.ts` is the postMessage ⇄ runtime relay:

```ts
// hook.content.ts — MAIN world, page realm
export default defineContentScript({
  matches: ["https://meet.google.com/*", "https://*.zoom.us/*", "https://teams.microsoft.com/*"],
  runAt: "document_start",
  world: "MAIN",
  main() {
    installHook();          // wrap RTCPeerConnection before the page's first `new`
    startCapture();         // claim epoch, wire the tap
  },
});
```

**Why `world: "MAIN"` and not `injectScript`.** The original spec used WXT `injectScript`, but in MV3 that inserts an async `<script src=…>` whose fetch loses the race against the page's earliest inline script. Verified empirically (roadmap Phase 1, synthetic-harness journal entry): with `injectScript` the page cached the **native** `RTCPeerConnection` at head time and the hook caught **0 of 3** loopback tracks; as a `world: "MAIN"` content script the hook installed before the page's head script and caught **all** tracks. A `world: "MAIN"` content script is registered by the browser to run before page scripts with no fetch race. Firefox has supported `world: "MAIN"` content scripts since v128 (the portability concern that motivated `injectScript` is resolved); keep the install behind `rtc-hook.ts` so a fallback injection can be swapped in per-browser if ever needed.

- **Zoom is the strictest case:** it caches the `RTCPeerConnection` constructor at bootstrap, so a late wrapper catches none of its connections. The `world: "MAIN"` document_start registration wins that race; verify on a cold load (roadmap Phase 1 exit).
- **Idempotent install guard** (`lib/epoch.ts`): the hook sets `window.__earsHookInstalled` and no-ops on a second install.
- **Capture epoch:** each hook instance claims a monotonically higher epoch on a shared `window` key; only the newest epoch emits PCM, and superseded instances tear down (adopting the live-track registry so no stream drops). This is what makes SPA navigations and extension reloads (which re-inject) safe against 2–3× duplicated audio.

## RTCPeerConnection hook contract

`lib/rtc-hook.ts` wraps the constructor, preserving native behavior:

```ts
const Original = window.RTCPeerConnection;
function Wrapped(this: unknown, ...args: any[]) {
  const pc = new Original(...args);
  onPeerConnection(pc);                 // register + attach track listeners
  return pc;                            // returning the real pc supersedes `this`
}
Wrapped.prototype = Original.prototype; // instanceof stays true
Object.setPrototypeOf(Wrapped, Original); // inherit static methods (generateCertificate…)
window.RTCPeerConnection = Wrapped as any;
```

Per connection, capture tracks two ways and never let the page shadow the hook:

```ts
function onPeerConnection(pc: RTCPeerConnection) {
  pc.addEventListener("track", onTrack);
  const desc = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, "ontrack");
  if (desc?.set) {
    Object.defineProperty(pc, "ontrack", {
      set(h) { desc.set!.call(this, (e: RTCTrackEvent) => { onTrack(e); return h?.call(this, e); }); },
      get: desc.get, configurable: true, enumerable: true,
    });
  }
}

function onTrack(e: RTCTrackEvent) {
  if (e.track.kind !== "audio") return;
  const stream = e.streams[0] ?? new MediaStream([e.track]);
  capturePipeline(e.track, stream, e.transceiver);   // §Track isolation
}
```

**MUST NOT** in this layer:
- Do **not** enumerate `getReceivers()` / `getTransceivers()` to discover tracks — it breaks when Zoom wraps tracks. Use the `track` event only.
- Do **not** read from or mutate `e.transceiver` beyond passing it to the adapter as an opaque correlation handle. Never set `transceiver.direction`. Never munge SDP or call `setLocalDescription`/`createOffer` on the intercepted connection.

## Track isolation & lifecycle

`lib/audio-tap.ts` owns a map keyed on the live `MediaStreamTrack` object — N tracks, N independent pipelines (the shape proven by the Twilio reference, minus the SDK identity):

```ts
interface Pipeline { participantId: string; generation: number; node: AudioWorkletNode; stop(): void; }
const pipelines = new Map<MediaStreamTrack, Pipeline>();
const generations = new Map<string, number>(); // participantId → monotonic segment counter
```

- **Start** (on `track`): resolve identity (§Identity), bump the participant's generation, build one `AudioContext` source → worklet, store it. A gone-and-back participant starts a fresh segment under the same id — never mutate a live pipeline across a drop.
- **Stop**: on `track.onended` / receiver removal, delete from the map before calling `stop()`, so a late frame can't resurrect a dead entry. Emit a `participant-left` control event.
- **Mute/replace**: `track.onmute` / `onunmute` gate emission; `onended` ends the segment. Teams delivers tracks `muted=true` until first speech — accept enabled-but-muted tracks.
- **Zoom/Teams normalization:** when the page exposes no per-participant `<audio>` element, the hook mirrors each remote track into a hidden `<audio srcObject=stream>` (offscreen-positioned, `autoplay`, but routed to a **muted** graph — see §Audio) so identity correlation and capture use the same per-element model as Meet.

## Platform adapter

Identity is the fragile part; it lives entirely behind one interface (`lib/identity/adapter.ts`), selected by hostname. The capture spine never branches on platform.

```ts
export type ParticipantId = string; // stable within a call; used verbatim as the earsd source label suffix

export interface PlatformAdapter {
  readonly platform: "meet" | "zoom" | "teams";
  /** Best-effort stable id for a remote track. null → caller assigns Speaker N. */
  identify(track: MediaStreamTrack, stream: MediaStream, transceiver: RTCRtpTransceiver): ParticipantId | null;
  /** Optional: human label for a participant id, for logs/UI. */
  displayName?(id: ParticipantId): string | undefined;
  /** Optional teardown of observers. */
  dispose?(): void;
}

export function selectAdapter(host: string): PlatformAdapter; // meet.google.com → MeetAdapter, etc.
```

- **`meet.ts`** — Meet renders a per-participant `<audio>`/`<video>` per tile. Correlate the captured stream to its tile and read `data-participant-id` (+ display name from the tile). A `MutationObserver` maintains the tile↔stream map; the CSRC `audioLevel` path (`RTCRtpReceiver.prototype.getContributingSources`) is the documented fallback if a build stops exposing per-tile elements. **Confidence: medium — verify which holds on the current Meet build (roadmap Phase 4).**
- **`zoom.ts`** — parse the participant id directly from the stream/MSID: `decodeURIComponent(streamId).match(/^(\d+)\+/)`, then `Number(m[1]) >> 10 << 10`, gated on the id containing `+CS+`. Intrinsic to the track, stable across mute/re-subscribe. **Confidence: high.**
- **`teams.ts`** — one mixed track, no usable CSRCs. Attribute buffered frames to the app's reported dominant speaker at the frame's arrival time, emitting `Speaker N`. **Confidence: low — this is attribution, not isolation; never present it as true per-participant.**
- **Universal fallback:** when `identify` returns `null`, assign a stable `speaker-<n>` keyed to the track/transceiver so audio still flows. Identity is best-effort; audio is not.

Do **not** decode any app's private protobuf or Redux store for identity (Meet `collections` datachannel, Zoom `__reduxStore`) — versioned to undocumented wire formats, the largest maintenance sink. Prefer DOM/MSID signals.

## Audio extraction

Two capture mechanisms, selected per platform. Both terminate in the same resample → 16 kHz mono `pcm_s16le` → bounded ring buffer pipeline in `audio-tap.ts`; only the *frame source* differs.

### Standard path — `MediaStreamTrackProcessor` (Zoom, Teams; assumed — verify per platform)

Read decoded audio frames directly off the remote `MediaStreamTrack` via the WebCodecs breakout box (`new MediaStreamTrackProcessor({ track }).readable`), not `AudioWorklet`. This supersedes the original design (`AudioWorkletNode` fed by `ctx.createMediaStreamSource(stream)`): a `MediaStreamAudioSourceNode` needs a live-playing `<audio>` element and, in this codebase's testing, read digital silence off remote tracks; `MediaStreamTrackProcessor` needs neither and reads real audio directly.

- Construction is **deferred until the track's first `unmute`** — a `MediaStreamTrackProcessor` built on a muted track never delivers frames, even after the track unmutes, and a track allows only one processor ever.
- Each `AudioData` frame is downmixed to mono, run through a streaming linear resampler (native rate → 16 kHz, phase-continuous across chunks), sliced into fixed-size frames, and pushed onto the per-participant ring buffer.
- `pcm-worklet.ts` (the original `AudioWorkletProcessor` approach) is retained only as a fallback if `MediaStreamTrackProcessor` is ever unavailable on a target browser — do not build new capture logic against it.

### Meet path — encoded-stream interception (validated; standard path does not work on Meet)

**Empirically confirmed** (journal `#28`–`#31`, live-call testing): Google Meet's client calls `receiver.createEncodedStreams()` on every audio receiver (the legacy pre-standard insertable-streams API) roughly 2 seconds after connect, diverting the raw encoded RTP to its own WASM NetEQ decode + playback pipeline *before* the browser's native decoder ever sees it. Evidence: `getStats()` inbound-rtp shows `decoderImplementation=undefined` and `jitterBufferEmittedCount=0` for the entire call, including active speech, while `bytesReceived`/`packetsReceived` climb normally; a `MediaStreamTrackProcessor` on the raw track delivers zero frames; a `MediaStreamAudioSourceNode` WebAudio tap reads `peak=0.0000` throughout. **No `MediaStreamTrack`-based mechanism — `AudioWorklet`, `MediaStreamTrackProcessor`, or an `<audio>` element — can ever produce audio for a Meet remote participant on this build.** This is a platform constraint, not a capture bug; do not spend further effort debugging the standard path against Meet.

The validated fix: intercept the same call Meet makes, before it does any damage.

```ts
// lib/rtc-hook.ts — wrapping RTCRtpReceiver.prototype.createEncodedStreams,
// installed in the same MAIN-world/document_start hook as the RTCPeerConnection wrap.
proto.createEncodedStreams = function (...args) {
  const streams = nativeCreateEncodedStreams.apply(this, args); // { readable, writable }
  if (this.track?.kind !== "audio") return streams;             // video: pass through untouched
  const [ours, theirs] = streams.readable.tee();
  decodeEncodedAudio(ours, this.track);   // our independent Opus decode → PCM, keyed by track
  return { readable: theirs, writable: streams.writable };      // Meet's own branch, untouched
};
```

- `.tee()` on the pre-decode `readable` is **transparent**: validated live that Meet's branch keeps working normally (call never drops, `getStats` bytes/packets keep climbing, video/UI unaffected) with 1 and 2 simultaneous remote participants and zero cross-talk between their tee'd streams.
- Decode the tee'd branch's frames (`{data: ArrayBuffer, timestamp}`, raw Opus payload) with the native `AudioDecoder` (WebCodecs): `new AudioDecoder({ output, error }).configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 1 })`, then `decode(new EncodedAudioChunk({ type: "key", timestamp: frame.timestamp, data: frame.data }))` per frame (Opus has no inter-frame prediction, so every chunk is `"key"`). Confirmed supported on this build via `AudioDecoder.isConfigSupported(...)` → `{supported: true}` — no bundled/reverse-engineered decoder needed.
- `AudioDecoder`'s `output` callback delivers real `AudioData` objects — the **same interface** `MediaStreamTrackProcessor`'s reader yields — so the existing downmix → resample → ring-buffer logic in `audio-tap.ts` needs no Meet-specific branch once frames reach it. Only the *source* (processor-reader vs. decoder-output) differs; design `audio-tap.ts`'s per-track pipeline around a pluggable frame source so both platforms share one consumer.
- **Wiring the tee to the right pipeline:** the tee happens inside the `createEncodedStreams` wrap (which only has `this` = the `RTCRtpReceiver`, hence `this.track`), while `audio-tap.ts` builds its per-participant pipeline off the separate `track` event. These fire independently (close in time, not ordered). Use a small registry keyed on the `MediaStreamTrack` — analogous to `rtc-hook.ts`'s existing `liveTracks()` pattern — so `audio-tap.ts` can look up "does this track have a tee'd encoded-audio source" when it builds the pipeline, on Meet.
- **Do not** attempt to call into or reverse-engineer Meet's own WASM NetEQ decoder. A `WebAssembly.instantiate`/`instantiateStreaming`/`Instance` probe installed in the same MAIN-world realm confirmed the real decoder never instantiates there — only one small, unrelated zero-export WASM blob was observed — so it almost certainly runs inside a Worker/AudioWorklet global scope this hook architecture can't reach without much higher effort (worker-script rewriting or CDP `Debugger` domain). It's unneeded anyway: native `AudioDecoder` already covers Opus decode.
- Gate this path on the resolved platform (Meet only) at hook-install time — `location.host === "meet.google.com"`, not through `audio-tap.ts`'s capture-epoch config, which isn't populated until after `installHook()` runs. Applying the tee unconditionally would double-capture on platforms where the standard path already works.

### Shared constraints (both paths)

- **No playback:** never connect any capture path (worklet, processor, or decoder output) to `AudioContext.destination`, and never let the hidden `<audio>` element used for Zoom/Teams normalization play to the user's speakers — double-playback and echo into the user's own mic are the failure this prevents.
- **Format:** 16 kHz, 1 channel, signed 16-bit little-endian. Declared to earsd verbatim as `{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}`. earsd derives its own ASR rate; sending 16 kHz directly is accepted.
- **Back-pressure:** `audio-tap.ts` holds a bounded ring buffer per participant. On overflow, drop the oldest frame and increment a logged `dropped` counter — never grow an unbounded queue. Mirrors earsd's own dropped-sample-counter policy.

## Messaging

- **Main → isolated:** `window.postMessage({ __ears: true, ... }, "*")`, filtered by the `__ears` marker and `event.source === window`. The only cross-world channel. PCM frames carry `participantId`, `seq`, and the `Int16Array` payload (transferable within the world, structured-cloned across it — ~32 KB/s/participant, negligible).
- **Isolated → main:** `window.postMessage({ __earsCtl: true, ... }, "*")` — the reverse channel (Phase 7), existing solely because the MAIN world has no extension APIs. `content.ts` reads the capture toggle from storage and mirrors it (and every later change) across as a `capture-state` message; `hook.content.ts` installs the constructor hook unconditionally (it must win the document_start race regardless, or mid-call enable could never work) but defers capture start until the state arrives, and supersedes the live epoch on OFF — the same teardown path a re-injection uses.
- **Isolated → background:** `browser.runtime` messaging. `content.ts` forwards PCM and lifecycle events; nothing else lives here. The "pcm" port reconnects **lazily** — on the next post after an observed disconnect, not eagerly in `onDisconnect` — so an idle meeting tab never traps a suspended worker in a wake/idle-out loop (`lib/pcm-port.ts`).
- **Control plane:** typed messages (`@webext-core/messaging`, per the WXT `basic-messaging` example) for start/stop, participant join/leave, and status. Keep the hot PCM path off the typed RPC to avoid per-frame overhead; PCM rides a dedicated long-lived `runtime.connect` port to the background.
- **Persisted state**, split across two areas on purpose (Phase 7 supersedes this spec's earlier single-area sketch):
  - `storage.local` — the user-facing capture toggle (`lib/capture-toggle.ts`). Turning off an audio-capture extension is explicit privacy intent and must survive a browser restart; defaulting missing/corrupt values to ON means a failed read can never silently kill capture.
  - `storage.session` — worker-respawn recovery (`lib/session-state.ts`): the active-session flag + platform, written when the first participant's PCM arrives and cleared when the last leaves. A respawned worker's top level reconnects the WebSocket and streams re-open lazily on the next frame anyway; this state exists so the respawn also re-arms the `chrome.alarms` keepalive *before* audio flows again. Session area, not local: a fresh browser start must not resurrect a stale alarm.

Everything downstream of `background.ts` — the WebSocket to earsd, the ingest handshake, per-participant `stream_id` mapping — is [`transport.md`](transport.md).

## Constraints & MUST-NOT

The anti-patterns from [`DESIGN_BRIEF.md`](../DESIGN_BRIEF.md) §4, as enforceable rules:

1. No whole-tab/display capture (`tabCapture`, `getDisplayMedia`, `chromeMediaSource:"tab"`).
2. No mixing sources into one `MediaStreamDestination`.
3. No caption/transcript DOM scraping as an audio source.
4. **No mutating `transceiver.direction` or SDP** — the "execution-context-destroyed" crash class (~44% of Meet sessions in the surveyed bot). We are passive.
5. No `getReceivers`/`getTransceivers` enumeration for track discovery — use the `track` event.
6. No decoding an app's private protobuf/Redux internals for identity.
7. No trusting dominant-speaker as isolation (Teams degrades to `Speaker N`, labeled as such).
8. No per-frame single-winner CSRC that silently drops simultaneous speakers.
9. No routing captured audio to `AudioContext.destination`.
10. No long-lived audio/transport in the service worker beyond the earsd WebSocket (no capture there).
11. No `Object.keys` static copy on the constructor — use `Object.setPrototypeOf`.
12. No install without the idempotent guard and capture epoch.
13. No swallowing injection-order errors — surface them; a silent failure records zero audio while reporting success.
14. No `ScriptProcessorNode` or `MediaRecorder` for PCM — `MediaStreamTrackProcessor` (standard path) or the `AudioDecoder`-fed pipeline (Meet path) only.
15. No unbounded PCM queues — bounded ring buffer, drop-oldest, logged counter.
16. No relying on `AudioWorklet`/`MediaStreamTrackProcessor`/`<audio>` for Meet audio — confirmed empirically that none of them ever receive a frame there (§Audio extraction). Use the `createEncodedStreams()` tee.
17. No reverse-engineering or calling into Meet's own WASM NetEQ decoder — confirmed unreachable from the main-world realm and unnecessary given native `AudioDecoder` Opus support (§Audio extraction).
18. No applying the `createEncodedStreams()` tee outside Meet — it would double-capture platforms where the standard `MediaStreamTrackProcessor` path already works. Gate on platform at hook-install time.
