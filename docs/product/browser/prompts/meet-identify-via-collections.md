# Prompt: Meet identify() via the `collections` datachannel (Phase 4, implementation)

Use this prompt against the `all-ears` repo, `browser/` extension. It follows the speaking-indicator-correlation investigation (journal `#41`–`#51`) and replaces the "DOM correlation" plan in the original `meet-identity.md` — that path is confirmed dead (`#41`–`#46`). A working mechanism was found instead: the Meet `collections` `RTCDataChannel` carries a stable participant id on the wire.

## Context (read first)

- Journal `#49` — how the signal was found (debug-only `RTCDataChannel`/WebSocket tracer in `rtc-hook.ts`, gated behind `localStorage.__earsDebugChannels`) and the decoded wire format.
- Journal `#50` — correlation evidence: device-id-bearing messages land within tens of milliseconds of real speaking onset/offset, confirmed distinct across 2 participants.
- Journal `#51` — the decision to pursue this, and its caveats (one build, one session, two fields decoded — not the full schema).
- `docs/product/browser/specs/extension.md` §Platform adapter and MUST-NOT #6 — this implementation is the one thing MUST-NOT #6's narrow exception permits. Read the exception text before writing code; it does **not** license decoding anything else on `collections`, and does not touch Zoom's `__reduxStore`.
- `lib/identity/meet.ts` — current adapter; `identify()` returns `null` unconditionally, correctly, per `#46`. This task changes that.
- `lib/identity/adapter.ts` — `identify(track, stream, transceiver)` is **synchronous, one-shot, called at `+track` time**. The collections signal arrives *asynchronously*, on its own schedule, tied to speaking activity rather than track creation — this is a real interface mismatch, not a detail to paper over. See Task 3.

## The wire format (from journal `#49`, 2 samples, 1 build — treat as provisional)

Each `collections` message is gzip-compressed (magic `1f 8b 08 00`). Decompress with `DecompressionStream("gzip")`. The inflated payload is protobuf. The two fields that matter, by field-number path from the message root:

| Path | Type | Meaning |
|---|---|---|
| `1.2.3.2.6` | string | Device id, shape `spaces/<space>/devices/<device>` — the stable participant id |
| `1.2.3.2.4` | string | A numeric participant-number string (e.g. `"112470408"`) — secondary, not needed if the device id is captured |
| `1.2.3.10.1` | varint (0/1) | Speaking flag: `0` on the first message of a turn, `1` on a second message sent 0.4–1.5s after audio actually stops (debounced end-of-turn) |

Known-good fixtures (gzip bytes, hex) for a parser unit test — decode both and assert the extracted device id/flag match:
- Turn start, device 377, flag 0: `1f 8b 08 00 00 00 00 00 00 00 e3 e2 16 e2 cc 62 ef 62 64 e1 62 e2 60 04 00 04 9e e3 4c 0d 00 00 00`
- (Pull the remaining 3 fixtures — devices/377 flag=1, devices/378 flag=0/1 — from journal `#49`/`#50`'s linked evidence or re-capture live; don't hand-roll them from memory.)

## Task

### 1. Defensive protobuf field extraction

Write a minimal, dependency-free protobuf field walker in `lib/identity/meet.ts` (or a new `lib/identity/meet-collections.ts`) that extracts just the two fields above by path, tolerant of the schema being wrong:
- No protobuf library — hand-roll varint/length-delimited parsing (small surface, no build dependency).
- Any parse failure (wrong tag, truncated buffer, missing path) returns `null` — never throws into the datachannel message handler. This is a private, undocumented, unversioned wire format; treat every read as "might be garbage" by default.
- Unit-test against the fixtures above plus deliberately-corrupted variants (truncated buffer, wrong first byte, valid gzip but non-protobuf payload) — all must return `null`, not throw.

### 2. Wire it into `MeetAdapter`

- Attach a passive listener to the `collections` datachannel the same way the investigation's tracer did (`pc.addEventListener("datachannel", ...)` plus wrapping `createDataChannel`, in `rtc-hook.ts`, gated at hook-install time on `location.host === "meet.google.com"` like the existing encoded-audio tee — **not** behind the debug-only `__earsDebugChannels` flag, which stays investigation-only).
- On each successfully-parsed message, update an internal `Map<device id, {speaking: boolean, lastSeen: number}>` in `MeetAdapter`. This is state, not a correlation attempt yet — `identify()` still can't synchronously resolve a *track* to a *device id* from this alone (nothing here ties a `MediaStreamTrack` to a device id — only to "someone is/isn't speaking").
- Tile↔device-id correlation still needs the DOM: cross-reference against tile `data-participant-id`-equivalent... **except that doesn't exist either (`#41`–`#46`)**. Concretely, the same DOM tile↔track correlation problem this whole investigation started from is *not* solved by this signal alone — what it gives you is a ground-truth "who is speaking right now" independent of the DOM. Pair it with the audio-domain signal you already have (per-track decoded RMS, `audio-tap.ts`'s existing pipeline) using temporal correlation: when a device id's speaking flag flips to `1` (start), and within ~200ms exactly one live track's decoded audio also crosses into "speaking", that track↔device-id pairing is your candidate identity. Confirm it over multiple turns before trusting it (see Task 3's confidence-curve requirement) — a single coincidence is not enough, per `#50`'s multi-turn confirmation approach.

### 3. Resolve the sync-interface mismatch — don't paper over it

`identify()` cannot synchronously return a device id derived from a correlation that only becomes confident after observing one or more speaking turns. Do not hack around this with a blocking wait or a synchronous cache-and-hope inside `identify()`. Instead:
- Ship `identify()` unchanged in behavior for the *first* call on a fresh track (still returns `null` → `speaker-<n>`, audio never blocks).
- Add the `PlatformAdapter.onIdentify?(cb: (track, id) => void)` push-callback interface proposed in the investigation prompt's Task 4, implemented for real this time: once a track↔device-id pairing crosses your confidence bar, call back with the *upgraded* id.
- `audio-tap.ts`'s `resolveIdentity`/`startPipeline` needs a small, explicit extension to consume a late `onIdentify` upgrade for an already-started `speaker-<n>` pipeline (rename the participant id on the existing segment, or start a new segment — pick one and document why; check how `generations`/`fallbackIds` in `audio-tap.ts` behave either way before choosing). This is the one piece of this task that *does* touch `audio-tap.ts`, unlike the read-only investigation phase — call it out explicitly in the PR description since it's a deliberate, scoped exception to the "don't touch the pipeline" default.

### 4. Confidence & fallback

- Log (not per-frame — once per upgrade) when a track's identity is upgraded via this path, and keep a rolling confidence count (how many consecutive turns confirmed the same pairing) before calling `onIdentify`. Start conservative — require ≥3 confirming turns before the first callback — and record in the journal what that threshold's false-positive rate looked like in live testing before loosening it.
- If the `collections` channel doesn't appear, or messages stop parsing (schema changed), `identify()`/`onIdentify` must degrade silently to the existing `speaker-<n>` behavior — never throw, never stall capture. Warn once (matching `maybeWarnStructure()`'s existing pattern), not per-message.

## Tests

- Unit: the protobuf field walker (Task 1) against the fixtures + corrupted variants. Pure logic, no live call needed.
- Live (required, per this repo's engineering-practices doc): ≥3-person real Meet call, multi-turn (≥10 speaking events across ≥2 non-self participants) — confirm the confidence-threshold upgrade path actually fires, lands on the correct participant every time, and survives a mute/unmute cycle and a track-churn event (the `AudioDecoder` error case from journal `#45`) without misattributing a new track to the wrong device id.

## Out of scope

- Any other `collections` field beyond the two in the table above — if you find yourself decoding more of the schema to make this work, stop and get that reviewed as its own scoped addition to the MUST-NOT #6 exception, not folded in here.
- Zoom/Teams — unaffected, unrelated mechanism.
- Popup UI changes (Phase 7).
