# Prompt: multi-source capture + sessions (Phase 4)

Use this prompt against the `all-ears` repo, `daemon/` Swift package. It's the next
`docs/roadmap.md` phase after Phase 3 (LLM stages, landed) — daemon Phases 0–3 are
done and Phase 6's browser-ingest half landed early (`16c4bbb`); this phase is
untouched. Confirmed by grep: no `CATap`/`AudioHardwareCreateProcessTap` code
anywhere in `daemon/Sources`, `PermissionProviding.systemAudio` still resolves to
`.notDetermined` (`MicrophonePermissionProvider.swift`'s doc comment says so
explicitly: "deferred to the later system-audio tap probe task"), and nothing
calls `SessionRegistry.open`/`.close` except `ears session open`/`close` — there
is no auto-trigger.

Two things this phase's roadmap bullet lists are **already done** — don't
re-implement them:

- **Session lifecycle over the socket.** `EarsDaemonKit/SessionRegistry.swift`
  fully implements `open`/`close`/`list`/`mark`, wired through `ControlServer`.
  This phase only adds the thing that *calls* `open`/`close` automatically.
- **Source-level (channel-of-origin) speaker attribution.** `transcribe/
  TranscriptAssembly.swift`'s `speakerLabel(for:)` already maps `mic` → `You`
  and every other source to its raw id. Nothing here needs to change it.

---

## Task

Land the two genuinely-missing pieces of Phase 4:

1. A **system/per-app audio capture backend** using Core Audio process taps
   (`CATap`), so `system` and `app:<bundle-id>` sources actually capture.
2. **App-signal auto-triggers**: watch for a configured app producing audio,
   open a session automatically, and run the pipeline on close.

Plus the TCC probing and pre-roll pieces both depend on.

## Context (read first)

- `docs/specs/capture-daemon.md` §"Audio capture (native APIs)" and
  §"Permissions and TCC probing" — the CATap recipe (`CATapDescription` →
  `AudioHardwareCreateProcessTap` → wrap in a **private auto-start aggregate
  device**, tap-only, no sub-device; read format from `kAudioTapPropertyFormat`,
  never assume it) and the TCC probe (no query API exists; probe by
  create-and-destroy, detect an all-zero PCM stream, actionable "System Audio
  Recording Only" messaging, poll `AXIsProcessTrusted`/`CGPreflight…`, never
  fake grant state with timers).
- `docs/architecture.md` §"Two buffers, kept distinct" and §"Concurrency &
  runtime model" — generation-counter-guarded teardown, the SPSC RAM ring as
  the realtime hand-off, `userInteractive` worker draining it. `MicCaptureBackend`
  (`daemon/Sources/EarsCaptureKit/MicCaptureBackend.swift`) is the reference
  implementation of this whole pattern for mic: `GenerationGate`,
  `HeartbeatMonitor` + `StallDetector` watchdog, `ExponentialBackoff` rebuild,
  debounced route-change recovery. The new system-audio backend should reuse
  `AudioSampleRing`/`GenerationGate`/`HeartbeatMonitor`/`StallDetector`/
  `ExponentialBackoff` from `EarsCaptureKit` rather than re-inventing them —
  only the engine-construction/tap-install internals differ from mic.
- `daemon/Sources/EarsCore/Protocols/CaptureBackend.swift` — the seam every
  backend implements (`source`, `start() -> AsyncStream<AudioBuffer>`,
  `stop()`). Its doc comment already flags "format negotiation (a
  system-audio tap's true format read from `kAudioTapPropertyFormat`)...
  remain genuinely deferred, to Phase 4" — this is that task.
- `daemon/Sources/EarsCore/Protocols/PermissionProviding.swift` +
  `EarsCaptureKit/MicrophonePermissionProvider.swift` — the permission seam.
  `.systemAudio` needs a real conformance now (the create-and-destroy probe),
  parallel to how `.microphone` is a real `AVCaptureDevice` query.
- `daemon/Sources/EarsCore/Models/SourceClass.swift` — `.system` and `.app`
  already exist as cases; only their capture backend is missing.
- `docs/configuration.md` §"Auto-triggers" — the `[triggers]`/`[[triggers.rule]]`
  config shape is already documented (`on = "app-audio-active"`, `apps = [...]`,
  `open_session`, `sources`, `on_close = ["transcribe", "cleanup", "summarize"]`).
  `EarsCore/Config/EarsdConfigSchema.swift` currently only has `"triggers"` in
  its `passthroughKeys` (unvalidated passthrough) — this phase gives it a real
  schema and reads it.
- `daemon/Sources/EarsDaemonKit/PowerObserver.swift` — the pattern to follow for
  the trigger watcher: an actor subscribing to `NSWorkspace.shared
  .notificationCenter` (there: sleep/wake; here: app launch/terminate), owned
  and started/stopped by `EarsDaemon` the same way `powerObserver` is.
- `daemon/Sources/EarsDaemonKit/SessionRegistry.swift` — `open(sources:slug:
  start:vocab:trigger:)` already accepts `trigger: TriggerKind = .manual`;
  `TriggerKind.appSignal` (`EarsCore/Models/TriggerKind.swift`) exists and is
  unused today. The auto-trigger calls `open(..., trigger: .appSignal)`.
- `daemon/Sources/EarsDataStore/AsrChunkRangeReader.swift` +
  `SegmentedAudioReader.swift` — the `(source, range) -> [AudioSlice]` reader
  landed in Phase 2/3 for `transcribe`. Session pre-roll ("prepend-on-open
  pre-roll from the ring", per the roadmap) is reading a lookback window from
  the *already-buffered* ring via this same reader, at `session.open` time —
  not a separate live pre-roll buffer.
- `docs/specs/transcribe.md`'s CLI section — what the trigger's `on_close`
  pipeline (`transcribe`, `cleanup`, `summarize`) actually invokes: separate
  binaries, run in sequence over the closed session's id
  (`transcribe --session <id> --diarize && cleanup ... && summarize ...`).

## Requirements

### 1. `SystemAudioCaptureBackend` (`system` + `app:<bundle-id>`)

- New `EarsCaptureKit` type conforming to `CaptureBackend`, built from a
  `CATapDescription` (global tap for `system`; process-inclusion list scoped
  to one bundle id's live PID(s) for `app:<bundle-id>`) wrapped in a
  private auto-start aggregate device.
- Read the tap's actual format from `kAudioTapPropertyFormat` on start —
  never assume 48 kHz/stereo.
- Reuse `MicCaptureBackend`'s realtime hand-off shape: allocation-free IO-proc
  → `AudioSampleRing` → drained by a `userInteractive` consumer task; a
  dropped-sample counter surfaced via `CaptureStatsReporting`; generation-
  guarded teardown on device/tap changes.
- **Per-app scoping is the least-proven path** (per the spec) — gate it behind
  integration tests that verify the tap's inclusion/exclusion semantics
  directly (does the tap actually exclude non-listed processes' audio, not
  just accept the config). The spec flags one surveyed tool's
  `processes = [own PID], isExclusive = true` as likely-wrong; don't copy that
  shape without verifying what it actually does on this OS version.
- Resolve `app:<bundle-id>` to its live PID(s) (`NSRunningApplication` /
  `NSWorkspace.runningApplications`), and **track process launch/exit**,
  rebuilding the tap's inclusion list as the target app's processes come and
  go — a bundle id can have zero, one, or several live PIDs over the source's
  lifetime.
- Stall watchdog is **non-negotiable even in-process** (spec: "if kept
  in-process, the stall watchdog is still required") — reuse
  `HeartbeatMonitor`/`StallDetector` exactly as `MicCaptureBackend` does. The
  optional `audiotee`-style external-process isolation (tap crash ≠ daemon
  crash) is explicitly a *later* hardening option per the spec, not required
  this phase — default in-process, but say so in a doc comment so it isn't
  silently assumed done.

### 2. TCC probing for the tap grant

- Extend `PermissionProviding.systemAudio` with a real conformance: create a
  throwaway tap, detect the all-zero-PCM signature of a TCC-denied tap, then
  destroy it. No query API exists for this grant — don't invent one.
- On denial, the source's `CaptureActor.start()` failure path (already
  isolates one source's startup failure from the daemon, per
  `EarsDaemon.start()`'s doc comment) must produce a **specific, actionable**
  log message naming macOS 15's "System Audio Recording Only" sub-pane —
  not a generic "permission denied".
- Poll real state (`AXIsProcessTrusted`, `CGPreflight…`) where applicable;
  never fake a grant with a timer.

### 3. App-signal auto-trigger

- New config: give `[triggers]`/`[[triggers.rule]]` a real `ConfigSchema`
  entry in `EarsdConfigSchema.swift` (currently just passthrough) — `enabled`,
  and per-rule `name`/`on`/`apps`/`open_session`/`sources`/`on_close`, per
  `docs/configuration.md`'s reference block.
- New `EarsDaemonKit` actor (parallel to `PowerObserver`) watching
  `NSWorkspace` app launch/terminate notifications for the configured `apps`
  list. `on = "app-audio-active"` means firing on genuine audio activity, not
  merely "the app process exists" (e.g. Zoom running in the background with no
  call active shouldn't open a session) — decide and document the concrete
  signal you use (e.g. correlating with the matching `app:<bundle-id>`
  source's own VAD/non-silence state once §1 makes that source real) rather
  than silently downgrading to launch-detection and calling it done.
- On fire: `SessionRegistry.open(sources: rule.sources, slug: ..., trigger:
  .appSignal)`. On the matched app's last process exiting:
  `SessionRegistry.close(id:)`, then spawn `on_close`'s pipeline
  (`transcribe`, `cleanup`, `summarize`) as subprocesses against the closed
  session's id, in order, logging each stage's exit status. A pipeline stage
  failing logs loud and stops the chain — it must never silently skip a later
  stage as if the run succeeded.
- Wire this actor into `EarsDaemon.start()`/`.stop()` exactly like
  `powerObserver`.

### 4. Pre-roll on session open

- `SessionRegistry.open` currently records `start` as given/`clock.now()` with
  no lookback. Add a configurable pre-roll: when opening (manual or
  app-signal), the session's *effective* readable range for `transcribe`
  should include N seconds before `start` already sitting in the ring, sourced
  via `AsrChunkRangeReader`/`SegmentedAudioReader` against each named source —
  not a separate live buffer. Decide (and document) whether this shifts the
  persisted `session.toml` `start` backward or is purely a `transcribe`-time
  concern layered on top of the session's nominal start; either is defensible,
  but pick one and say why in a doc comment, matching this codebase's existing
  practice of resolving ambiguity explicitly (`ActorContracts.swift`,
  `EarsDaemon.openIngestSource`'s doc comments) rather than leaving it
  implicit.

## Tests

- Tier 2 (behaviour-verified, not syscall-unit-tested) for the CATap shim:
  isolate it behind `CaptureBackend` and test the protocol with a mock;
  verify the real shim end-to-end against a real tap.
- Integration test proving per-app inclusion/exclusion actually isolates one
  app's audio from another's — not just that the config was accepted.
  Per-app scoping is the roadmap's explicit gate: "per-app capture isolates
  the meeting app from other system audio (integration-tested)".
- TCC probe: a fake all-zero-PCM tap response maps to `.denied`, not silently
  treated as "captured nothing yet".
- Trigger config: `EarsdConfigSchema` round-trips a `[[triggers.rule]]` block
  through validation (currently untyped passthrough — this is new coverage,
  not a regression check).
- Auto-trigger actor: given a fake app-launch/terminate event source (don't
  drive real `NSWorkspace` in tests — inject the same way `PowerObserver`
  should be checked for an injection seam, adding one if it doesn't have one),
  a matching launch opens a session with `trigger: .appSignal` and the
  configured sources; exit closes it and invokes the configured pipeline
  stages in order.
- Pre-roll: a session opened against a source with N seconds already in the
  ring reads that lookback via `AsrChunkRangeReader`, proven against a
  fixture ring buffer (tier 1, no daemon needed).

## Out of scope

- Diarization (Phase 5) — this phase's transcripts stay at channel-of-origin
  attribution only (`You` vs raw source id), already implemented.
- `transcribe --follow` / streaming (Phase 6) — the `on_close` pipeline here
  runs `transcribe` in **batch** mode only.
- The `audiotee`-style external-process tap isolation — document it as a
  deferred hardening option, don't build it.
- Diarization/summary-quality tuning of the trigger's `on_close` pipeline
  invocation — wiring three existing binaries together correctly is the bar,
  not improving what they produce.
