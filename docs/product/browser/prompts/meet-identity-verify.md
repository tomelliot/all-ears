# Prompt: Meet identity — live verification & finalization (Phase 4, part 2)

Use this prompt against the `all-ears` repo, on branch `claude/meet-identity-docs-f4pau2`, from a machine with Chrome, browser control (`claude-in-chrome` or manual DevTools), and the `journal` CLI. It finalizes [`meet-identity.md`](meet-identity.md): the adapter is implemented (commit `f6770df`, `browser/lib/identity/meet.ts` + `meet.test.ts`) but was built in a remote environment with no browser access, so the **empirical verification required by that prompt's §1 has not run** and no journal evidence exists yet. Everything below is about closing that gap — the code may be finished, partially wrong, or need its fallback promoted; only a live call can tell.

## Current state (read the adapter's doc comment first)

- `MeetAdapter.identify()` implements tile-DOM correlation per `specs/extension.md` §Platform adapter: match the captured track to a media element (exact track object → track `.id` → shared-msid `MediaStream`), climb to the nearest ancestor carrying one of `PARTICIPANT_ID_ATTRIBUTES` (`data-participant-id`, `data-requested-participant-id`, `data-initial-participant-id`), return the raw attribute value. Display name probes: own/descendant `data-self-name`, then `aria-label`.
- All misses return `null` → `audio-tap.ts`'s `speaker-<n>` fallback. A structural total failure (media rendering, zero tiles with any expected attribute) warns once.
- The `MutationObserver` only marks a cache dirty; rescans are lazy inside `identify()`/`displayName()`.
- The CSRC fallback (`getContributingSources()`) is **documented in the doc comment but deliberately not implemented** — this task decides whether it's needed.
- Unit tests: `bun run test` (hand-rolled DOM fakes, node env). `bun run compile` and `bun run build` are green.

## Task

### 1. Live inspection (≥2 other participants; record everything as journal evidence)

Build (`cd browser && bun run build`), load `.output/chrome-mv3` unpacked, join a real Meet call, then answer — in DevTools on the meet.google.com tab, MAIN world:

1. **Which id attribute holds on this build?**
   ```js
   document.querySelectorAll("[data-participant-id],[data-requested-participant-id],[data-initial-participant-id]")
   ```
   For each hit: which attribute, what the value looks like (`spaces/…/devices/…`?), and where the display-name text lives relative to it (is `data-self-name`/`aria-label` right?).
2. **Does the correlation channel exist?** Enumerate media elements:
   ```js
   [...document.querySelectorAll("audio,video")].map(el => ({
     tag: el.tagName, streamId: el.srcObject?.id,
     tracks: el.srcObject?.getTracks().map(t => `${t.kind}:${t.id}`),
   }))
   ```
   Compare against the `[ears] +track → …` console lines (each logs when a pipeline starts; `localStorage.setItem("__earsDebugAudio","1")` + reload adds per-participant RMS logs). The known risk (journal `#28`–`#31`): Meet decodes audio in WASM, so tile media elements may hold Meet-generated streams whose track ids **don't** match the RTC tracks — in that case check whether the msid/stream-id fallback matches (tile `<video>` sharing the audio track's stream id).
3. **Ordering:** are tiles mounted by the time `+track` fires? `identify()` runs once, synchronously, per track — a tile that mounts later means that track stays `speaker-<n>` (acceptable per Phase 4's exit bar, but record which way it goes).

`journal add --type evidence` for each finding, in the style of `#28`–`#31`.

### 2. Act on what you find

- **Adapter correct as-is** → no code change; go to §3.
- **Attribute/name probes drifted** → update `PARTICIPANT_ID_ATTRIBUTES` / `extractDisplayName` in `meet.ts`, extend `meet.test.ts` with fixtures matching the *observed* DOM, re-verify live.
- **Tile-DOM doesn't hold at all** (no correlation channel from any media element to the RTC tracks) → implement the CSRC path per `meet-identity.md` §3 as the primary mechanism, and say so in the adapter's doc comment. Constraints still apply: reading `getContributingSources()` on the already-known receiver is fine (not track discovery); never per-frame single-winner attribution silently dropping simultaneous speakers; if it's attribution rather than identity, label it that way (as `teams.ts` does) — don't present it as verified identity.
- Whatever the outcome, **rewrite the adapter's `VERIFICATION STATUS` doc comment** to state what was verified, on what date/build, with journal entry numbers — it currently says verification has NOT run, and that must not survive this task.

### 3. Exit criteria (roadmap Phase 4 — all live, none substitutable with unit tests)

- ≥3-person call: each speaker's earsd source carries their real name/id (`browser:meet:<sanitized-id>`; `sanitizeLabel` maps `/` → `-`), and each source's audio is only that speaker's (isolation was proven in Phase 2/3 — confirm the *label* is right and isolation didn't regress).
- Mute → unmute: same id, new segment (should hold — `audio-tap.ts` untouched — but confirm).
- Leave → rejoin: a new id/segment is fine; the display name must be correct, not stale or blank.
- `bun run compile && bun run test && bun run build` green; commit to this branch with journal entry numbers referenced in the message.

## Out of scope (unchanged from meet-identity.md)

No changes to `rtc-hook.ts`/`audio-tap.ts`'s audio pipeline; no Zoom/Teams work; no decoding Meet's private protobuf/Redux state under any circumstance; no popup UI for names (Phase 7). `identify()` must stay synchronous and null-safe — audio never blocks on identity.
