# PRD: browser capture extension

## One job

Inside a video call the user has already joined, isolate each remote participant's audio into its own 16 kHz mono PCM stream and hand each stream to the local `earsd` daemon as a distinct `browser:<label>` source. Nothing else.

The extension is the `browser:<label>` producer named in [`capture-daemon.md`](../../docs/specs/capture-daemon.md) — the only source class earsd receives over the socket rather than capturing natively. It exists because a first-party browser tab is the one place per-participant remote audio is separable before the app mixes it for playback.

## Motivation

macOS process taps (earsd Phase 4) capture a meeting app as one mixed `app:<bundle-id>` source — you-vs-them at best, never speaker-vs-speaker for the far end. Web meetings carry each remote participant as a separate WebRTC track (Meet/Zoom) or an attributable mixed track (Teams) *before* the page mixes them to one output. Tapping that layer in the page is the only way to get true per-participant far-end audio without diarization guesswork.

## Users & usage

A single technical user, already in a Meet/Zoom-web/Teams call in their own Chrome or Firefox, with earsd running locally. They install the extension once and point it at earsd's local ingest port. The extension activates on a known meeting host, streams per-participant audio to earsd for the call's duration, and stops on leave. No UI beyond an on/off toggle, the earsd port, and a connection indicator.

## Scope — v1

Three meeting platforms and two browsers, all in v1, behind one `PlatformAdapter` abstraction. Only the identity layer is platform-specific; the capture spine (injection, RTC hook, audio tap, transport) is shared.

| Platform | Audio delivery | Identity strategy | Fidelity |
|----------|----------------|-------------------|----------|
| Google Meet | per-participant tracks, but **not** capturable via any `MediaStreamTrack`-based path (AudioWorklet, `MediaStreamTrackProcessor`, `<audio>`) — Meet's client steals the encoded RTP off each audio receiver via `receiver.createEncodedStreams()` before the browser ever decodes it, and decodes it itself off the standard pipeline. Validated live (journal #28–#31): capture instead by wrapping `createEncodedStreams()`, `.tee()`-ing the encoded stream (Meet's own branch untouched), and decoding our branch with the native `AudioDecoder` (opus). See [`specs/extension.md`](specs/extension.md#audio-extraction). | tile DOM `data-participant-id` + name; CSRC `audioLevel` fallback | high |
| Zoom (web) | 1 track / participant | participant id parsed from MSID (`nodeId >> 10 << 10`) | high, intrinsic |
| Teams | 1 mixed track | dominant-speaker at timestamp → `Speaker N` | degraded |

**Google Meet is a platform constraint, not a bug in our capture code:** on the current Meet build, standard track-based audio capture reads pure silence for every remote participant, confirmed via `getStats()` (`decoderImplementation=undefined`, `jitterBufferEmittedCount=0` throughout live speech) and independently via a `MediaStreamTrackProcessor`/WebAudio tap that never receives a single frame. The encoded-stream tee is the only mechanism that works, and it does — validated with real Opus frames flowing continuously, zero errors, zero disruption to Meet's own call, and clean per-participant isolation at 2 simultaneous remote speakers. Reverse-engineering Meet's own WASM decoder was considered and ruled out: it doesn't even instantiate in the page's main-world realm (almost certainly runs inside a Worker), and is unnecessary anyway since the browser's native `AudioDecoder` already supports Opus decode.

| Browser | Transport host | Notes |
|---------|----------------|-------|
| Chrome (MV3) | service worker holds the WebSocket to earsd | WebSocket activity keeps the worker alive (Chrome 116+); `chrome.alarms` keepalive fallback |
| Firefox (MV3) | persistent background page holds the WebSocket | no service-worker suspension; no offscreen document |

Transport is a **loopback WebSocket** to earsd's ingest endpoint (`ws://127.0.0.1:<port>/ingest`), opened from the background context — no native-messaging host, no offscreen document, binary PCM frames. See [`transport.md`](specs/transport.md).

## Non-goals

- **No meeting-join / bot / automation.** No Playwright/Puppeteer, headless browsers, Xvfb, Docker, fake camera/mic. The user joins; the extension only listens.
- **No mixed-tab capture.** No `chrome.tabCapture`, `getDisplayMedia`, or whole-tab audio — it yields post-mix audio that cannot be separated per participant.
- **No caption/DOM transcript scraping.** Audio only. Captions are text, obfuscated, and useless as a PCM source.
- **No transcription, models, or LLMs** in the extension. It produces PCM; earsd and `transcribe` do the rest.
- **No cloud.** Everything stays on the local machine.
- **macOS-only host.** The daemon and the machine running it are macOS (the parent project's target).

## Success criteria

1. On Meet and Zoom-web, each remote participant who speaks produces a distinct earsd `stream_id`, and the resulting per-source audio contains only that participant. Verified by `ears sources.list` showing one `browser:<platform>:<participant>` source per speaker and by listening to each source's chunks.
2. The RTC hook is installed before the page's first `RTCPeerConnection`, verified on a cold Zoom-web load (the strictest timing case).
3. No double-playback, echo, or feedback into the user's mic while capturing.
4. A re-injection (SPA navigation, extension reload) never doubles or drops a live stream.
5. Both Chrome and Firefox builds run the full path on the same code, differing only in the transport-host entrypoint.
6. Teams produces attributed `Speaker N` streams and never claims false per-participant fidelity.

## Constraints

- MV3, TypeScript, built with [WXT](https://wxt.dev). One maintainer must be able to hold the whole codebase in their head — a dozen source files, fragile per-platform logic quarantined behind the adapter.
- Wire compatibility with earsd's existing `Sources/EarsCore/Socket/` Codable types is mandatory; the extension reuses `ingest.open` verbatim, adds one `ingest.close` command, and defines the binary PCM frame — all specified in [`transport.md`](specs/transport.md).

## References

- [`DESIGN_BRIEF.md`](../DESIGN_BRIEF.md) — the design rationale and 5-repo review this PRD distills. Its §2 transport recommendation is **refined** here: a loopback WebSocket held in the background context (no offscreen document, since an MV3 worker holds the socket directly), streaming to earsd's ingest port.
- [`specs/extension.md`](specs/extension.md) — the extension internals.
- [`specs/transport.md`](specs/transport.md) — the WebSocket transport and earsd wire contract.
- [`prompts/earsd-websocket-ingest.md`](prompts/earsd-websocket-ingest.md) — the earsd-side change (WebSocket ingest server).
- [`roadmap.md`](roadmap.md) — phased build plan.
