import EarsCaptureKit
import EarsCore
import EarsDataStore
import EarsLogging
import Foundation

/// The domain (non-wire) snapshot of one source's capture state, returned by
/// ``CaptureActor/status()``. `ControlServer` converts this to the wire
/// `SourceStatus` at the socket boundary (see ``SourceStatus/init(_:)`` below),
/// mirroring the `SessionDescriptor` ↔ `SessionSummary` domain/wire split this
/// codebase already uses. Keeping the actor free of the wire `Codable`
/// (ISO-8601 / snake_case) concern is deliberate.
public struct CaptureSourceStatus: Sendable, Hashable {
  /// The source this snapshot describes.
  public var id: SourceID
  /// Current runtime state (`capturing`/`paused`/`disabled`/`error`).
  public var state: SourceRuntimeState
  /// The source's `meta.toml` `codec`, echoed for the `status` reply.
  public var codec: String
  /// Start of the oldest chunk still on disk, or `nil` if the buffer is empty.
  public var oldestChunkStart: Instant?
  /// End of the newest chunk written, or `nil` if the buffer is empty.
  public var newestChunkEnd: Instant?
  /// Bytes currently used by this source's on-disk buffer.
  public var bytesUsed: Int

  public init(
    id: SourceID,
    state: SourceRuntimeState,
    codec: String,
    oldestChunkStart: Instant? = nil,
    newestChunkEnd: Instant? = nil,
    bytesUsed: Int = 0
  ) {
    self.id = id
    self.state = state
    self.codec = codec
    self.oldestChunkStart = oldestChunkStart
    self.newestChunkEnd = newestChunkEnd
    self.bytesUsed = bytesUsed
  }
}

extension SourceStatus {
  /// The wire mapping of a domain ``CaptureSourceStatus`` — pure field copy,
  /// the domain→wire seam ``ControlServer`` uses to build `status` /
  /// `sources.list` replies (the same pattern as `SessionSummary.init(_:)`).
  public init(_ status: CaptureSourceStatus) {
    self.init(
      id: status.id,
      state: status.state,
      codec: status.codec,
      oldestChunkStart: status.oldestChunkStart,
      newestChunkEnd: status.newestChunkEnd,
      bytesUsed: status.bytesUsed
    )
  }
}

/// Errors surfaced by ``CaptureActor``'s lifecycle transitions. `ControlServer`
/// maps these to `ControlError` messages on the wire.
public enum CaptureActorError: Error, Sendable, Hashable {
  /// ``CaptureActor/start()`` called while already capturing.
  case alreadyCapturing
  /// ``CaptureActor/resume()`` called on a source that isn't paused.
  case notPaused
}

/// Owns the continuous capture of one source: drains its ``CaptureBackend``'s
/// buffer stream into a ``ChunkEncoder``, runs its ``VAD`` to append `vad`
/// spans, and records `gap` events through its ``IndexAppender``. One instance
/// per source, per `docs/architecture.md`'s "Actor decomposition inside
/// `earsd`". An `actor`: all of this is real shared mutable per-source state
/// that exactly one writer may touch (the "single writer per source" rule).
///
/// ## Dependencies (all injected, for testability)
///
/// The backend, encoder, index appender, and VAD are injected already-built so
/// tests can drive a `SyntheticCaptureBackend` + fake writers. The encoder is
/// anchored at its own construction instant (it never reads a clock; see
/// `ChunkEncoder`'s doc comment), so a caller that wants the first chunk's
/// `start` to line up with ``start()`` should construct the encoder immediately
/// before constructing this actor.
///
/// If the injected `backend` also conforms to `EarsCaptureKit.CaptureStatsReporting`,
/// ``status()`` surfaces its dropped-sample counter / failure latch (the
/// implementing task downcasts and reads `stats`); a plain `CaptureBackend`
/// reports capture health from index/disk state alone.
///
/// This actor never deletes audio. Retention is the daemon's
/// ``EvictionSweeper``'s job, and it operates on whole *meetings*: audio is
/// meeting-scoped (this actor's `dataRoot` is a meeting's directory), so an
/// ended meeting's audio is removed as one directory delete, long after this
/// actor was torn down.
public actor CaptureActor {
  /// This actor's source id — `nonisolated` so `ControlServer` can key its
  /// source→actor lookup without hopping onto the actor.
  public nonisolated let sourceID: SourceID

  private let descriptor: SourceDescriptor
  private let dataRoot: URL
  private let backend: any CaptureBackend
  private let encoder: ChunkEncoder
  private let indexAppender: IndexAppender
  private let vadWriter: VADSegmentWriter
  private let vad: any VAD
  private let clock: any NowProviding
  private let eventSink: EventSink?

  /// Normalizes every incoming buffer to the source's configured native rate
  /// before VAD/encode, so an input device switching sample rate mid-run
  /// (e.g. a 16 kHz Bluetooth headset replacing the 48 kHz built-in mic)
  /// resamples rather than being rejected by the encoder's strict
  /// single-rate contract. `nil` only if the descriptor's native rate is
  /// non-positive (a broken config), in which case buffers pass through
  /// unchanged and the encoder's `sampleRateMismatch` backstop still guards.
  private let normalizer: AdaptiveResampler?
  /// The one structured sink the capture path logs through — the same
  /// ``LogRecordSink`` the rest of the daemon uses, so drop/rate-change events
  /// land in the shared JSON-Lines + stderr + unified-logging stream (not a
  /// separate path) and stay assertable in tests via a recorder.
  private let logSink: any LogRecordSink

  /// The input rate of the most recently consumed buffer, for detecting a
  /// device rate change and emitting `capture.input_rate_changed` once per
  /// transition rather than per buffer.
  private var lastInputRate: Int?
  /// Count of buffers dropped because normalization threw, for rate-limiting
  /// the `capture.normalize_failed` error log (first + every 100th).
  private var normalizeFailureCount = 0
  /// Count of `encoder.append` failures, for rate-limiting the
  /// `capture.encode_failed` error log (first + every 100th).
  private var encodeFailureCount = 0

  /// Current runtime state, reported by ``status()``.
  private var runtimeState: SourceRuntimeState = .disabled
  /// When paused, the instant capture stopped — the `gap`'s `start`, closed on
  /// ``resume()``. `nil` whenever the source is not paused.
  private var pauseStartInstant: Instant?
  /// Bounds of the chunks this actor has finalized in this run, tracked on
  /// each rollover for ``status()``'s window fields. In-process only: an actor
  /// is built fresh per meeting, so there are no prior-run chunks to account
  /// for in the steady state (a restart-resumed meeting under-reports until
  /// its first new rollover — acceptable for a status display).
  private var oldestChunkStart: Instant?
  private var newestChunkEnd: Instant?
  /// The task draining `backend`'s stream into the encoder/VAD; `nil` while
  /// stopped or paused.
  private var consumerTask: Task<Void, Never>?
  /// Wall-clock start of the *next* buffer to arrive, advanced by each
  /// consumed buffer's duration. Anchored to the encoder's current chunk start
  /// whenever consumption (re)starts, so `vad` events land on the same
  /// buffer-derived timeline the encoder rolls chunks on. Each consumed buffer
  /// *checks* wall clock against this playhead (``reanchorAfterDeliveryGap``)
  /// so a stalled delivery can't silently freeze the timeline, but between
  /// gaps the timeline stays buffer-derived.
  private var playhead: Instant = Instant(secondsSinceEpoch: 0)
  /// The coarse VAD state most recently published to ``eventSink``, so the
  /// live feed carries *transitions* only (the spec's `vad` event is a state
  /// change, not a per-buffer heartbeat). `nil` until the first speech is
  /// published — the silence baseline is never announced — and reset by
  /// ``teardownCapture()`` so the first speech after a resume/restart is
  /// re-announced rather than assumed continuous across the gap.
  private var lastPublishedVADState: VADState?
  /// Periodic dry-spell check for push (browser) sources; `nil` for local
  /// backends and while stopped/paused. See ``startDryWatchdog()``.
  private var dryWatchdogTask: Task<Void, Never>?
  /// Latch so one dry episode logs once; cleared when delivery resumes.
  private var dryWarnedThisEpisode = false

  /// - Parameters:
  ///   - descriptor: This source's `meta.toml` model — supplies `codec`,
  ///     sample rates, and the id.
  ///   - dataRoot: The suite's data root; per-source paths derive from
  ///     `DataStoreLayout` + `descriptor.id`.
  ///   - backend: The capture seam for this source (real `MicCaptureBackend`,
  ///     or a `SyntheticCaptureBackend` in tests).
  ///   - encoder: This source's chunk writer (already anchored at its start
  ///     instant — see the type doc's dependency note).
  ///   - indexAppender: This source's structural `chunks.jsonl` writer
  ///     (chunk/gap/evict events).
  ///   - vadWriter: This source's segmented VAD-stream writer (`vad/`).
  ///   - vad: The voice-activity index for this source.
  ///   - clock: Wall-clock seam; injected so tests never touch real time.
  ///   - eventSink: Where live-feed `vad` state-change events are published
  ///     (``EarsDaemon`` supplies its ``EventBus``'s `publish`); `nil` (the
  ///     default) publishes nothing — the on-disk index is unaffected either
  ///     way.
  ///   - logSink: The structured sink the capture path writes its
  ///     drop/rate-change events to. Defaults to ``NoOpLogRecordSink`` so
  ///     existing call sites and tests that don't care compile unchanged.
  public init(
    descriptor: SourceDescriptor,
    dataRoot: URL,
    backend: any CaptureBackend,
    encoder: ChunkEncoder,
    indexAppender: IndexAppender,
    vadWriter: VADSegmentWriter,
    vad: any VAD,
    clock: any NowProviding = SystemClock(),
    eventSink: EventSink? = nil,
    logSink: any LogRecordSink = NoOpLogRecordSink()
  ) {
    self.sourceID = descriptor.id
    self.descriptor = descriptor
    self.dataRoot = dataRoot
    self.backend = backend
    self.encoder = encoder
    self.indexAppender = indexAppender
    self.vadWriter = vadWriter
    self.vad = vad
    self.clock = clock
    self.eventSink = eventSink
    self.logSink = logSink
    self.normalizer = AdaptiveResampler(targetSampleRate: descriptor.nativeSampleRate)
  }

  /// Begin continuous capture: start the backend and drain its stream —
  /// encoding chunks and running the VAD.
  ///
  /// - Precondition: not already capturing.
  /// - Postcondition: ``status()`` reports `.capturing`.
  /// - Throws: ``CaptureActorError/alreadyCapturing`` if already running; or
  ///   the backend's start error (a denied permission disables just this
  ///   source — `.error` state — rather than propagating fatally).
  public func start() async throws {
    guard runtimeState != .capturing else { throw CaptureActorError.alreadyCapturing }

    let stream: AsyncStream<AudioBuffer>
    do {
      stream = try await backend.start()
    } catch {
      await transition(to: .error)
      throw error
    }

    playhead = await encoder.currentChunkStart
    await transition(to: .capturing)
    startConsuming(stream)
    startDryWatchdog()
  }

  /// Stop continuous capture and tear the backend down (generation-counter
  /// teardown, so no stale realtime callback survives). Flushes the encoder's
  /// in-flight chunk first so no captured audio is left unindexed. Idempotent:
  /// a no-op when not capturing. Leaves ``status()`` reporting `.disabled`.
  public func stop() async {
    guard runtimeState == .capturing || runtimeState == .paused else { return }
    await teardownCapture()
    await transition(to: .disabled)
  }

  /// Pause capture, recording the resulting downtime as a `gap`.
  ///
  /// **Operational meaning (locked decision):** `CaptureBackend` exposes only
  /// `start()`/`stop()`, so pause **literally calls `backend.stop()`** — a full
  /// generation-counter teardown of the engine/tap — after flushing the
  /// in-flight chunk. It does *not* keep the engine running and merely drop
  /// buffers (that would burn the backend's realtime work for nothing). The
  /// pause-start instant (`clock.now()`) is remembered; the matching `gap` event
  /// is appended by ``resume()``, covering `[pauseStart, resumeTime)`. Cost of
  /// this decision: each pause/resume is a full teardown/rebuild cycle, which
  /// task 4a implements exactly as specified here.
  ///
  /// - Postcondition: ``status()`` reports `.paused`; the backend is stopped.
  /// - Note: If a session is open on this source, nothing special happens — the
  ///   gap simply lands in `index.jsonl` and the session's `end` is set
  ///   independently by `session.close` (see ``ActorContracts``).
  /// - Idempotent: a no-op when already paused.
  public func pause() async throws {
    guard runtimeState == .capturing else { return }
    pauseStartInstant = clock.now()
    await teardownCapture()
    await transition(to: .paused)
  }

  /// Resume capture after a ``pause()``: append the single `gap` event covering
  /// the paused interval `[pauseStart, now)`, then rebuild and restart the
  /// backend (fresh generation).
  ///
  /// - Precondition: currently paused.
  /// - Postcondition: ``status()`` reports `.capturing`; `pauseStart` cleared.
  /// - Throws: ``CaptureActorError/notPaused`` if not paused; or the backend's
  ///   restart error.
  public func resume() async throws {
    guard runtimeState == .paused else { throw CaptureActorError.notPaused }

    let resumeTime = clock.now()
    if let pauseStart = pauseStartInstant, pauseStart < resumeTime {
      try await indexAppender.append(
        .gap(start: pauseStart, end: resumeTime, reason: "pause"))
    }
    pauseStartInstant = nil

    // Re-anchor the encoder's sample-derived timeline to the resume instant so
    // audio captured after the gap is stamped at real wall-clock time, not
    // continued from where the timeline froze at pause. Without this, each
    // pause shifts every later chunk/vad timestamp behind wall clock by the
    // gap's full duration (a system sleep of hours is the pathological case),
    // and `transcribe --last Nm` — a wall-clock window — can't find the audio.
    // The teardown above flushed the encoder, so no in-flight chunk is
    // mis-stamped. `playhead` picks up the re-anchored start below.
    await encoder.reanchor(to: resumeTime)

    let stream: AsyncStream<AudioBuffer>
    do {
      stream = try await backend.start()
    } catch {
      await transition(to: .error)
      throw error
    }

    playhead = await encoder.currentChunkStart
    await transition(to: .capturing)
    startConsuming(stream)
    startDryWatchdog()
  }

  /// Finalize the current in-progress chunk and index it, then open a fresh
  /// chunk — the per-source half of the control socket's `flush` command (not a
  /// bare fsync of an unindexed partial). A no-op if nothing is pending.
  /// Delegates to `ChunkEncoder.flush()`.
  public func flush() async throws {
    let before = await encoder.currentChunkStart
    try await encoder.flush()
    await trackRollover(previousChunkStart: before)
  }

  /// A snapshot of this source's current capture state for `status` /
  /// `sources.list`.
  ///
  /// `async` (the stub declared it synchronous): surfacing backend health
  /// reads `CaptureStatsReporting.stats`, whose accessor is `get async`, so
  /// the body must be able to `await`. This is invisible to callers — every
  /// caller hops onto the actor with `await` regardless — but the declaration
  /// had to gain `async` to read the (async) stats accessor.
  ///
  /// When the backend conforms to `CaptureStatsReporting`, a latched
  /// unrecoverable failure (`stats.hasFailed`) is surfaced as the `.error`
  /// runtime state. The dropped-sample *count* has no home in
  /// ``CaptureSourceStatus`` yet — see the type's field set — so it is not
  /// surfaced in Phase 1 (flagged rather than force-fit into an unrelated
  /// field).
  public func status() async -> CaptureSourceStatus {
    var state = runtimeState
    if let reporting = backend as? any CaptureStatsReporting, await reporting.stats.hasFailed {
      state = .error
    }
    return CaptureSourceStatus(
      id: sourceID,
      state: state,
      codec: descriptor.codec,
      oldestChunkStart: oldestChunkStart,
      newestChunkEnd: newestChunkEnd,
      bytesUsed: bytesUsedOnDisk()
    )
  }

  // MARK: - Consume loop

  /// Launches the task that drains `stream` into the encoder/VAD. The task
  /// body inherits this actor's isolation, so each buffer is processed under
  /// the single-writer rule and the `for await` suspension between buffers is
  /// where `stop`/`pause`/`status`/`flush` interleave.
  /// Assigns ``runtimeState`` and publishes the change as a v2 `source`
  /// state event (revision-tagged by the bus). No-op when unchanged, so
  /// idempotent verbs don't spam subscribers.
  private func transition(to state: SourceRuntimeState) async {
    guard runtimeState != state else { return }
    runtimeState = state
    await eventSink?(.source(id: descriptor.id, state: state))
  }

  private func startConsuming(_ stream: AsyncStream<AudioBuffer>) {
    consumerTask = Task { [weak self] in
      for await buffer in stream {
        guard let self else { break }
        await self.consume(buffer)
      }
    }
  }

  /// How far wall clock may run ahead of the buffer-derived playhead (seconds)
  /// before ``reanchorAfterDeliveryGap`` re-anchors the timeline. Continuous
  /// backends (the mic's realtime tap) never approach it; a push source that
  /// only delivers while its speaker talks (Meet's per-speaker streams) trips
  /// it at every silence longer than this. Gaps under the threshold stay
  /// compressed, so it bounds the worst-case timestamp smear.
  static let deliveryGapThreshold: Double = 2.0

  /// Processes one buffer: append its `vad` spans on the buffer-derived
  /// timeline, feed it to the encoder, and — if that append rolled a chunk
  /// over — track the finalized chunk and run the per-source eviction pass.
  private func consume(_ raw: AudioBuffer) async {
    await reanchorAfterDeliveryGap(before: raw)
    let buffer: AudioBuffer
    if let normalizer {
      if raw.sampleRate != lastInputRate {
        // A device rate switch mid-recording (AirPods engaging HFP at 16 kHz
        // mid-call is the canonical case) is made an *explicit chunk boundary*:
        // finalize the chunk still accumulating at the old rate before the new
        // rate's audio starts, so every chunk file is single-rate end to end
        // and the AdaptiveResampler rebuilds its converter on the next
        // normalize(). Previously the transition was written silently into the
        // same chunk, producing an m4a `ExtAudioFileOpenURL` later refused to
        // open — poisoning a whole meeting's window (all-ears issue #26). The
        // action taken is logged (the old silent behaviour was the bug's hiding
        // place); the very first buffer only establishes the baseline rate and
        // has no prior chunk to finalize.
        var action = "baseline"
        if lastInputRate != nil {
          let before = await encoder.currentChunkStart
          try? await encoder.flush()
          await trackRollover(previousChunkStart: before)
          let after = await encoder.currentChunkStart
          if after != before {
            // Re-anchor the VAD playhead to the fresh chunk so post-flip spans
            // land on the encoder's timeline, exactly as a rollover does.
            playhead = after
            action = "chunk_finalized"
          } else {
            action = "converter_rebuilt"
          }
        }
        await logEvent(
          "capture.input_rate_changed", level: .notice,
          fields: [
            LogField("source", .string(sourceID.rawValue)),
            LogField("from", .int(lastInputRate ?? 0)),
            LogField("to", .int(raw.sampleRate)),
            LogField("target", .int(normalizer.targetSampleRate)),
            LogField("action", .string(action)),
          ])
        lastInputRate = raw.sampleRate
      }
      do {
        buffer = try normalizer.normalize(raw)
      } catch {
        normalizeFailureCount += 1
        if normalizeFailureCount == 1 || normalizeFailureCount % 100 == 0 {
          await logEvent(
            "capture.normalize_failed", level: .error,
            fields: [
              LogField("source", .string(sourceID.rawValue)),
              LogField("rate", .int(raw.sampleRate)),
              LogField("target", .int(normalizer.targetSampleRate)),
              LogField("error", .string(String(describing: error))),
              LogField("count", .int(normalizeFailureCount)),
            ])
        }
        // Drop the buffer and do NOT advance the playhead: keeping the
        // playhead ↔ encoder timeline consistent matters more than the lost
        // audio (the same accepted caveat as the encoder's partial writes).
        return
      }
    } else {
      buffer = raw
    }

    let bufferStart = playhead

    if let spans = try? vad.detect(in: buffer) {
      for span in spans {
        try? await vadWriter.append(
          state: span.state,
          start: bufferStart.advanced(by: span.start),
          end: bufferStart.advanced(by: span.end))
      }
      await publishVADTransition(spans: spans, bufferStart: bufferStart)
    }

    let chunkStartBefore = await encoder.currentChunkStart
    do {
      try await encoder.append(buffer)
    } catch {
      // A partial-chunk-write still finalizes (truncated) coverage and advances
      // the encoder's chunk start; a sample-rate mismatch leaves it untouched.
      // Either way the rollover check below reconciles our tracked state, so an
      // encode failure is non-fatal to the loop — but it must be visible, never
      // a silent drop, so it's logged (rate-limited: first + every 100th).
      encodeFailureCount += 1
      if encodeFailureCount == 1 || encodeFailureCount % 100 == 0 {
        await logEvent(
          "capture.encode_failed", level: .error,
          fields: [
            LogField("source", .string(sourceID.rawValue)),
            LogField("error", .string(String(describing: error))),
            LogField("count", .int(encodeFailureCount)),
          ])
      }
    }
    let chunkStartAfter = await encoder.currentChunkStart

    if chunkStartAfter != chunkStartBefore {
      await trackRollover(previousChunkStart: chunkStartBefore)
      // Re-anchor to the encoder's timeline so any truncation from a partial
      // write doesn't drift the VAD playhead.
      playhead = chunkStartAfter
    } else {
      playhead = bufferStart.advanced(by: buffer.duration)
    }
  }

  /// Detects a stalled delivery — wall clock more than
  /// ``deliveryGapThreshold`` ahead of the buffer-derived playhead — and
  /// re-syncs the timeline before `raw` is processed: the in-flight chunk is
  /// finalized (its audio arrived before the stall), the missing interval is
  /// recorded as a `gap`, and the encoder and playhead re-anchor to the
  /// arriving buffer's wall-clock start.
  ///
  /// The accumulated timeline (each chunk's `start` = the previous chunk's
  /// `end`) is correct only while audio arrives continuously. A push source
  /// delivers PCM over a socket that carries no timestamps and can go quiet at
  /// will — Meet's per-speaker streams send audio only while that speaker
  /// talks — so without this check every silence is squeezed out of the
  /// timeline and each later chunk is stamped further behind wall clock (a
  /// 30-minute call drifted ~13 minutes; all-ears issue: mis-interleaved
  /// meeting transcripts). The ingest close/reopen path is covered by the same
  /// check: `start()` resumes the frozen playhead and the first buffer of the
  /// new stream trips the threshold.
  private func reanchorAfterDeliveryGap(before raw: AudioBuffer) async {
    let now = clock.now()
    guard now.interval(since: playhead) > Self.deliveryGapThreshold else { return }
    // The buffer in hand was just delivered, so its audio began roughly one
    // buffer-duration before `now`; clamp so the timeline never runs backwards
    // if a single buffer is longer than the observed stall.
    let anchor = max(playhead, now.advanced(by: -raw.duration))
    let chunkStartBefore = await encoder.currentChunkStart
    try? await encoder.flush()
    await trackRollover(previousChunkStart: chunkStartBefore)
    let gapSeconds = anchor.interval(since: playhead)
    if gapSeconds > 0 {
      try? await indexAppender.append(
        .gap(start: playhead, end: anchor, reason: "delivery-stall"))
    }
    await encoder.reanchor(to: anchor)
    playhead = anchor
    await logEvent(
      "capture.delivery_gap", level: .notice,
      fields: [
        LogField("source", .string(sourceID.rawValue)),
        LogField("seconds", .double((gapSeconds * 1000).rounded() / 1000)),
      ])
  }

  /// How long a push (browser) source may deliver nothing before
  /// ``checkPushDrySpell()`` logs a breadcrumb, and how often it checks.
  ///
  /// Quiet is normal for a per-speaker stream — audio flows only while that
  /// speaker talks — so a dry spell alone is never treated as an error. But
  /// the 2026-07-24 Meet failure (browser/dev/captures/
  /// 2026-07-24-meet-collections-drift.md) delivered 4 seconds of remote audio
  /// and then went permanently dry with zero errors anywhere: the only daemon-
  /// visible symptom was `now - playhead` growing without bound, and nothing
  /// logged it. ``reanchorAfterDeliveryGap`` can't cover this case — it runs
  /// when the *next* buffer arrives, and in a permanent stall there is no next
  /// buffer. One notice per dry episode makes a dead delivery path visible in
  /// the log without paging anyone over a participant who just stopped talking.
  static let pushDryWarnSeconds: Double = 120
  static let pushDryCheckSeconds: Double = 30

  /// Arm the dry-spell watchdog for push sources. Local backends (mic, system,
  /// app) have their own realtime stall watchdog (`StallDetector` inside the
  /// backend) and are excluded — a quiet mic still delivers zero-filled
  /// buffers, so playhead lag genuinely means a wedged engine there, which the
  /// backend already handles by rebuilding.
  private func startDryWatchdog() {
    guard sourceID.sourceClass == .browser else { return }
    dryWatchdogTask?.cancel()
    dryWarnedThisEpisode = false
    dryWatchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(Self.pushDryCheckSeconds * 1_000_000_000))
        guard !Task.isCancelled, let self else { return }
        await self.checkPushDrySpell()
      }
    }
  }

  private func checkPushDrySpell() async {
    guard runtimeState == .capturing else { return }
    let drySeconds = clock.now().interval(since: playhead)
    if drySeconds < Self.pushDryWarnSeconds {
      dryWarnedThisEpisode = false
      return
    }
    guard !dryWarnedThisEpisode else { return }
    dryWarnedThisEpisode = true
    await logEvent(
      "capture.push_source_dry", level: .notice,
      fields: [
        LogField("source", .string(sourceID.rawValue)),
        LogField("seconds", .double(drySeconds.rounded())),
        LogField(
          "hint",
          .string(
            "no PCM delivered — speaker may simply be silent, or the extension's"
              + " audio path is down (Meet RTP migration, see"
              + " browser/dev/captures/2026-07-24-meet-collections-drift.md)")),
      ])
  }

  /// Publishes this buffer's coarse VAD state to ``eventSink`` iff it differs
  /// from the last published one — the live feed's `vad` event is a *state
  /// change* (`docs/specs/capture-daemon.md`'s
  /// `{"ev":"vad","source":"mic","state":"speech","t":...}`), not the
  /// per-span index record.
  ///
  /// Coarseness is buffer-granular, matching the spec's "coarse VAD state":
  /// a buffer containing any speech span is `speech` (stamped at the first
  /// speech span's start), a buffer with none is `silence` (stamped at the
  /// buffer's start). The `VAD` conformances only *emit* speech spans
  /// (``EnergyVAD`` never yields a silence span), so silence is derived from
  /// their absence rather than read off a span. The initial silence baseline
  /// is not announced — subscribers hear the first transition *into* speech,
  /// per ``lastPublishedVADState``'s doc.
  private func publishVADTransition(spans: [VADSpan], bufferStart: Instant) async {
    guard let eventSink else { return }
    let firstSpeechStart = spans.first { $0.state == .speech }?.start
    let state: VADState = firstSpeechStart == nil ? .silence : .speech
    guard state != lastPublishedVADState else { return }
    if state == .silence && lastPublishedVADState == nil { return }
    lastPublishedVADState = state
    await eventSink(
      .vad(source: sourceID, state: state, t: bufferStart.advanced(by: firstSpeechStart ?? 0)))
  }

  // MARK: - Teardown / rollover / eviction

  /// Stops the backend, drains the in-flight consume loop, and flushes the
  /// encoder's in-progress chunk so no captured audio is left unindexed. Used
  /// by both `stop` (full teardown) and `pause` (teardown, gap on resume).
  ///
  /// Order note: the stub's pause contract phrases this as "flush the in-flight
  /// chunk, *then* `backend.stop()`". This does the equivalent guarantee more
  /// safely by stopping the backend first, draining every already-queued
  /// buffer, and flushing last — so any buffers delivered between a flush and
  /// the teardown can't be silently dropped (they would be, under strict
  /// flush-then-stop). No audio is left unindexed either way.
  private func teardownCapture() async {
    dryWatchdogTask?.cancel()
    dryWatchdogTask = nil
    dryWarnedThisEpisode = false
    await backend.stop()
    await consumerTask?.value
    consumerTask = nil
    // Forget the published VAD state across the stop/pause gap, so the first
    // speech after a resume/restart is re-announced to live subscribers.
    lastPublishedVADState = nil

    let before = await encoder.currentChunkStart
    try? await encoder.flush()
    await trackRollover(previousChunkStart: before)
  }

  /// If the encoder's chunk start advanced past `previousChunkStart`, a chunk
  /// was finalized covering `[previousChunkStart, currentChunkStart)`. Track
  /// its bounds so `status`'s window fields stay fresh.
  private func trackRollover(previousChunkStart: Instant) async {
    let currentStart = await encoder.currentChunkStart
    guard currentStart != previousChunkStart else { return }
    if oldestChunkStart == nil {
      oldestChunkStart = previousChunkStart
    }
    newestChunkEnd = currentStart
  }

  /// Sum of this source's on-disk `chunks/` and `asr/` file sizes — the
  /// buffer's current footprint for `status`'s `bytesUsed`.
  private func bytesUsedOnDisk() -> Int {
    let directories = [
      DataStoreLayout.chunksDirectory(dataRoot: dataRoot, sourceID: sourceID),
      DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: sourceID),
    ]
    var total = 0
    for directory in directories {
      guard
        let entries = try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.fileSizeKey])
      else { continue }
      for url in entries {
        total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      }
    }
    return total
  }

  // MARK: - Logging

  /// Builds and forwards one structured ``LogRecord`` to the shared
  /// ``LogRecordSink``, stamping it with the actor's clock and the capture
  /// subsystem/category. Keeps the capture-path call sites to a single
  /// `event` + `fields` line. `try?` because a log-write failure must never
  /// take down the capture loop; only ever called on exceptional events (a
  /// rate change or a drop), never per buffer in the steady state.
  private func logEvent(_ event: String, level: LogLevel, fields: [LogField]) async {
    try? await logSink.log(
      LogRecord(
        ts: clock.now(),
        level: level,
        tool: "earsd",
        subsystem: "net.tomelliot.ears",
        category: "earsd.capture",
        pid: ProcessInfo.processInfo.processIdentifier,
        event: event,
        fields: fields))
  }

  // MARK: - Test support

  /// Awaits the current consume loop's completion. The synthetic backend's
  /// stream is finite, so this returns once every scripted buffer is
  /// processed. Internal — a test seam, not part of the control surface.
  func drainForTesting() async {
    await consumerTask?.value
  }
}
