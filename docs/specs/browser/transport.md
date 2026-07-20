# Spec: transport (extension ↔ `earsd`)

## One job

Stream per-participant PCM from the extension to `earsd`'s loopback WebSocket ingest endpoint, mapping each participant to a distinct `browser:<label>` source and its `stream_id`. One WebSocket, held in the background context, with one piece of state: the participant → `stream_id` table.

The extension's control traffic (meeting resolution, session open/close) rides the separate `/control` WebSocket via `lib/control-transport.ts`, which speaks the same command set as the Unix socket — see the [capture-daemon spec](../capture-daemon.md#transports). This document covers the audio leg (`lib/transport.ts`).

### Why a WebSocket, not native messaging

No native-messaging host manifest, no extension-id-coupled install, and PCM ships as binary frames. MV3 service workers hold WebSockets, and WebSocket activity resets the worker idle timer (Chrome 116+), so the connection lives in the background context on both browsers with no offscreen document.

### Responsibilities

- Open one WebSocket to `ws://127.0.0.1:<port>/ingest`; reconnect with backoff on drop.
- Lazily `ingest.open` a source on the first PCM for a new participant; stream binary frames; `ingest.close` on leave.
- Maintain the participant → `stream_id` table; discard it on disconnect and re-open lazily as new frames arrive.
- Apply backpressure; never buffer unbounded.

It does **not** capture, resample, or inspect audio (it receives finished 16 kHz `pcm_s16le`), and does **not** resolve identity (it receives an already-stable id).

## Endpoint & connection

- URL: `ws://127.0.0.1:<port>/ingest`; port from extension options (default `47811`, matching `[earsd.ingest_ws].port`).
- **Loopback only.** The extension refuses any non-`127.0.0.1` URL — a remote URL is a bug, not a configuration.
- The browser sets `Origin` (`chrome-extension://<id>` / `moz-extension://<uuid>`) truthfully on the handshake; `earsd` allowlists it.

## Wire protocol

Control is text frames, reusing `earsd`'s `ControlRequest`/`ControlResponse` types:

```jsonc
// text --> declare a per-participant stream (first PCM for a new participant)
{"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
// text <-- {"ok":true,"data":{"stream_id":"s7"}}

// text --> end the stream (participant left / track ended)
{"cmd":"ingest.close","stream_id":"s7"}
// text <-- {"ok":true,"data":{}}
```

Audio is one binary frame per PCM chunk, multiplexed by `stream_id` — no sequence number, since WebSocket rides TCP:

```
[ u8 idLen ][ stream_id : idLen ASCII bytes ][ pcm_s16le bytes (mono, little-endian) ]
```

At ~10 frames/s/participant (~3 KB each), message size is never a concern.

### Source labeling

One participant → `browser:<platform>:<participant>` → one `stream_id` → one independently-recorded, independently-transcribed `earsd` source. `<platform>` is `meet` | `zoom` | `teams`; `<participant>` is the sanitized id from the [extension spec](./extension.md#platform-adapters). Fallback ids become e.g. `browser:teams:speaker-3` — stable within the call, honest about provenance.

## State & lifecycle

- **participant → stream_id table:** populate on `ingest.open` success; drop on `ingest.close`. On an `{"ok":false}` open, log and drop that participant's frames (no per-frame retry).
- **Reconnect:** on close/error, discard the table (stream ids are per-connection), buffer nothing, reconnect with backoff, and re-open lazily as new frames arrive. Surface a `disconnected` status to the popup.
- **Backpressure:** if the socket's `bufferedAmount` exceeds its threshold, drop frames and count them in a logged `dropped` counter — never grow an unbounded queue.

### Per-browser lifetime

- **Chrome (MV3 service worker):** continuous PCM keeps the worker alive, but silence produces no traffic, so a `chrome.alarms` keepalive is armed while a capture session is active and cleared when the last participant leaves. On worker respawn, the module top level reconnects, streams re-open lazily, and persisted `storage.session` state re-arms the alarm.
- **Firefox (MV3 event page):** Firefox can also suspend its background context after idle, so the same keepalive + lazy-reconnect hardening applies; the code path is identical.

## Security

Both sides enforce the boundary; neither trusts the other to.

**`earsd` (server):** binds `127.0.0.1` only; validates `Origin` against `[earsd.ingest_ws].allowed_origins` before completing the upgrade (empty allowlist rejects all — fail closed); accepts nothing but `ingest.open`/`ingest.close` and binary audio, so even an allowed origin cannot drive the daemon from this endpoint.

**Extension (client):** connects to loopback only; the WebSocket lives in the background context, never the page realm, so no meeting-page CSP applies and no endpoint or state is exposed to page scripts.

Residual risk on a shared machine: another **local** process can present an allowed `Origin` and connect. Loopback + Origin allowlist is the specified control; the threat model is a single-user machine. A user-configured bearer token is a documented future option.

The extension is testable without a daemon against `browser/dev/stub-server.ts`, which speaks this same wire protocol.
