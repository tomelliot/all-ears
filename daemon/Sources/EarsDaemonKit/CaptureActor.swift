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
  /// buffer-derived timeline the encoder rolls chunks on — no wall-clock read
  /// per buffer.
  private var playhead: Instant = Instant(secondsSinceEpoch: 0)
  /// The coarse VAD state most recently published to ``eventSink``, so the
  /// live feed carries *transitions* only (the spec's `vad` event is a state
  /// change, not a per-buffer heartbeat). `nil` until the first speech is
  /// published — the silence baseline is never announced — and reset by
  /// ``teardownCapture()`` so the first speech after a resume/restart is
  /// re-announced rather than assumed continuous across the gap.
  private var lastPublishedVADState: VADState?

  /// - Parameters:
  ///   - descriptor: This source's `meta.toml` model — supplies `codec`,
  ///     `time_cap_seconds`, sample rates, and the id.
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

  /// Processes one buffer: append its `vad` spans on the buffer-derived
  /// timeline, feed it to the encoder, and — if that append rolled a chunk
  /// over — track the finalized chunk and run the per-source eviction pass.
  private func consume(_ raw: AudioBuffer) async {
    let buffer: AudioBuffer
    if let normalizer {
      if raw.sampleRate != lastInputRate {
        await logEvent(
          "capture.input_rate_changed", level: .notice,
          fields: [
            LogField("source", .string(sourceID.rawValue)),
            LogField("from", .int(lastInputRate ?? 0)),
            LogField("to", .int(raw.sampleRate)),
            LogField("target", .int(normalizer.targetSampleRate)),
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
