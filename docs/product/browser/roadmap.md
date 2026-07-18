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

- `pcm-worklet.ts` (`AudioWorkletProcessor`) loaded via `addModule(runtime.getURL("/pcm-worklet.js"))`; per-stream `AudioContext` → source → worklet → 16 kHz mono `Int16Array`; **never** connected to `destination`.
- `lib/audio-tap.ts` emits tagged PCM to `content.ts` → `background.ts`; bounded per-participant ring buffer with a logged dropped counter.
- **Exit:** `background.ts` receives ~10 `pcm_s16le` frames/s/participant with monotonic `seq`; dumping one participant's frames to a `.wav` plays back that participant only; no audio is played by the extension and no echo enters the user's mic.

## Phase 3 — WebSocket transport + earsd ingest contract

- `background.ts` opens one WebSocket to `ws://127.0.0.1:<port>/ingest`; participant→`stream_id` table; text-frame `ingest.open`/`ingest.close`; binary PCM frames (`[u8 idLen][stream_id][pcm_s16le]`, no seq); reconnect + back-pressure.
- earsd side (parent repo, per [`prompts/earsd-websocket-ingest.md`](prompts/earsd-websocket-ingest.md)): loopback WebSocket server bound `127.0.0.1`, `Origin` allowlist, `[earsd.ingest_ws]` config, one new `ingest.close` case on `ControlRequest`, binary-PCM handler.
- Test first against a **WebSocket stub** (accepts `ingest.open` → `stream_id`, drains binary frames), then against the real earsd server once parent Phase 6 lands.
- **Exit:** with the stub, PCM captured in a live Meet call reaches the stub keyed by `stream_id`, one stream per participant; killing/restarting the stub triggers a clean reconnect and lazy re-open; a disallowed `Origin` is rejected. Against real earsd: `ears sources.list` shows a `browser:meet:<participant>` source per speaker with audio on disk.

## Phase 4 — Meet identity

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
