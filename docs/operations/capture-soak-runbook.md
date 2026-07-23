# Capture daemon soak-test runbook

Manual procedure for checking the capture daemon's core reliability claim:
"daemon runs for days at a flat memory baseline; disk usage tracks meeting
activity and retention, not elapsed time; gaps recorded across sleep/wake and
device unplug." This is a real-world, multi-day claim about a running process
on real hardware — no automated test can establish it, and none here claims
to.

## What already exists, and what this fills in

The CI suites (`EarsDaemonTests`, `EvictionSweeperTests`) prove the logic
deterministically: an idle daemon writes nothing, a meeting's audio lands
under its own `meetings/<id>/sources/` directory, and the retention sweeper
deletes an ended meeting's audio at its transcript-driven deadline (driven by
a `ManualClock`, so no real time passes). What they cannot demonstrate is
flat process *memory* over real days, nor real sleep/wake or device unplug —
those only happen on a real machine over real time. This runbook is the
manual procedure a human runs to actually check those things before treating
the exit criterion as met. Nothing in this file or in the code should claim
this is automated — it isn't.

## Setup

1. Build a release binary from `daemon/`: `swift build -c release`. The
   binary lands at `daemon/.build/release/earsd`.
2. Write a config with exactly one enabled source (mic keeps the run simple), a
   real `data_root` with room to spare, and a `--log-file` so `earsd`'s own
   structured log survives the whole run. A short retention window makes
   eviction observable within the run:

   ```toml
   data_root = "/Users/you/soak-test/data"

   [earsd]
   [[earsd.source]]
   id = "mic"
   class = "mic"

   [earsd.retention]
   evict_after_transcript_seconds = 3600
   max_audio_age_seconds = 14400
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
overnight system sleep. Several times a day, drive a real meeting cycle:

```sh
ears meeting start --source mic     # prints the meeting id
# ...talk for a few minutes...
ears meeting end <id>
```

Longer is better; the point is to see whether any of the sub-criteria below
drift with elapsed time, and a few hours is too short to distinguish a slow
leak from noise.

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

**Expected:** RSS stays flat while idle, may tick up during an active
meeting, and returns to the baseline after each meeting ends (its capture
actors are torn down). A slow, steady climb across hours/days — especially
one that survives meeting teardown — is a leak: treat that as a failed run,
not noise, and file it before calling capture reliable.

### 2. Disk usage tracks meetings and retention, not elapsed time

```sh
du -sh <data_root>/meetings/*/sources 2>/dev/null
ls <data_root>/meetings
```

Sampled on the same cadence as RSS above. **Expected:** an idle daemon
writes nothing (no new directories between meetings). Each meeting's
`sources/` directory grows only while that meeting is active. Once a
meeting's transcript completes, its `sources/` directory disappears within
`evict_after_transcript_seconds` (plus up to one sweep interval); a meeting
whose transcript failed keeps its audio until `max_audio_age_seconds` after
it ended, then loses it too. `meeting.toml` and `events.jsonl` remain for
every meeting. Audio directories that outlive their deadline mean retention
is broken — file it.

### 3. Gaps are recorded across sleep/wake and device unplug

Each source's `chunks.jsonl` (under the active meeting's directory)
discriminates events on `"t"`; watch it with `tail -f` **during an active
meeting** for each scenario below (`docs/data-formats.md`'s "The index" and
`docs/specs/capture-daemon.md`'s "Power/idle awareness").

**Sleep/wake.** With a meeting active, put the machine to sleep (lid close,
or Apple menu → Sleep) for at least several minutes, then wake it. Confirm:
- a `{"t":"gap", ..., "reason":"pause"}` event appears, covering the
  suspended interval (`PowerObserver` pauses every source on
  `NSWorkspace.willSleepNotification`/screen-lock, `CaptureActor.pause()`
  records the gap).
- capture visibly resumes afterward — new `chunk`/`vad` events with
  timestamps past the gap's `end`.

**Restart mid-meeting.** Stop `earsd` cleanly (`kill -TERM <pid>`, or Ctrl-C
in the foreground terminal) while a meeting is active, wait a few minutes,
then start it again with the same config. Confirm the meeting resumes
capture (new `chunk` events appear under the *same* meeting directory) —
`MeetingRegistry.loadFromDisk()` restarts a still-active meeting's sources.

**Device unplug/replug.** With a meeting active, physically unplug the
configured microphone (or switch the default input device in System
Settings → Sound) for at least a minute, then reconnect it. Watch both
`earsd`'s own log (`--log-file`) and the meeting's `chunks.jsonl` across the
outage window.

> **Known open gap, found by inspecting the code while writing this
> runbook, not yet fixed:** `MicCaptureBackend.swift` rebuilds the Core Audio
> engine on a device-route change (with backoff), but nothing in that path
> emits an explicit `{"t":"gap",...}` index event for the outage window the
> way pause/resume does — the interval where no frames arrive during the
> rebuild isn't distinguished from an ordinary VAD silence span. When you run
> this scenario, check `chunks.jsonl` for whether *any* event actually covers
> the unplug window. If none does, this sub-criterion is not met yet — record
> that plainly rather than assuming device-unplug gap recording works because
> sleep/wake does.

## Recording the result

For each run, keep:
- start/end timestamps, macOS version, hardware, and the config file used.
- the sampled RSS log and `du`/directory-listing samples.
- for each of the sleep/wake, mid-meeting restart, and device-unplug
  scenarios: the timestamp you triggered it, and the exact `chunks.jsonl`
  line(s) (or their absence) that resulted.
- a plain statement of whether each sub-criterion held — and, if the
  device-unplug gap above is still unfixed at the time you run this, say so
  explicitly rather than marking the exit criterion met.

## Non-goals of this runbook

- Does not replace the CI suites, which keep running on every commit as the
  regression guard on the meeting-scoped capture and retention *logic*.
- Does not cover multi-source scenarios — this procedure only exercises the
  single `mic` source.
