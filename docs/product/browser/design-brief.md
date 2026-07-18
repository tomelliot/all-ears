# Per-participant audio capture extension — design brief

MV3, TypeScript, Chrome-first. Runs inside a call the user has already joined. Intercepts the page's WebRTC peer connections, isolates each remote participant's audio, and streams each per-participant PCM feed to a separate local process for transcription. No meeting-join, no bots, no headless browsers, no tab capture. Optimized for a small codebase one maintainer can hold in their head.

---

## 1. Repo review — adopt / avoid / portability

### `ggarber/webrtc-intercept` — the core primitive
Documentation-only (a single README). One recipe: replace the `RTCPeerConnection` constructor with a plain function that news-up the real PC and returns it, keeping `prototype = orig.prototype`. No track handling exists — isolation is entirely net-new for us.

| Adopt | Avoid | Portability |
|---|---|---|
| Return-the-inner-`pc` construction trick (a constructor returning an object supersedes `this`, so callers get a 100% native PC). `prototype = orig.prototype` for `instanceof` safety. Bind-then-wrap for instance methods. | `Object.keys` static-copy (misses non-enumerable statics like `generateCertificate`). `webkit`/`moz` aliases, DTMF/DSCP examples. Bare `window.pcs` global. | Maps cleanly onto a MAIN-world `document_start` content script — that *is* the "install before the page runs" guarantee the README asks for by hand. Modernize: use `Object.setPrototypeOf(wrapper, Orig)` (inherits statics) and add the missing `ontrack` isolation layer. |

### `recallai/chrome-recording-transcription-extension` — the MV3 skeleton
A real MV3 extension. Correct plumbing, wrong audio path (whole-tab capture + caption DOM scraping).

| Adopt | Avoid | Portability |
|---|---|---|
| The **SW-as-coordinator / offscreen-as-media-worker** split (MV3 SW has no DOM/`getUserMedia`). Offscreen lifecycle guard: `getContexts` → `createDocument({reasons})` → ping → port-ready. Long-lived `Port` + `__id`/`__respFor` RPC. `web_accessible_resources` exposure of `offscreen.html`. Module SW. Webpack multi-entry + copy-manifest build, `@types/chrome`, strict TS. `chrome.storage.session` for state a respawned SW recovers. | `tabCapture.getMediaStreamId` → `chromeMediaSource:'tab'` — taps the tab's **post-mix** output; no access to individual inbound tracks. Fails per-participant by construction. `mixAudio`'s single `MediaStreamDestination` (collapses sources — the opposite of the goal). Caption DOM scraping (`.ygicle`/`.NWpY1d` — obfuscated, text-only, no PCM). | Keep the manifest scaffold, SW↔offscreen port/RPC, offscreen bootstrap, build. **Rip out the entire capture core and the caption scraper.** Key lifetime lesson: the offscreen document is **not** subject to the ~30s SW idle suspension — put all long-lived audio + transport there, treat the SW as a stateless controller. |

### `Vexa-ai/vexa` — the battle-tested live track hook
Read only the in-page code (`webrtc-audio-hook.ts`, formerly `screen-content.ts`; `inpage.ts`). The most production-hardened `RTCPeerConnection` track hook across Meet/Teams/Zoom-web, already extracted into an extension-ready, Node-free module.

| Adopt | Avoid | Portability |
|---|---|---|
| Constructor wrapper + per-instance `addEventListener('track')` **and** an `ontrack`-setter wrapper (so a page handler can't shadow the hook). Idempotent install guard (`__hookInstalled`). Trust `event.transceiver`/`event.streams[0]`; **do not** scan `getReceivers()/getTransceivers()` (breaks when Zoom wraps tracks). The **mirror-into-hidden-`<audio srcObject>`** trick to normalize Zoom/Teams to Meet's per-element model. `AudioWorklet` → 16 kHz mono PCM. **Capture-epoch** guard against re-injection double-capture. Per-channel active-speaker onset correlation for identity. | Everything virtual-camera (`addTrack`/`replaceTrack`/`createOffer`/`enumerateDevices` faking). `MediaRecorder`→webm/opus 30s-chunk upload. RMS `ScriptProcessor` alone-detection. DOM participant-count "alone" timeouts. Playwright bridge globals. | `webrtc-audio-hook.ts` is pure browser code — port near-verbatim into a `world:"MAIN"`, `document_start` content script. Replace the `page.evaluate`/`window.__vexa*` bridge with `window.postMessage` → ISOLATED content script → `chrome.runtime`. No CDP/`addInitScript` needed. |

**Lessons from git history (load-bearing):**
- **The "Execution context destroyed" crash class (~44% of Meet meetings).** Setting `transceiver.direction = 'sendonly'/'inactive'` in `ontrack` (done to free the video decoder's ~300 MB) triggers renegotiation emitting self-contradictory SDP (BUNDLE on, `rtcp-mux` missing on `m=video`); Chrome rejects `setLocalDescription` with `InvalidAccessError`; the peer degrades over ~60s; Meet severs the session and navigates away; the injected context dies. Teams reproduced it 44 ms post-admission. **Rule: never mutate `transceiver.direction` and never munge SDP from an injected script.** We are passive listeners — this is free to obey.
- **Injection ordering:** utilities must be installed before the capture pipeline constructs, or classes are `undefined` and the error is silently swallowed by a promise chain → records zero audio while reporting success. Install order matters; surface errors.
- **Re-injection races** (SPA nav, extension reload) → 2–3× duplicated PCM. Fixed with a monotonic capture epoch: newest instance wins, older instances self-stop.
- **Don't fight the decoder in-page** (Zoom): five suppression approaches all failed or spiked CPU. Irrelevant to us (we only read audio) — noted so we don't try.

### `attendee-labs/attendee` — track→identity mapping (the crux)
Read only the injected payloads under `bots/`. No single strategy — each platform correlates differently, dictated by how it ships audio.

| Platform | Audio delivery | Correlation | Stability |
|---|---|---|---|
| **Zoom** | 1 track / participant | participant id parsed from the **MSID** (`nodeId >> 10 << 10`) | strongest — intrinsic to the track |
| **Meet** | mixed track | loudest **CSRC `audioLevel`** (via `RTCRtpReceiver.getContributingSources`) → streamId → `deviceId`, table decoded from Meet's protobuf datachannel | good identity, **heuristic per-frame** attribution |
| **Teams** | single mixed track | dominant-speaker at timestamp (+2s buffer) | weakest — no true isolation |

| Adopt | Avoid | Portability |
|---|---|---|
| The **framing envelope** `[int32 type][uint8 idLen][id UTF-8][Float32 PCM]` + out-of-band JSON `AudioFormatUpdate` (sampleRate/channels changes). Consumer-agnostic, trivially portable. Insertable-streams tap (`MediaStreamTrackProcessor`→`TransformStream`) as an alternative to AudioWorklet. Zoom MSID parsing. Meet CSRC `audioLevel` as the right primitive for a mixed track. Drop all-zero frames. | Teams dominant-speaker "isolation" (a 2s-buffered guess; collapses under crosstalk). **Decoding each app's private protobuf/Redux internals** (Meet `collections` datachannel, Zoom `__reduxStore`) — versioned to undocumented wire formats, the main maintenance burden. Per-frame single-winner CSRC (drops simultaneous speakers). | Prototype overrides must run in MAIN world at `document_start`. Replace `ws://localhost` from page context with a relay to the offscreen doc. Keep the `UserManager` map + envelope; discard everything tied to the bot's output PC, video, captions, chat. |

### `twilio/twilio-video.js-recording-bot` — the pipeline shape (pattern only)
Two files, ~2018, SDK-specific. Value is one data-model idea.

| Adopt (shape, not code) | Avoid | Portability |
|---|---|---|
| **N tracks → N pipelines** as a flat map keyed on the live `MediaStreamTrack` object, each entry owning one MediaStream + one consumer. **Re-key on churn via a monotonic per-identity generation counter**: unsubscribe stops+deletes; re-subscribe increments `N` and starts a fresh segment — never mutate a live pipeline across a drop. Idempotent catch-up (replay current tracks through the same subscribe handler). Delete-from-map-before-stop. | All `twilio-video` objects/events/`.sid` fields. Puppeteer+Express host. FileReader chunk marshalling. Remove the SDK and nothing remains. | **The key insight:** Twilio hands you stable `participant.sid`/`track.sid` and pre-correlated subscribe/unsubscribe events for free. Raw WebRTC gives anonymous `RTCRtpReceiver`/`MediaStreamTrack` with opaque per-session ids and no human identity. The layer the SDK provided — stable identity + our own subscribe/unsubscribe events from `ontrack`/`onended`/`onmute` + track→participant attribution — is exactly what we must build ourselves. |

---

## 2. Cross-cutting design decisions

### Injection & timing — **MAIN-world content script, `document_start`. Confidence: high.**
Use `"world": "MAIN"`, `"run_at": "document_start"`. An isolated-world content script cannot patch the page's `RTCPeerConnection` constructor; only a MAIN-world script shares the realm. `document_start` guarantees the wrapper wins the race against the page's first `new RTCPeerConnection()` — critical for Zoom-web, which caches the constructor at bootstrap (miss it and you catch only the first of N connections, or none). This replaces the injected-`<script>`-tag hack entirely: the manifest gives the same pre-page-load timing as CDP `addInitScript` with none of the race. Survive SPA navigation and extension reload with an **idempotent install guard** (`window.__hookInstalled`) plus a **monotonic capture epoch** so a re-injected instance supersedes the old one and stale instances self-stop.

### Track isolation — **hook `addEventListener('track')` + wrap the `ontrack` setter; use `event.streams[0]`. Confidence: high.**
Per PC instance, attach `addEventListener('track', …)` and also wrap the `ontrack` property setter so a page handler can't shadow the hook. Filter `event.track.kind === 'audio'`. Take the stream from `event.streams[0]` (fallback `new MediaStream([event.track])`). **Do not enumerate `getReceivers()/getTransceivers()`** — it breaks when Zoom wraps tracks and adds no value here. For mid-call tracks, the `track` event already fires. For muted/replaced tracks, listen to `track.onmute`/`onunmute`/`onended` and re-key via the generation counter (Twilio shape). Accept Teams' enabled-but-`muted=true` tracks (they unmute when someone speaks). **Never touch `transceiver.direction` or SDP** (Vexa crash class).

### Participant identity — **platform-specific; per-track where possible, else DOM active-speaker correlation, degrading to "Speaker N". Confidence: medium; this is the fragile part and evidence is genuinely platform-dependent.**
Raw tracks carry no human identity, so the strategy is per platform, cleanest first:
- **Zoom-web (strongest):** parse the participant id directly from the MSID/stream id (`nodeId >> 10 << 10`), cross-referenced to the app's roster. Intrinsic to the track; survives mute/unmute and re-subscription. No guessing.
- **Meet:** two viable paths. (a) **DOM per-element** — Meet's own client renders a per-participant `<audio srcObject>`/`<video>` per tile, so you can capture those elements directly and read identity from the tile's `data-participant-id`/name (Vexa's approach; simplest, gives true multichannel). (b) **CSRC `audioLevel`** on a mixed track → participant via a decoded stream-id table (attendee). Prefer (a) — it avoids decoding Google's private protobuf, the single biggest maintenance sink. The two repos disagree on whether Meet exposes per-participant audio; **verify empirically in v1** which holds for the current Meet build, and keep DOM correlation as the anchor.
- **Teams (weakest):** one mixed track, no usable CSRCs. Best achievable is dominant-speaker-at-timestamp — a guess that fails under overlap. Treat Teams per-participant audio as **degrade-to-Speaker-N**, not a v1 promise.
- **Universal fallback:** when correlation is unavailable or ambiguous, emit a stable synthetic id (`speaker-<n>`) keyed to the track/transceiver so downstream transcription still gets a consistent stream. Never block audio on identity.

DOM active-speaker correlation is inherently brittle (obfuscated classes, per-build churn). Isolate it behind the platform adapter so identity fragility never leaks into the capture/transport core.

### Audio extraction — **`AudioWorklet` per stream → 16 kHz mono PCM, no playback. Confidence: high.**
One `AudioContext` in the page (MAIN world); route each isolated stream through a `MediaStreamAudioSourceNode` → an `AudioWorkletNode` running a small `AudioWorkletProcessor` that downsamples to 16 kHz mono and posts Int16/Float32 frames. Connect the worklet to a **muted `GainNode` (gain 0) or leave it unconnected to `destination`** — never route captured remote audio back to `destination` (double-playback + echo/feedback into the user's own mic path). `AudioWorklet`, not `ScriptProcessor` (deprecated, main-thread) or `MediaRecorder` (encodes, wrong for raw PCM). **Back-pressure:** the worklet posts small fixed frames; the transport layer maintains a bounded ring buffer per participant and drops oldest frames (with a logged counter) if the socket can't keep up — never grow an unbounded queue.

### Transport to the local process — **one multiplexed local WebSocket, client held in the offscreen document. Confidence: medium-high.**
> **Refined** in [`docs/specs/transport.md`](docs/specs/transport.md). v1 uses a loopback WebSocket to earsd's ingest endpoint (`ws://127.0.0.1:<port>/ingest`), held in the **background context** — not an offscreen document, since an MV3 service worker holds the WebSocket directly (WebSocket activity keeps it alive, Chrome 116+). earsd gains a loopback WebSocket ingest server (bound `127.0.0.1`, `Origin`-allowlisted); see [`docs/prompts/earsd-websocket-ingest.md`](docs/prompts/earsd-websocket-ingest.md). The comparison below stands as rationale.

Compared:
- **Native messaging** — Chrome-managed lifecycle, no localhost port, good security. But message-oriented (not streaming), setup friction (host manifest install), and a `connectNative` port held by the SW fights SW suspension. Runner-up; pick it only if you want Chrome to spawn the transcriber process.
- **Local WebSocket (recommended)** — streaming-native, trivial, and the "separate local process" is literally a WS server. Host the client in the **offscreen document**, which has no ~30s idle suspension and is free of the page CSP (a MAIN-world `ws://localhost` risks the page's `connect-src`). One connection carries all participants, tagged with attendee's `[type][idLen][id][PCM]` envelope; the local side fans out to per-participant transcription workers. Keeps the extension minimal (no N-socket bookkeeping).
- **WebRTC data channel** — over-engineered for localhost PCM; reject.

Path: MAIN-world hook + worklet → `window.postMessage` → ISOLATED relay content script → `chrome.runtime` → SW (stateless controller, ensures offscreen exists) → offscreen document → WebSocket → local transcriber. PCM at 16 kHz mono is ~32 KB/s per participant — structured-clone copies across contexts are negligible.

### Cross-platform surface — **v1 targets one platform cleanly behind a thin adapter interface. Confidence: high.**
The capture spine (constructor hook, track isolation, worklet, transport) is fully generalizable. Only **identity** is platform-specific. Define a one-method adapter interface from day one but ship exactly one implementation. Recommended v1: **Google Meet** (largest surface; per-tile DOM identity is the least-fragile well-trodden path). Zoom-web is the natural second (intrinsic MSID identity is actually the cleanest, but the constructor-caching timing and canvas decoder make it fiddlier). Teams last (no real per-participant audio). Do not build a full three-platform abstraction up front — one interface, one impl, add the next when it earns its place.

---

## 3. Proposed minimal module layout

```
manifest.json            MV3. content_scripts: [MAIN/document_start hook, ISOLATED relay].
                         offscreen + storage permissions; host_permissions per target platform.
                         web_accessible_resources: pcm-worklet.js, offscreen.html.
src/
  inpage/                MAIN world (page realm)
    rtc-hook.ts          Constructor wrap + track/ontrack hook. Idempotent guard + capture epoch.
                         Emits {stream, transceiver} per remote audio track. NO SDP/direction mutation.
    audio-tap.ts         Per stream: AudioContext → source → AudioWorkletNode. Owns the N→N pipeline
                         map keyed on the track object; generation counter on churn. gain=0, no playback.
    pcm-worklet.ts       AudioWorkletProcessor: downsample → 16 kHz mono Int16 frames. (web-accessible)
    identity/
      adapter.ts         interface PlatformAdapter { identify(track, stream, transceiver): ParticipantId | null }
      meet.ts            v1 impl: per-tile DOM correlation (data-participant-id + name), Speaker-N fallback.
    bridge.ts            window.postMessage envelope up to the ISOLATED relay.
  content/
    relay.ts             ISOLATED world. window.postMessage ↔ chrome.runtime bridge. No page-realm access.
  background/
    service-worker.ts    Stateless controller: ensureOffscreen (getContexts guard), relay start/stop,
                         state in chrome.storage.session.
  offscreen/
    offscreen.html/.ts   Durable. Holds the WebSocket to the local transcriber; writes the
                         [type][idLen][id][PCM] frames; bounded per-participant ring buffer (back-pressure).
  shared/
    protocol.ts          Envelope types, AudioFormatUpdate, message enums. One source of truth.
  popup/
    popup.html/.ts       On/off toggle + connection status. Minimal.
build: esbuild (or webpack) multi-entry, tsconfig strict, @types/chrome, copy-manifest.
```

Roughly a dozen source files. The fragile surfaces (identity, per-platform quirks) are quarantined in `inpage/identity/`; the durable spine (hook → worklet → transport) is platform-agnostic.

**Firefox note:** MV3 `world:"MAIN"` content scripts landed later in Firefox and remain the riskiest portability point — keep the injection mechanism behind one module (`rtc-hook.ts` install) so a fallback `<script>`-tag injection can be swapped in without touching the rest. Offscreen documents are Chrome-only; Firefox would host the WebSocket in a persistent background page instead. `AudioWorklet`, `RTCPeerConnection`, insertable streams are standard.

---

## 4. Anti-pattern list — seen in these repos, do NOT do

1. **Whole-tab / display capture** (`tabCapture`, `getDisplayMedia`, `chromeMediaSource:'tab'`) — yields post-mix audio; cannot separate participants. (recallai)
2. **Mixing sources into one `MediaStreamDestination`** — the exact inverse of the goal. (recallai)
3. **Caption/transcript DOM scraping as the audio source** — text-only, obfuscated classes, no PCM. (recallai)
4. **Mutating `transceiver.direction` or munging SDP from an injected script** — the "Execution context destroyed" crash class; killed ~44% of Meet sessions. We are passive; never do it. (Vexa)
5. **Enumerating `getReceivers()/getTransceivers()` for track discovery** — breaks when Zoom wraps tracks; use the `track` event. (Vexa)
6. **Decoding the app's private protobuf/Redux internals** for identity — versioned to undocumented wire formats; the biggest maintenance sink. Prefer DOM/MSID signals. (attendee, Vexa)
7. **Trusting dominant-speaker as isolation** — a buffered guess that collapses under overlapping speech. (attendee/Teams)
8. **Per-frame single-winner CSRC** — silently drops simultaneous speakers. (attendee/Meet)
9. **Routing captured remote audio to `AudioContext.destination`** — double-playback and feedback. (avoid in all)
10. **Long-lived audio/transport in the service worker** — dies on ~30s idle suspension; put it in the offscreen document. (recallai lesson)
11. **`Object.keys` to copy constructor statics** — misses non-enumerable statics; use `Object.setPrototypeOf`. (ggarber)
12. **No idempotent guard / no capture epoch** — SPA nav and re-injection cause 2–3× duplicated PCM. (Vexa)
13. **Swallowing injection-order errors in a promise chain** — records zero audio while reporting success. Surface errors, enforce install order. (Vexa)
14. **`ScriptProcessorNode` / `MediaRecorder` for raw PCM** — deprecated main-thread node / wrong (encoded) output. Use `AudioWorklet`. (Vexa/recallai)
15. **Unbounded PCM queues** — apply bounded ring buffers with drop-oldest + a logged counter for back-pressure.
