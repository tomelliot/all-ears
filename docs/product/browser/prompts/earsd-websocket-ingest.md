# Prompt: add a WebSocket ingest endpoint to `earsd`

Use this prompt against the parent `transcriber` Swift monorepo to implement the earsd side of the browser extension's audio transport. It replaces the browser plugin's Unix-socket ingest path with a loopback WebSocket. The extension side is specified in `browser/docs/specs/transport.md`; keep the two in exact agreement.

---

## Task

Add a **localhost WebSocket ingest endpoint** to `earsd` so the browser extension can stream per-participant PCM directly, without a native-messaging bridge. The existing Unix control socket (`socket_path`) keeps handling `status` / `sources.*` / `session.*` / `subscribe`; the WebSocket handles **ingest only**. Reuse the existing socket Codable types for control messages.

## Context (read first)

- `docs/specs/capture-daemon.md` → "Audio ingestion": today ingest is declared over the Unix socket (`ingest.open` → `stream_id`, "then binary/base64 frames … framing defined in the wire spec"). That framing was never defined; this task defines it as WebSocket binary frames and moves browser ingest off the Unix socket.
- `Sources/EarsCore/Socket/ControlRequest.swift` — the 14-command enum. `ingest.open` already exists (`case ingestOpen(source:format:)`). `EarsCore/Socket/AudioFormatSpec.swift`, `IngestOpenData.swift`, `ControlResponse.swift`, `ControlError.swift`, `EmptyData.swift` — reuse verbatim.
- `Sources/EarsCore/Config/EarsdConfigSchema.swift` — `[earsd]` config table. `Sources/EarsCore/Models/SourceClass.swift` — `browser` class (`browser:<label>`).
- `Sources/EarsIPC/EarsIPC.swift` — placeholder; the socket server(s) live here per the parent roadmap. `docs/roadmap.md` Phase 6 is "Streaming + browser ingestion" — this is that work.

## Requirements

### 1. Config (`EarsdConfigSchema.swift`)

Add an `[earsd.ingest_ws]` table:

```toml
[earsd.ingest_ws]
enabled        = false               # off by default; opt-in
port           = 47811               # loopback TCP port
allowed_origins = []                 # e.g. ["chrome-extension://<id>", "moz-extension://<uuid>"]
```

Layered like every other config value (defaults < file < `EARS_` env < flags). `allowed_origins` empty ⇒ reject all origins (fail closed).

### 2. WebSocket server (in `EarsIPC`, started by the daemon)

- **Bind `127.0.0.1` only. Never `0.0.0.0` or `::`.** A non-loopback bind is a bug; assert it in code and cover it with a test.
- Serve one path: `GET /ingest` (WebSocket upgrade). Reject any other path with 404.
- On the upgrade request, **validate the `Origin` header against `allowed_origins`**. No match ⇒ respond `403` and do not upgrade. Browsers set `Origin` on WebSocket handshakes and page/web content cannot forge it, so this blocks web pages; loopback bind blocks remote hosts.
- The WebSocket is **ingest-only**: accept only `ingest.open` / `ingest.close` control frames and binary audio frames. Reject any other `cmd` with `{"ok":false,"error":"…"}`. The daemon's control plane (status, sources, sessions) stays on the privileged Unix socket, so an allowed origin still cannot drive the daemon.
- Start with the daemon; stop cleanly on shutdown (`SIGTERM`), closing streams like a normal ingest close.

### 3. Wire protocol on the WebSocket

**Control = text frames.** Decode each text frame as `ControlRequest` (the same `JSONDecoder` the Unix socket uses). Respond with a text frame carrying the matching `ControlResponse<Payload>`.

```jsonc
// text frame  --> declare a per-participant stream
{"cmd":"ingest.open","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
// text frame  <-- ControlResponse<IngestOpenData>
{"ok":true,"data":{"stream_id":"s7"}}

// text frame  --> end the stream
{"cmd":"ingest.close","stream_id":"s7"}
// text frame  <-- ControlResponse<EmptyData>
{"ok":true,"data":{}}
```

**Audio = binary frames.** One binary WebSocket message per PCM chunk, multiplexed by `stream_id`:

```
┌────────┬──────────────────────┬───────────────────────────┐
│ u8     │ stream_id (idLen ASCII)│ pcm_s16le bytes           │
│ idLen  │                       │ (mono, little-endian)      │
└────────┴──────────────────────┴───────────────────────────┘
```

Route the PCM to the open stream for that `stream_id`, then resample/encode/append to the `browser:<label>` source exactly like locally-captured audio (as `capture-daemon.md` already states). WebSocket rides TCP, so frames are ordered and reliable — **no sequence number is needed** (drop the `seq` field the Unix design carried). Unknown `stream_id` ⇒ drop the frame and log once.

### 4. `ControlRequest` change

Add one case: `ingest.close`. Give it `CodingKeys` `stream_id` (reuse `IngestOpenData`'s `stream_id` wire key convention). `ingest.open` is unchanged. Do **not** add `ingest.push` — audio is binary frames on the WebSocket, not a JSON command.

### 5. Source model

`ingest.open` on a `browser:<platform>:<participant>` source declares/creates that source and returns its `stream_id`. One participant ⇒ one source ⇒ one independently-recorded, independently-transcribed stream (preserving speaker-vs-speaker through `transcribe`'s independent-then-merged path). Labels are already sanitized `[A-Za-z0-9._-]` by the extension.

### 6. Tests

- Loopback-bind assertion (server never binds non-loopback).
- Origin allowlist: allowed origin upgrades; disallowed origin gets 403; empty allowlist rejects all.
- `ingest.open` → `stream_id`, binary frame with that id appends PCM to the named source, `ingest.close` ends it.
- A non-ingest `cmd` on the WebSocket is rejected.
- Malformed binary header (idLen past end) is dropped, not crashing.

### 7. Docs

Update `docs/specs/capture-daemon.md`'s "Audio ingestion" section to describe this WebSocket endpoint (loopback bind, Origin allowlist, text-control + binary-PCM framing) and note that browser ingest no longer uses the Unix socket. Cross-reference `browser/docs/specs/transport.md`.

## Security checklist (must all hold)

- [ ] Server binds `127.0.0.1` only.
- [ ] `Origin` header validated against `allowed_origins`; fail closed on empty.
- [ ] WebSocket accepts ingest commands only; control plane stays on the Unix socket.
- [ ] No audio ingest path reachable from a non-loopback address or an unlisted origin.

## Out of scope

Native messaging, the `ears-bridge` executable, and base64 framing — all removed by this change. Do not add a bearer-token scheme unless asked; loopback + Origin allowlist is the specified control. If added later, the token must be user-configured in the extension (a browser extension cannot read a token file from disk).
