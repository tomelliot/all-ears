# Roadmap: capture extension

Phased so each stage is independently verifiable in a real call. Every phase carries the day-one requirements: the idempotent install guard, capture epoch, no-playback, and surfaced (never swallowed) errors. This is the extension's own roadmap; the earsd-side ingest server it ultimately targets is Phase 6 of the parent [`docs/roadmap.md`](../../docs/roadmap.md).

## Phase 0 — Scaffold

- WXT project: entrypoints (`injected`, `content`, `background`, `popup`, `pcm-worklet`), `wxt.config.ts` with the three host permissions and `web_accessible_resources`, `tsconfig`, strict TS.
- Builds for both targets: `wxt build` (Chrome) and `wxt build -b firefox` produce loadable MV3 extensions.
- `content.ts` logs on a Meet/Zoom/Teams tab; `background.ts` and `popup` load.
- **Exit:** both builds load in their browser and the content script logs on all three meeting hosts.

## Phase 1 — Injection + track isolation

- `lib/rtc-hook.ts`: constructor wrapper installed via `injectScript("/injected.js")` at `document_start`; idempotent guard + capture epoch; `Object.setPrototypeOf` for statics.
- Capture remote **audio** tracks via `addEventListener("track")` + `ontrack`-setter wrap; `event.streams[0]`; the N→N map keyed on the track object; `onended`/`onmute` lifecycle. No SDP/transceiver mutation.
- Zoom/Teams hidden-`<audio>` normalization (routed to a muted graph).
- **Exit:** on a cold Zoom-web load (strictest timing) and on Meet, the console logs one captured audio track per speaking remote participant; a mid-call join adds a track; leaving removes it; an extension reload does not double the count (epoch works).

## Phase 2 — Audio → PCM

- **Standard path** (Zoom, Teams — assumed, verify per platform): `MediaStreamTrackProcessor` reads decoded `AudioData` directly off each remote `MediaStreamTrack` (construction deferred to first `unmute`); a streaming linear resampler (native rate → 16 kHz mono); `pcm-worklet.ts` retained only as a fallback if `MediaStreamTrackProcessor` is unavailable. **Never** connected to `destination`.
- **Meet path (validated, required — standard path produces zero audio on Meet):** wrap `RTCRtpReceiver.prototype.createEncodedStreams` in `lib/rtc-hook.ts` (same MAIN-world/`document_start` hook as the `RTCPeerConnection` wrap); on `kind === "audio"`, `.tee()` the pre-decode `readable`, return Meet's branch untouched, and decode our branch with the native `AudioDecoder` (`{codec:"opus", sampleRate:48000, numberOfChannels:1}`) into the same `AudioData` interface `MediaStreamTrackProcessor` yields, feeding the same downmix/resample/ring-buffer pipeline. Gate this path on `location.host === "meet.google.com"` — applying it elsewhere double-captures platforms where the standard path already works. Full rationale, evidence, and the ruled-out alternatives (WASM reverse-engineering) are in [`specs/extension.md`](specs/extension.md#audio-extraction) and journal entries `#28`–`#31`.
- `lib/audio-tap.ts` emits tagged PCM to `content.ts` → `background.ts`; bounded per-participant ring buffer with a logged dropped counter.
- **Exit:** `background.ts` receives ~10 `pcm_s16le` frames/s/participant with monotonic `seq` on **both** paths; dumping one participant's frames to a `.wav` plays back that participant only; no audio is played by the extension and no echo enters the user's mic. On Meet specifically: verified with 2 simultaneous remote participants, zero cross-talk, zero errors, and Meet's own call unaffected by the tee.

## Phase 3 — WebSocket transport + earsd ingest contract

- `background.ts` opens one WebSocket to `ws://127.0.0.1:<port>/ingest`; participant→`stream_id` table; text-frame `ingest.open`/`ingest.close`; binary PCM frames (`[u8 idLen][stream_id][pcm_s16le]`, no seq); reconnect + back-pressure. **Implemented** (`lib/transport.ts`).
- earsd side (parent repo, per [`prompts/earsd-websocket-ingest.md`](prompts/earsd-websocket-ingest.md)): loopback WebSocket server bound `127.0.0.1`, `Origin` allowlist, `[earsd.ingest_ws]` config, one new `ingest.close` case on `ControlRequest`, binary-PCM handler. **Landed** (`daemon/Sources/EarsIPC/IngestWebSocketServer.swift`, `WebSocketFraming.swift`, `daemon/Sources/EarsDaemonKit/PushCaptureBackend.swift` + `EarsDaemon`'s dynamic `browser:<label>` source construction) — hand-rolled directly on the raw-byte socket transport rather than `NWProtocolWebSocket`, which gives no hook to validate `Origin` before completing the upgrade. Daemon-side test coverage: handshake/framing/Origin-allowlist unit tests, a real-loopback-socket integration test, and an `EarsDaemon`-level test confirming pushed PCM actually lands on disk under a `browser:<label>` source.
- Test first against a **WebSocket stub** (accepts `ingest.open` → `stream_id`, drains binary frames), then against the real earsd server now that it's landed.
- **Exit:** with the stub, PCM captured in a live Meet call reaches the stub keyed by `stream_id`, one stream per participant; killing/restarting the stub triggers a clean reconnect and lazy re-open; a disallowed `Origin` is rejected. Against real earsd: `ears sources.list` shows a `browser:meet:<participant>` source per speaker with audio on disk. **Verified live**: a real Meet call with `[earsd.ingest_ws]` enabled produced `browser:meet:speaker-1` in `ears sources.list` with real bytes captured, and `ears flush` finalized a valid 26.2s mono/16kHz AAC file on disk (`afinfo`-confirmed) matching the designed `meta.toml` shape (`class='browser'`, `native_sample_rate=asr_sample_rate=16000`, `store_native=false`).

## Phase 4 — Meet identity

- **Depends on Phase 2's Meet audio path** (the `createEncodedStreams` tee) — without it there is no PCM to attach identity to on Meet; the `track`/`transceiver` correlation this phase uses is unaffected by the tee (the standard `track` event still fires normally).
- `lib/identity/meet.ts`: tile `MutationObserver` correlating each captured stream to its tile, reading `data-participant-id` + display name; `Speaker N` fallback; CSRC `audioLevel` path documented as fallback.
- **Verify empirically** whether the current Meet build exposes per-tile `<audio srcObject>` (preferred) or requires CSRC attribution; pick the least-fragile path that holds.
- **Exit:** in a ≥3-person Meet call, each speaker's earsd source carries their real name/id and only their audio; a participant who mutes and unmutes keeps the same id (new segment, same source).

## Phase 5 — Zoom identity

- `lib/identity/zoom.ts`: MSID parse (`/^(\d+)\+/` → `>> 10 << 10`, gated on `+CS+`); roster/display-name lookup.
- **Exit:** in a ≥3-person Zoom-web call, per-participant sources are correct and stable across mute/re-subscribe without any active-speaker guessing.

## Phase 6 — Teams identity

- `lib/identity/teams.ts`: dominant-speaker-at-timestamp attribution over the mixed track, emitting `Speaker N`; buffered to the app's reported speaker intervals.
- **Exit:** a Teams call produces attributed `Speaker N` sources; the UI/logs state plainly that Teams is attribution, not isolation. No false per-participant claim.

## Phase 7 — Cross-browser parity + hardening

- Firefox: persistent-background-page WebSocket owner; confirm `injectScript` timing and that earsd's `Origin` allowlist includes the Firefox `moz-extension://<uuid>` origin; the only per-browser code is the socket lifetime.
- Chrome: `chrome.alarms` keepalive; `storage` session recovery on worker respawn.
- Popup: on/off toggle + connection indicator.
- `vitest` unit tests for `lib/protocol.ts` and the identity parsers (Zoom MSID math, Meet tile correlation, `Speaker N` fallback) — the pieces testable without a live call.
- **Exit:** the full path runs on both browsers from the same source; the test suite covers protocol + identity parsing; a day-long call does not leak, double, or drop streams.

## Sequencing notes

- Phases 0–3 are the spine and unblock everything; 4–6 are parallelizable once the adapter interface (Phase 1) is stable. 7 is continuous hardening, not a gate.
- Phase 3's real-earsd exit depends on parent-repo Phase 6. Until then the stub keeps the extension fully testable end-to-end.
- Ship Meet + Zoom as the "high fidelity" pair first if time-boxing; Teams (Phase 6) is honest-but-degraded and can trail.
