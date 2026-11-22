# Live-call probes

Read-only console scripts for answering a question about a real call that no fixture can answer. They are paste-in scripts, deliberately **not** extension code: a probe shipped into the live extension untested once killed capture mid-call, and these run beside the extension where they cannot reach the capture path.

Every probe here obeys the same three rules. It polls and diffs rather than attaching listeners to page objects; it mutates nothing; and it never emits a display name — free text is reduced to a stable 7-character hash, so `row ·1196iw7 lit up 14 times` is answerable without the log ever carrying who that is. Developer-authored strings (class names, `data-tid` values) do come out verbatim, because they are how the selector gets written afterwards.

| Probe | Question |
|---|---|
| `meet-identity-probe.js` | Which streams belong in the transcript, and which tile is the local user (journal #142, #158) |
| `teams-identity-probe.js` | Where Teams keeps participant identity, and whether a speaking signal exists in the DOM at all |
| `zoom-names-probe.js` | Whether the selectors in `identity/zoom-dom.ts` match the live web client, and which classes hold the names if not |

## Teams: finding the speaker-name signal

Teams hands the extension **one mixed far-end track** — `identity/teams.ts` returns `null`, so every remote voice files as `browser:teams:<track>` and the transcript labels them all identically. Naming turns needs two things from the DOM, neither verified on any current build: a stable per-participant key with a name attached, and a signal that toggles while someone speaks.

The probe hunts rather than assuming selectors. It censuses the attribute surface once (expensive, ~5ms on the Teams SPA), decides which attributes look like participant rows, then diffs those rows every second. **Whichever attribute flips on and off while people talk is the speaking signal.** Every toggle is timestamped in wall clock so the log lines up against the daemon's own record of the call: the audio says *when* someone spoke, the probe says *which row lit up*.

It polices its own cost — three ticks over 15ms and it backs off to 5s, because it is running on the thread the call renders on.

### Before the call

```sh
python3 browser/dev/probes/probe-receiver.py --out ~/probe-dumps
```

Leave it running. It writes each POSTed dump to a file and prints a one-line summary.

### In the call

Open DevTools on the tab that is **in** the call, paste the contents of `teams-identity-probe.js`, and check the banner it returns:

```
__earsTeams ready — rows=7, rowAttrs=data-participant-mri
```

`rowAttrs=NONE` means the census found no participant key — run `__earsTeams.census()` after opening the People panel and see whether rows appear. That answer is itself a finding: Meet's roster panel stays mounted at 0×0 when closed (journal #169), and whether Teams does the same decides if the extension can read identity without the user opening anything.

Then just let it run. When the call ends:

```js
__earsTeams.post()     // → the receiver
__earsTeams.stop()
```

`__earsTeams.dump()` returns the same object if you would rather read it in the console.

### Checking it before you trust it

```sh
node browser/dev/probes/teams-identity-probe.smoke.mjs      # add VERBOSE=1 to see the log it produces
```

Drives the probe against a synthetic Teams-shaped DOM: asserts the census finds the row key, that a speaking-class toggle reaches the change log, and — the part worth having a test for — that no display name, MRI, or meeting URL survives into the output.

## Zoom: checking the name selectors

`identity/zoom-dom.ts` reads participant names and the meeting topic from class names. The tile names are confirmed live; the participants panel, pre-join field and topic selectors are not. In a call, open DevTools on the Zoom tab, paste `zoom-names-probe.js`, and read the JSON it logs. Each selector lists one hash per match, plus the role suffix Zoom put on it (`host`, `host, me`), never the name. A selector with no matches and a `classes` census that shows the real name holder means the selector needs changing. Nothing is clicked.

To find what marks your own tile, run `copy(JSON.stringify(__earsZoom.snapshot("Your Name")))` twice: once with the Participants panel closed and once with it open. The name is compared, never printed. Read:

- `self.ownOnly`: classes and attribute names on your tile's ancestry that no other tile has. A self-view class here is the tile signal `zoom-dom.ts` lacks.
- `participantRows[].label` on the `own: true` row: `(Host, me)` or `Me` confirms the panel marker and its selector.
- `preJoin`: whether the pre-join field exists in this frame. Run the probe once on the pre-join screen too.
- `selfNames` and `selfText`: any class, id or attribute name that says "self", and any element whose text or aria-label carries `(me)`.
