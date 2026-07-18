# Prompt: Meet identity (Phase 4)

Use this prompt against the `all-ears` repo, `browser/` extension. It's the next roadmap phase after Phase 3 (WebSocket ingest, landed and live-verified — see journal `#32`–`#40`). Right now every Meet participant is captured correctly (audio isolation is done and live-verified) but shows up as an anonymous `speaker-1`/`speaker-2`/... — this task attaches their real name/id.

---

## Task

Implement `lib/identity/meet.ts`'s `MeetAdapter.identify()` for real, replacing the current placeholder that always returns `null`. Correlate each captured remote audio track to the Meet participant tile it belongs to, and read a stable participant id (plus display name) off that tile's DOM.

## Context (read first)

- `docs/product/browser/specs/extension.md` §"Platform adapter" — the `PlatformAdapter` interface and the documented approach for Meet: *"Meet renders a per-participant `<audio>`/`<video>` per tile. Correlate the captured stream to its tile and read `data-participant-id` (+ display name from the tile). A `MutationObserver` maintains the tile↔stream map; the CSRC `audioLevel` path (`RTCRtpReceiver.prototype.getContributingSources`) is the documented fallback if a build stops exposing per-tile elements. Confidence: medium — verify which holds on the current Meet build."* Treat "confidence: medium" as literal — the first real step of this task is empirical verification against a live Meet call, the same way the Phase 2 `createEncodedStreams` finding was empirically driven (see journal `#28`–`#31`), not an assumption to build blind against.
- `lib/identity/adapter.ts` — the `PlatformAdapter` interface every adapter implements:
  ```ts
  export interface PlatformAdapter {
    readonly platform: "meet" | "zoom" | "teams";
    identify(track: MediaStreamTrack, stream: MediaStream, transceiver: RTCRtpTransceiver): ParticipantId | null;
    displayName?(id: ParticipantId): string | undefined;
    dispose?(): void;
  }
  ```
  `null` → the caller (`audio-tap.ts`'s `resolveIdentity`) assigns a stable `speaker-<n>` per track. Audio must never block on identity — a broken/changed Meet DOM must degrade to `speaker-<n>`, never throw or hang.
- `lib/identity/zoom.ts` — the one *real* (non-placeholder) adapter today, useful as a shape reference even though Zoom's mechanism (MSID parsing, no DOM) is completely different from what Meet needs (DOM correlation). Its test file `lib/identity/zoom.test.ts` shows the expected unit-test shape for a pure parsing/correlation helper.
- `lib/identity/meet.ts` — current placeholder:
  ```ts
  class MeetAdapter implements PlatformAdapter {
    readonly platform = "meet" as const;
    identify(): null { return null; }
  }
  registerAdapter((host) => host === "meet.google.com", () => new MeetAdapter());
  ```
- `lib/audio-tap.ts`'s `resolveIdentity(track, stream, transceiver)` — calls `cfg.adapter?.identify(...)` once per track, on first `+track` (see `startPipeline`). Falls back to a `WeakMap<MediaStreamTrack, ParticipantId>`-backed `speaker-<n>` if `identify()` returns `null`, keyed so a re-adopted track (epoch handoff) keeps its id. **Do not** change this fallback logic — `meet.ts` only needs to make `identify()` return a real id when it can.
- **MUST-NOT** (from `extension.md`'s constraints list, directly relevant here): no decoding Meet's private protobuf/Redux internals (the `collections` datachannel) for identity — "the largest maintenance sink." DOM/MSID signals only. No enumerating `getReceivers()`/`getTransceivers()` for *track discovery* (that's `rtc-hook.ts`'s job and is unaffected by this task) — but reading `getContributingSources()` on the *already-known* receiver for the CSRC fallback is fine, that's not track discovery.

## Requirements

### 1. Empirical verification first (live Meet call required)

Before writing the adapter, join a real Meet call with ≥2 other participants and inspect the live DOM (via `claude-in-chrome` or the same manual DevTools workflow used in the Phase 2/3 verification) to answer:

- Does each participant's tile carry a stable `data-participant-id`-shaped attribute (exact attribute name may have changed — verify, don't assume)? Where does the display name text live relative to it?
- Is there a per-tile `<audio>` (or `<video>` with an audio track) element with `.srcObject` set to a `MediaStream`? Does that stream's tracks match the ones `rtc-hook.ts` already captures via the `track` event (same `MediaStreamTrack` object, or same `.id`)?
- Does the tile structure exist at the moment `identify()` would first be called (on `+track`), or does it appear later (e.g., tiles render before the RTCPeerConnection track fires, or vice versa) — this determines whether correlation needs to be async/retried rather than synchronous.

Record findings as journal entries (`journal add --type evidence`) the same way `#28`–`#31` documented the encoded-streams finding, before committing to an implementation. If the tile-DOM approach doesn't hold on the current build, fall back to the CSRC path (§3) as the primary mechanism instead, and say so explicitly in the adapter's doc comment — don't silently half-implement both.

### 2. Tile-DOM correlation (primary path, if §1 confirms it holds)

- A `MutationObserver` on the meeting-grid container (or `document.body` if no stable container exists) maintaining a tile↔stream map, added/updated as tiles mount and their `srcObject` gets set, removed as tiles unmount.
- `identify(track, stream, transceiver)` looks up which tile's stream contains `track` (by `MediaStreamTrack` identity or `.id`) and reads that tile's participant-id attribute.
- `displayName(id)` returns the cached display name text for that id, if still known.
- Handle the ordering race explicitly: if `identify()` is called before the tile exists yet, it should return `null` for now (audio still flows under `speaker-<n>`) — do **not** block or await inside `identify()`, it must stay synchronous per the interface. If the tile appears *later*, that's fine — Phase 4's exit bar doesn't require retroactively renaming an already-started `speaker-<n>` segment (see Exit criteria below for what's actually required).

### 3. CSRC fallback (if §1 shows tile-DOM doesn't hold, or as a documented secondary path)

- Use `RTCRtpReceiver.prototype.getContributingSources()` on the receiver behind `transceiver` to read per-frame CSRC + `audioLevel`, correlating against Meet's own participant roster (if a roster API/DOM list is separately available) or against tile data by CSRC where possible.
- Per the spec's constraint list: never make per-frame single-winner CSRC attribution silently drop simultaneous speakers — that's the Teams-style attribution failure mode this constraint exists to prevent. If CSRC can only give attribution (not true isolation) on the build you're testing against, treat that the same way `teams.ts` treats its dominant-speaker approach: label it as `Speaker N`-style attribution, not a confident identity, and say so in the doc comment. Do not silently present attribution as if it were verified per-participant identity.

### 4. Universal fallback stays intact

`identify()` returning `null` must remain a safe, expected, non-error outcome (a DOM structure change, a tile that hasn't mounted yet, a track this adapter genuinely can't place) — `audio-tap.ts`'s existing `speaker-<n>` fallback handles it. Don't add error throwing or logging noise for the normal "not yet correlated" case; do log (once, not per-frame) if the tile-DOM structure looks fundamentally different from what `identify()` expects (e.g., the expected attribute is missing from *every* tile), since that's the "MUST NOT swallow injection-order errors" principle — a silent total failure here looks like working code that happens to produce zero real names, which is worse than a loud one-time warning.

### 5. `dispose()`

Implement it to disconnect the `MutationObserver` and clear the tile map — called on... check whether anything currently calls `adapter.dispose()` (search `hook.content.ts` and `audio-tap.ts`); if nothing does yet, that's a pre-existing gap outside this task's scope, but make sure `dispose()` itself is correct and idempotent so it's ready whenever epoch teardown starts calling it.

## Tests

- `lib/identity/meet.test.ts`: unit-test whatever in this change is pure logic — e.g. a DOM-parsing helper (`extractParticipantID(tileElement): string | null`, `extractDisplayName(tileElement): string | undefined`) fed synthetic DOM fixtures (JSDOM is not currently configured for this project — check `vitest.config.ts`'s `environment: "node"` — you may need a per-file `// @vitest-environment jsdom` override or a minimal hand-built fake-DOM object shape, matching this repo's existing preference for small hand-rolled fakes over heavy tooling, e.g. `rtc-hook.test.ts`'s fake `RTCPeerConnection`/`RTCRtpReceiver`). Don't try to unit-test the live `MutationObserver` wiring itself — that's what live verification is for.
- Live verification (required, cannot be substituted with unit tests per this repo's engineering-practices doc — same requirement Phase 2/3 followed):
  - ≥3-person real Meet call: each speaker's earsd source carries their real name/id, and each source's audio is genuinely only that speaker's (isolation was already proven in Phase 2/3 — this just confirms the *label* is now correct, not a regression in isolation).
  - A participant who mutes and unmutes keeps the same id (new segment, same underlying source) — this should already hold given `audio-tap.ts`'s generation/segment logic is untouched by this task, but confirm it wasn't broken.
  - A participant who leaves and rejoins: reasonable to get a *new* id/segment (matches how Meet Phase 3's `browser:meet:<label>` source-reuse logic already works per-label) — confirm the label itself (name) is still correct on rejoin, not stale or blank.

## Out of scope

- Any change to `rtc-hook.ts` or `audio-tap.ts`'s audio pipeline — this task only changes what `identify()`/`displayName()` return, never how audio is captured/decoded/resampled.
- Zoom or Teams identity (Phases 5/6) — separate, already-scoped work.
- Decoding Meet's private protobuf/Redux state for identity, under any circumstance — ruled out by the spec's MUST-NOT list, not a case-by-case judgment call.
- Popup UI changes to *display* participant names (Phase 7) — this task only makes the names available on captured `earsd` sources.
