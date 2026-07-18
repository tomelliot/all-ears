# Prompt: Cross-browser parity + hardening (Phase 7)

Use this prompt against the `all-ears` repo, `browser/` extension. Phases 1–3 (injection, audio capture, WebSocket ingest) are done and live-verified against real Meet calls and a real `earsd` (journal `#28`–`#40`). This phase is Chrome-only-today → both-browsers-and-resilient. It has **three largely independent work streams** — Firefox parity, popup UI, and service-worker resilience — that can be split across separate subagents/sessions with minimal overlap. Read the whole prompt first, then pick a section (or hand each section to its own agent).

---

## Task

Close out the roadmap's Phase 7 exit bar: *"the full path runs on both browsers from the same source; the test suite covers protocol + identity parsing; a day-long call does not leak, double, or drop streams."*

## Context (read first)

- `docs/product/browser/specs/extension.md` §"Messaging" — Chrome vs Firefox background-context lifetime differences, the `storage` session-state requirement.
- `docs/product/browser/roadmap.md` Phase 7's bullet list (this is that list, expanded into an executable prompt).
- `browser/wxt.config.ts` — already declares `permissions: ["storage", "alarms"]` and a Firefox-only `browser_specific_settings.gecko.id` (`ears-capture@tomelliot.net`). Neither `alarms` nor `storage` is actually *used* anywhere in the code yet — the manifest surface is ahead of the implementation.
- `browser/package.json` scripts already include `dev:firefox` / `build:firefox` / `zip:firefox` (`wxt -b firefox --mv3` etc.) — the build targets exist; there's no evidence anyone has actually loaded the output in Firefox and confirmed it works. Don't assume it does.
- `browser/entrypoints/background.ts` — the MV3 service worker owning the `EarsSocket` WebSocket (`lib/transport.ts`) and the `browser.runtime.onConnect` PCM port. This is the file most of the service-worker-resilience work touches.
- `browser/entrypoints/popup/` — `index.html` + `main.ts`, currently a two-line stub (`"not connected"`, no interactivity, no toggle).
- **Test coverage note:** the roadmap's "vitest unit tests for `lib/protocol.ts` and the identity parsers" bullet is **already substantially done** as a side effect of Phases 1–3's work — `lib/protocol.test.ts`, `lib/identity/zoom.test.ts`, `lib/audio-tap.test.ts`, `lib/rtc-hook.test.ts`, and `lib/transport.test.ts` all exist and pass (run `bun run test` in `browser/` to confirm current state before assuming anything is missing). Don't redo this; extend it only where a specific new piece of logic in this task needs coverage (e.g. session-state serialization).

## Requirements

### A. Firefox parity (independent work stream)

- Actually build and load the extension in Firefox (`bun run build:firefox`, then load `browser/.output/firefox-mv3/manifest.json` as a temporary add-on via `about:debugging`) and confirm the baseline still works: hook installs, tracks capture, PCM flows to `background.ts`. Do this **before** writing new code — establish what's actually broken, if anything, rather than assuming.
- Confirm `world: "MAIN"` content-script injection timing holds on Firefox the same way it was validated on Chrome (`extension.md`'s injection-timing section references "Firefox has supported `world: "MAIN"` content scripts since v128" — verify against whatever Firefox version is actually available to test with, and record the version).
- Firefox's background context is a **persistent background page**, not a suspendable MV3 service worker — per `transport.md`'s "Per-browser lifetime" section, this should need *no* code change (same code path, just a stronger lifetime guarantee), but confirm empirically that `EarsSocket`'s reconnect logic still behaves correctly rather than assuming the stronger guarantee makes it moot.
- Confirm `earsd`'s `[earsd.ingest_ws].allowed_origins` allowlist correctly includes a real `moz-extension://<uuid>` origin during a live Firefox test — Firefox's extension UUID is **not** stable across installs the way Chrome's unpacked-path-derived id is (double-check this against `browser_specific_settings.gecko.id`, which pins the add-on id but may not pin the origin UUID used in `moz-extension://` URLs — verify empirically rather than assuming they're the same thing).
- **Live verification required:** a real Meet or Zoom call captured end-to-end through Firefox, reaching a real (or stub) earsd ingest endpoint. Not just "it builds."

### B. Popup UI (independent work stream)

- Build out `entrypoints/popup/` into: an on/off capture toggle, and a connection-status indicator (`background.ts` already computes `TransportStatus` — `"connecting" | "connected" | "disconnected"` — via `EarsSocket`'s status callback and does `browser.runtime.sendMessage({kind:"status", status: s})`; the popup needs to listen for this and also query current status on open via the existing `{kind:"get-status"}` message `background.ts` already answers).
- Decide and implement what "off" actually means at the architecture level before writing UI for it — currently there's no capture on/off gate anywhere in `hook.content.ts`/`audio-tap.ts` (capture is unconditionally active once the extension is loaded on a matching host). Toggling "off" needs either (a) a check early in `hook.content.ts`'s `main()` that reads persisted state and no-ops `startEpoch()` if off, or (b) some other mechanism — pick one and justify it in a doc comment; don't half-wire a UI toggle that doesn't actually stop capture.
- Persist the toggle state via the `storage` permission (`browser.storage.session` or `.local` — pick based on whether "off" should survive a browser restart; `extension.md`'s messaging section specifically calls out `storage` **session** area for "capture on/off and the active platform, so a respawned Chrome service worker recovers without re-handshaking" — that's about surviving a service-worker respawn *within* a browsing session, which argues for `session`, not `local`; think through whether the user-facing toggle should behave the same way or persist across restarts, and document the choice).
- Keep the popup CSP-safe and minimal — no new dependencies; the existing inline-styled two-file shape (`index.html` + `main.ts`) is fine to extend rather than replace with a framework.

### C. Service-worker resilience (independent work stream, overlaps with B on the storage/session piece)

- **Chrome `chrome.alarms` keepalive:** MV3 service workers suspend after ~30s of inactivity; WebSocket activity resets the idle timer (Chrome 116+, already relied on per `transport.md`), but a call with long silent stretches (no PCM frames because no one's talking, not because the socket is idle — check whether `EarsSocket` sends anything during silence, e.g. no) could still let the worker suspend. Add a `chrome.alarms` periodic wake (`browser.alarms.create` + `onAlarm` listener) frequent enough to keep the worker alive for the duration of an active capture session, and confirm it's a no-op / doesn't fire at all when the extension is idle (no active call) — this must not become a permanent battery-draining background wake.
- **Session-state recovery on service-worker respawn:** per `extension.md`'s messaging section, persist "capture on/off and the active platform" to `storage.session` so a respawned worker recovers without re-handshaking. Trace through what "recovers" concretely means given `background.ts`'s current structure — does a respawned worker need to reconnect `EarsSocket` (it already does, in the module's top-level `connect()` call, so this may already work for free) and re-associate with any already-open `runtime.connect({name:"pcm"})` ports from content scripts that were connected before the respawn (ports don't survive a service worker restart — confirm whether `content.ts`'s port reconnects on its own if the receiving end disappears, or whether that needs new reconnect logic in `content.ts` too)?
- **Live verification required, not just code review:** force a service-worker respawn mid-call (Chrome's `chrome://serviceworker-internals` has a manual "Stop" button for exactly this, or just wait out the idle timeout with an artificially quiet capture) and confirm capture resumes without the user having to reload the Meet/Zoom tab. This is the same category of test as the existing capture-epoch reinjection tests (journal `#28`–`#31`, `#39`) — don't skip it because it's fiddly to set up.

## Tests

- Unit-test whatever in each stream is pure logic (e.g. a `resolveCaptureToggleState` function, an alarm-interval calculation) — follow this repo's existing `*.test.ts` patterns (fake `chrome.alarms`/`chrome.storage` globals the same way `rtc-hook.test.ts` fakes `window`/`RTCPeerConnection`, not a heavy mocking library).
- Everything marked "live verification required" above is genuinely required per this repo's engineering-practices doc — WebRTC/extension-lifecycle behavior cannot be fully proven by unit tests alone. Don't report a sub-task done on the strength of a green test suite alone if it has a live-verification requirement attached.
- **Exit bar for the whole phase:** a day-long call does not leak, double, or drop streams. This is explicitly a soak/endurance property, not something any single test run proves — if you can't literally run a day-long call, say so explicitly and describe what you *did* verify (e.g. a forced respawn + a few hours) rather than silently claiming the full exit bar is met.

## Out of scope

- Meet/Zoom/Teams identity (Phases 4–6) — separate, independently-scoped work; don't let popup UI work drift into displaying participant names before Phase 4 makes them available.
- Any change to the audio capture pipeline (`rtc-hook.ts`, `audio-tap.ts`) — this phase is lifecycle/platform/UI hardening only.
- Safari — not in scope for any phase of this roadmap; don't add Safari-specific manifest handling speculatively.
