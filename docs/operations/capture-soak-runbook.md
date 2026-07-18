# Capture daemon soak-test runbook

Manual procedure for checking [the roadmap](../product/roadmap.md)'s Phase 1
exit criterion: "daemon runs for days at a flat memory baseline; buffer stays
bounded; gaps recorded across restarts, sleep/wake, and device unplug." This
is a real-world, multi-day claim about a running process on real hardware —
no automated test can establish it, and none here claims to.

## What already exists, and what this fills in

`SoakProxyTests` (`daemon/Tests/EarsDaemonKitTests/SoakProxyTests.swift`)
drives a real `CaptureActor` through hundreds of accelerated rollover/
eviction cycles with a `ManualClock`, and asserts the on-disk ring buffer
converges to a bounded file count and byte footprint. It runs in CI on every
commit and is a genuine regression guard on the eviction *logic*. Its own doc
comment is explicit that it is "a proxy, not a proof": it cannot demonstrate
flat process *memory* over real days, nor real restarts, sleep/wake, or
device unplug — those only happen on a real machine over real time. This
runbook is the manual procedure a human runs to actually check those things
before treating the exit criterion as met. Nothing in this file or in the
code should claim this is automated — it isn't.

## Setup

1. Build a release binary from `daemon/`: `swift build -c release`. The
   binary lands at `daemon/.build/release/earsd`.
2. Write a config with exactly one enabled source (Phase 1 is mic-only), a
   real `data_root` with room to spare, and a `--log-file` so `earsd`'s own
   structured log survives the whole run:

   ```toml
   data_root = "/Users/you/soak-test/data"

   [earsd]
   [[earsd.source]]
   id = "mic"
   class = "mic"
   ```

3. Start it in the foreground of a terminal you can leave running (or under
   `nohup .../earsd --config soak.toml --log-file soak.jsonl &` so it survives
   a closed terminal). There is no installed `launchd` agent to rely on yet —
   `LaunchAgentPlist` generates plist *content* but writing it to disk and
   registering it via `SMAppService`/`launchctl` is still a manual step per
   `docs/distribution.md` — so driving `earsd` directly is the current
   procedure, not a shortcut.
4. Record the start timestamp, macOS version, and hardware.

Run for **at least 48–72 hours continuously**, spanning at least one real
overnight system sleep and one real microphone unplug/replug. Longer is
better; the point is to see whether any of the three sub-criteria below drift
with elapsed time, and a few hours is too short to distinguish a slow leak
from noise.

## What to watch

### 1. Memory (RSS) stays flat

Sample resident set size periodically for the life of the run:

```sh
while true; do
  ps -o pid,rss,etime,command -p "$(pgrep -x earsd)" >> soak-rss.log
  sleep 900   # 15 minutes
done
```

(Activity Monitor's Memory column, with `earsd` pinned in the window, works
equally well for a spot check — the log above is so you have a record to
attach afterward.)

**Expected:** RSS ramps briefly as the ring buffer fills to its `time_cap`,
then flattens and stays flat — no sustained upward trend across the run. A
slow, steady climb across hours/days is exactly the "buffer scales with time
on disk instead of being bounded" failure this criterion exists to catch —
treat that as a failed run, not noise, and file it before considering Phase 1
done.

### 2. The on-disk ring buffer stays bounded

```sh
du -sh <data_root>/sources/mic/chunks <data_root>/sources/mic/asr
ls <data_root>/sources/mic/chunks | wc -l
```

Sampled on the same cadence as RSS above. **Expected:** both directories'
size and file count converge to roughly `time_cap_seconds / chunk_seconds`
files and stay there — not keep growing. `index.jsonl` **will** keep growing
for the whole run; it is an append-only log by design (`docs/data-formats.md`),
not the ring buffer — don't mistake its size for a leak.

### 3. Gaps are recorded across restarts, sleep/wake, and device unplug

`index.jsonl` discriminates events on `"t"`; watch it with `tail -f` during
each of the three scenarios below (`docs/data-formats.md`'s "The index" and
`docs/specs/capture-daemon.md`'s "Power/idle awareness").

**Sleep/wake.** Put the machine to sleep (lid close, or Apple menu → Sleep)
for at least several minutes mid-run, then wake it. Confirm:
- a `{"t":"gap", ..., "reason":"pause"}` event appears, covering the
  suspended interval (`PowerObserver` pauses every source on
  `NSWorkspace.willSleepNotification`/screen-lock, `CaptureActor.pause()`
  records the gap).
- capture visibly resumes afterward — new `chunk`/`vad` events with
  timestamps past the gap's `end`.

**Restart.** Stop `earsd` cleanly (`kill -TERM <pid>`, or Ctrl-C in the
foreground terminal), wait a few minutes, then start it again with the same
config. Confirm a `{"t":"gap", ..., "reason":"daemon_restart"}` event appears
on the next startup, covering the downtime (`StartupGapDetector`).

**Device unplug/replug.** Physically unplug the configured microphone (or
switch the default input device in System Settings → Sound) for at least a
minute, then reconnect it. Watch both `earsd`'s own log (`--log-file`) and
`index.jsonl` across the outage window.

> **Known open gap, found by inspecting the code while writing this
> runbook, not yet fixed:** `MicCaptureBackend.swift` rebuilds the Core Audio
> engine on a device-route change (with backoff), but nothing in that path
> emits an explicit `{"t":"gap",...}` index event for the outage window the
> way pause/resume and restart do — the interval where no frames arrive
> during the rebuild isn't distinguished from an ordinary VAD silence span.
> When you run this scenario, check `index.jsonl` for whether *any* event
> actually covers the unplug window. If none does, this sub-criterion is not
> met yet — record that plainly rather than assuming device-unplug gap
> recording works because sleep/wake and restart do.

## Recording the result

For each run, keep:
- start/end timestamps, macOS version, hardware, and the config file used.
- the sampled RSS log and `du`/file-count samples.
- for each of the three sleep/wake, restart, and device-unplug scenarios: the
  timestamp you triggered it, and the exact `index.jsonl` line(s) (or their
  absence) that resulted.
- a plain statement of whether each of the three sub-criteria held — and, if
  the device-unplug gap above is still unfixed at the time you run this,
  say so explicitly rather than marking the exit criterion met.

## Non-goals of this runbook

- Does not replace `SoakProxyTests`, which keeps running in CI on every
  commit as the regression guard on the eviction/bounded-file *logic*.
- Does not cover multi-source scenarios — Phase 1 is mic-only, so this
  procedure only exercises the single `mic` source.
