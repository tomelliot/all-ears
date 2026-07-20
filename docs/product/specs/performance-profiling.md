# Performance profiling (proposal)

Status: **proposal — options and tradeoffs for review, with a recommendation.**

The suite needs opt-in performance profiling so the cost of each component — capture,
encoding, VAD, transcription, LLM stages — can be observed and compared: CPU, memory,
disk I/O, energy, and (as far as the platform allows) GPU/ANE. Each component gets its
own configuration toggle; everything is **off by default** and adds near-zero cost when
disabled.

## What to measure

The metrics worth having, and where each comes from on macOS. Nearly all of the
process-level numbers come from **one public syscall**:
`proc_pid_rusage(getpid(), RUSAGE_INFO_V6, …)` (`<libproc.h>`, no root, no entitlement
for your own process).

| Metric | Source | Notes |
|---|---|---|
| CPU time (user/system) | `ri_user_time` / `ri_system_time` | Mach-tick values; convert via `mach_timebase_info`. Delta between samples → utilisation %. |
| Memory footprint | `ri_phys_footprint` | The number that matters on Apple platforms (what Activity Monitor "Memory" and jetsam use), **not** RSS. `ri_lifetime_max_phys_footprint` gives the peak for free. |
| Disk I/O | `ri_diskio_bytesread` / `ri_diskio_byteswritten`, `ri_logical_writes` | Answers the "constant recording to disk" question directly. Logical vs physical writes exposes write amplification from the atomic temp+rename pattern and `index.jsonl` appends. |
| Energy | `ri_billed_energy` (nJ, Apple Silicon) | For an always-on laptop daemon this is arguably the most user-visible cost of all. |
| Timer wakeups | `ri_pkg_idle_wkups` | What macOS's energy accounting punishes. The 5 ms consumer drain poll (`MicCaptureBackend.runConsumerLoop`) is a likely finding here. |
| ANE memory | `ri_neural_footprint` (`RUSAGE_INFO_V6`) | The **only** per-process ANE signal Apple exposes publicly. |
| ANE/GPU *utilisation* | — none (public, per-process) | See below. Proxies: wall time and queue depth at `ANEInferenceGate`, RTF. Deep dives via Instruments / `powermetrics`. |
| Thermal state | `ProcessInfo.processInfo.thermalState` | System-wide, but essential context: explains ANE/CPU throttling in the same record. |
| Chunk write latency | app-level, in `ChunkEncoder` | Per-chunk encode+write duration and bytes. Catches I/O stalls (sleep/wake, disk pressure) that process counters average away. |
| Capture health | already exists (`CaptureStats`, ring occupancy, heartbeat age) | Dropped-sample count exists but isn't surfaced on the wire yet; profiling gives it a home. |

**Beyond CPU/GPU/memory, the metrics missing from the original list** are: **energy +
wakeups** (for a daemon that runs 24/7 on battery, this is the one users will actually
notice), **disk bytes written + per-chunk write latency** (the recording-to-disk cost —
steady-state is small, ~28 MB/h/source at 64 kbps AAC ×2 feeds, but amplification and
latency spikes are worth watching), **peak footprint**, and **thermal state**.

### The GPU/ANE reality

There is no public API for per-process GPU or ANE utilisation on macOS. `powermetrics`
can report ANE/GPU power system-wide but requires root; tools like macmon/asitop use
private IOReport APIs. A user-level LaunchAgent should not depend on either. The
workable strategy:

1. **Measure the work, not the silicon**: every Core ML call in the suite is already
   funnelled through `ANEInferenceGate` (`EarsCore/Concurrency/ANEInferenceGate.swift`)
   — a single choke point. Record hold-duration, queue depth, and per-slice RTF there
   and you have ANE *load* (how busy we keep it, how contended it is) without any
   private API.
2. **Attribute the silicon in deep dives**: `os_signpost` intervals around model load /
   decode / diarization light up Instruments' Core ML, GPU, and Neural Engine
   instruments, where real utilisation attribution lives. That is a dev-time activity,
   not continuous monitoring — and that split is fine.

## Options considered

### A. In-house sampler emitting `metrics.sample` JSON records — **recommended core**

A small tier-2 module (`EarsMetrics`) wrapping `proc_pid_rusage` + `thermalState` into a
`ResourceSnapshot`; pure delta/rate math lives in `EarsCore` (tier-0, unit-tested). The
daemon runs a sampler task on an interval emitting a periodic `metrics.sample`
`LogRecord`; short-lived tools snapshot at stage boundaries and attach deltas to the
already-specified `stage.end` and `run.summary` records.

- **Pros**: fits the logging philosophy exactly (JSON Lines authoritative, `jq`-able,
  no new consumers needed); zero new dependencies; one syscall per sample (~µs — at a
  30 s interval, unmeasurable); covers disk + energy + ANE footprint, which **no
  library option does**; per-component toggles fall out of per-record fields.
- **Cons**: ~200–300 lines of ours to maintain (the Darwin APIs involved are decades-
  stable); no dashboards out of the box — consumption is `jq`, `ears metrics`, or
  whatever is layered on later.

### B. `swift-metrics` façade + `swift-system-metrics` + a backend — optional later layer

Apple's [swift-metrics](https://github.com/apple/swift-metrics) is the standard Swift
metrics API; [swift-system-metrics 1.0](https://www.swift.org/blog/swift-system-metrics-1.0-released/)
(Feb 2026) now supports macOS 13+ and emits CPU-time, memory, fd, thread, and page-fault
gauges. Pair with [swift-prometheus](https://github.com/swift-server/swift-prometheus)
for a scrapeable endpoint and Grafana dashboards.

- **Pros**: maintained by Apple/SSWG; standard façade; instant dashboard ecosystem if a
  Prometheus/OTel pipeline is ever wanted.
- **Cons**: `swift-system-metrics` collects **no disk I/O, no energy, no wakeups, no
  ANE footprint** — the metrics this project cares most about would still need the
  Option-A sampler feeding the façade; a Prometheus scrape endpoint means the daemon
  grows an HTTP listener and the user runs a collector — heavy for a single-user local
  tool; it also drags in the server-side dependency stack (service-lifecycle et al.)
  where the project currently has three deps. It also cuts against "JSON Lines is
  authoritative": the same numbers would exist in two pipelines.
- **Verdict**: not now. If dashboards are wanted later, bootstrap the façade and let the
  Option-A sampler publish through it as a *second* sink — the two compose rather than
  compete.

### C. `os_signpost` + Instruments / `xctrace` — dev-time deep dives, adopt alongside A

Already promised by `docs/logging.md` ("wrap expensive stages in `os_signpost`
intervals") but unimplemented. Signposts cost ~nothing when no tool is recording, and
they are the **only** route to real ANE/GPU attribution (Instruments' Core ML / Neural
Engine / GPU instruments), allocation tracking, and File Activity tracing.
`xctrace record --template 'Time Profiler' --launch …` makes runs scriptable for
benchmark-as-CI later.

- **Pros**: idiomatic macOS answer; zero-maintenance (OS tooling); pairs with the
  existing `stage.start`/`stage.end` design — one call site emits both.
- **Cons**: not continuous monitoring; requires attaching a tool; binary trace output,
  not greppable — which is exactly why the JSON records remain authoritative.

### D. MetricKit — rejected

Wrong shape for this project: on macOS MetricKit's strength is **diagnostics** (crash,
hang, disk-write-exception reports, macOS 12+); its metric payloads are 24-hour
aggregates designed for App Store GUI apps, delivered at most daily via a per-user
agent. Useless for "watch what the daemon costs right now, per component", and most
payload types are sparse for background CLI processes. Not worth the integration.

### E. External `powermetrics` harness — ad-hoc benchmarking only

A script (e.g. `scripts/profile-session.sh`) that runs a workload while sampling
`sudo powermetrics --samplers tasks,gpu_power,ane_power` and/or `xctrace`. The only way
to see actual ANE/GPU **power**, and useful for before/after comparisons of a change.
Requires root, so it must never be a daemon dependency — keep it a dev tool.

## Recommendation

**A + C together, B deferred, E as a dev script.** A gives continuous, opt-in,
per-component numbers in the existing log pipeline; C gives the deep-dive story and the
only honest GPU/ANE attribution; together they cover monitoring *and* investigation
with zero new runtime dependencies.

## Sketch of the recommended design

### Configuration

A shared `profiling` schema slice (composed into each tool's schema the same way
`Phase0ConfigSchema` shares `[log]`), so every component gets an independent toggle:

```toml
[earsd.profiling]
enabled          = false   # master switch for the daemon
interval_seconds = 30      # metrics.sample cadence
per_source       = true    # per-source capture fields (drops, ring occupancy, chunk writes)
signposts        = false   # os_signpost mirror for Instruments

[transcribe.profiling]
enabled   = false          # stage deltas on stage.end / run.summary
signposts = false          # + ANE gate hold/queue instrumentation

[cleanup.profiling]
enabled = false            # subprocess wall time + child rusage deltas

[summarize.profiling]
enabled = false
```

Defaults keep everything off; `enabled = false` short-circuits to zero syscalls and
`OSSignposter.disabled`.

### Where it attaches

- **`earsd`** — a sampler task launched in `EarsDaemon.start()` (torn down in `stop()`)
  emits `metrics.sample` every `interval_seconds`: rusage deltas, footprint, energy,
  wakeups, thermal state, plus per-source fields (dropped samples, ring occupancy,
  bytes/chunks written this interval). Per-source health piggybacks on the existing 2 s
  watchdog tick; `ChunkEncoder.finalizeChunk` gains `duration_ms`/`bytes` fields on the
  existing `chunk.written` event. (Wiring note: `EarsdRuntime` currently holds only the
  string `os.Logger` closure — the structured `LogSink` must be plumbed into
  `EarsDaemon` for the sampler to emit records; the construction in
  `EarsCLISupport.bootstrapLoggingAndRun` is the template.)
- **`transcribe`** — snapshot at stage boundaries (model load, per-slice ASR,
  diarization, assembly); `stage.end` gains `cpu_ms`, `phys_footprint`,
  `disk_write_bytes`; `run.summary` gains totals + peak footprint + `rtf`.
  `ANEInferenceGate.run` records hold-duration and waiter depth (`ane_gate_ms`,
  `ane_gate_queue`), doubling as the ANE-contention metric, with an optional signpost
  interval.
- **`cleanup` / `summarize`** — the LLM runs out of process (`CommandLLMBackend`
  spawns `llm`), so profile the boundary: spawn-to-first-byte and total wall time,
  child CPU via `getrusage(RUSAGE_CHILDREN)` deltas, plus the token counts the logging
  spec already calls for.
- **`ears metrics`** — a `metrics` control-socket request returning the daemon's latest
  sample, mirroring `status` (new `ControlRequest` case + payload + one `ControlServer`
  arm); both socket transports inherit it automatically.

### Module placement

Snapshot/delta *math* (pure, `Codable`, testable): `EarsCore`. The syscall shim
(`proc_pid_rusage`, `mach_timebase_info`, thermal state) and the sampler actor: a new
small tier-2 target `EarsMetrics` depended on by `EarsDaemonKit` and the tool
runtimes — keeping `EarsCore` I/O-free per the engineering practices.

### Rollout

1. `ResourceSnapshot` + delta math in `EarsCore` (tier-0 tests), `EarsMetrics` shim.
2. Config slices + `earsd` sampler + `metrics.sample` records; `ears metrics` endpoint.
3. Stage deltas in `transcribe` (+ `ANEInferenceGate` instrumentation), then
   `cleanup`/`summarize` subprocess accounting.
4. Signpost mirrors behind the `signposts` toggles; `scripts/profile-session.sh`
   (`xctrace`/`powermetrics`) for deep dives.
