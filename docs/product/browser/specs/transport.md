# Spec: transport (earsd WebSocket ingest)

## One job

Stream per-participant PCM from the extension to `earsd`'s loopback WebSocket ingest endpoint, mapping each participant to a distinct `browser:<label>` source and its `stream_id`. One WebSocket, held in the background context, with one piece of state: the participant→`stream_id` table.

### Why a WebSocket (not native messaging)

`earsd` exposes a loopback WebSocket ingest endpoint (`ws://127.0.0.1:<port>/ingest`, see [`../prompts/earsd-websocket-ingest.md`](../prompts/earsd-websocket-ingest.md)). The extension connects to it directly from `background.ts` — no native-messaging host, no host manifest, no extension-id-coupled install, and PCM ships as **binary frames** (no base64). MV3 service workers hold WebSockets and WebSocket activity resets the worker idle timer (Chrome 116+), so the connection lives in the background context on both browsers with **no offscreen document**. This supersedes [`DESIGN_BRIEF.md`](../DESIGN_BRIEF.md) §2's offscreen-document detail and the earlier native-messaging bridge.

### Responsibilities

- Open one WebSocket to `ws://127.0.0.1:<port>/ingest` from the background context; reconnect on drop.
- Lazily `ingest.open` a source the first time PCM arrives for a new participant; stream its PCM as binary frames; `ingest.close` on leave.
- Maintain the participant→`stream_id` table; discard and re-open lazily across reconnects.
- Apply back-pressure upstream; never buffer unbounded.

### Explicit non-responsibilities

- Does **not** capture, resample, or inspect audio — the extension delivers finished 16 kHz `pcm_s16le`.
- Does **not** resolve participant identity — it receives an already-stable id.
- Does **not** speak the daemon's control plane (`status`/`sources.*`/`session.*`) — that stays on earsd's Unix socket, unreachable from the WebSocket.

## Where it lives

```
injected.ts ──win──► content.ts ──rt──► background.ts ──ws──► earsd  ws://127.0.0.1:<port>/ingest
 (page main world)    (isolated)         (SW / bg page)         (loopback, Origin-allowlisted)
```

The page→content→background hops are unchanged from [`extension.md`](extension.md); only the final leg is a WebSocket. The page never sees the socket — the WebSocket is opened in the background context, so no meeting-page CSP applies and no secret sits in page scope.

## Endpoint & connection

- URL: `ws://127.0.0.1:<port>/ingest`. Port from extension options (default `47811`), matching earsd's `[earsd.ingest_ws] port`.
- **Loopback only.** The extension connects to `127.0.0.1` and refuses any non-loopback host — a remote `ws://` URL is a bug, not a configuration.
- **Origin** is set automatically by the browser to `chrome-extension://<id>` (Chrome) / `moz-extension://<uuid>` (Firefox) on the handshake; earsd allowlists it (see [Security](#security)). Web content cannot forge `Origin`, so the allowlist blocks pages.
- No `nativeMessaging` permission. If a browser requires host permission for a background WebSocket to loopback, add `ws://127.0.0.1/*` (or `http://127.0.0.1/*`) to `host_permissions`.

## Wire protocol

**Control = text frames**, reusing earsd's `ControlRequest`/`ControlResponse` Codable types verbatim (`Sources/EarsCore/Socket/`).

```jsonc
// text  --> declare a per-participant stream (first PCM for a new participant)
{"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
// text  <-- {"ok":true,"data":{"stream_id":"s7"}}

// text  --> end the stream (participant left / track ended)
{"cmd":"ingest.close","stream_id":"s7"}
// text  <-- {"ok":true,"data":{}}
```

**Audio = binary frames.** One binary WebSocket message per PCM chunk, multiplexed by `stream_id`:

```
[ u8 idLen ][ stream_id : idLen ASCII bytes ][ pcm_s16le bytes (mono, LE) ]
```

- `format` keys match `AudioFormatSpec` exactly (`sample_rate`, `channels`, `encoding`); always `16000/1/pcm_s16le` in v1.
- **No sequence number.** WebSocket rides TCP — frames are ordered and reliable — so the `seq` the base64 design needed is dropped.
- The extension emits ~10 binary frames/s/participant (~3 KB each). No message-size cap concern.

### Source labeling

- One participant → `browser:<platform>:<participant>` → one `stream_id` → one independently-recorded, independently-transcribed earsd source. This is what preserves speaker-vs-speaker through storage and `transcribe`.
- `<platform>` is `meet` | `zoom` | `teams`; `<participant>` is the sanitized `ParticipantId` from [`extension.md`](extension.md). `Speaker N` fallback ids become e.g. `browser:teams:speaker-3` — stable within the call, honest about provenance.

## State & lifecycle

- **participant→stream_id table.** Populate on `ingest.open` success; drop on `ingest.close`. On `{"ok":false,…}` for `ingest.open`, log and drop that participant's frames (no per-frame retry).
- **Reconnect.** On WebSocket close/error: discard the table (stream_ids are per-connection), buffer nothing, reconnect with backoff, and re-`ingest.open` lazily as new frames arrive. Surface a `disconnected` status to the popup.
- **Back-pressure.** If the socket's `bufferedAmount` grows past a threshold, drop the oldest frame per participant and increment a logged `dropped` counter — never grow an unbounded queue (mirrors earsd's realtime hand-off policy).

### Per-browser lifetime

- **Chrome (MV3 service worker):** `background.ts` holds the WebSocket. Continuous PCM traffic keeps the worker alive (Chrome 116+ WebSocket keepalive); add a `chrome.alarms` backstop for silent calls. On worker respawn, reconnect and re-open streams lazily; recover capture state from `storage` session.
- **Firefox (MV3 persistent background page):** no suspension; the background page holds the WebSocket for the call. Same code, stronger lifetime guarantee.

## Security

Both sides enforce the boundary; neither trusts the other to.

**earsd (server) — see the [ingest prompt](../prompts/earsd-websocket-ingest.md):**
- **Binds `127.0.0.1` only** — never `0.0.0.0`/`::`. Remote hosts cannot reach the port.
- **Allowlists the `Origin` header** against `[earsd.ingest_ws] allowed_origins`; unlisted origins get `403` and no upgrade; empty allowlist rejects all (fail closed). This blocks any web page, since browsers set a truthful `Origin` on the handshake.
- **Ingest-only:** the WebSocket accepts `ingest.open`/`ingest.close` and binary audio; every other `cmd` is rejected. The control plane (status/sources/sessions) stays on the Unix socket, so an allowed origin still cannot drive the daemon.

**extension (client):**
- Connects to **loopback only**; refuses a non-`127.0.0.1` URL.
- The WebSocket lives in the **background context**, never the page/MAIN world — no meeting-page CSP applies and no endpoint or state is exposed to page scripts.
- The browser supplies the `Origin` automatically; the extension adds no forgeable auth in page scope.

Residual risk on a shared machine: another **local** process (not a browser) can set any `Origin` and connect. If that matters, add a user-configured bearer token (options page → earsd config); loopback + Origin allowlist is the specified v1 control, since a browser extension cannot read a token file from disk.

## earsd changes required

Implemented by [`../prompts/earsd-websocket-ingest.md`](../prompts/earsd-websocket-ingest.md); parent [`docs/roadmap.md`](../../docs/roadmap.md) Phase 6. In brief: add `[earsd.ingest_ws]` config, a loopback WebSocket server in `EarsIPC` with Origin allowlisting, the text-control + binary-PCM framing above, and one new `ingest.close` case on `ControlRequest`. Until it lands, the extension is testable against a stub WebSocket server that accepts `ingest.open`, returns a `stream_id`, and drains binary frames (roadmap Phase 3).
