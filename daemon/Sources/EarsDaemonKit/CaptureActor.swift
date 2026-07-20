import EarsCaptureKit
import EarsCore
import EarsDataStore
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
/// spans, records `gap`/`evict` events through its ``IndexAppender``, and
/// enforces the source's per-source time cap. One instance per source, per
/// `docs/architecture.md`'s "Actor decomposition inside `earsd`". An `actor`:
/// all of this is real shared mutable per-source state that exactly one writer
/// may touch (the "single writer per source" rule).
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
/// ## Eviction seam (per-source now, cross-source later)
///
/// On each newly-indexed chunk, ``CaptureActor`` runs `EvictionExecutor.evict`
/// for **this source only** — deleting chunks aged past the source's
/// `time_cap_seconds` and appending `evict` events. Cross-source coordination
/// (`earsd`'s `hard_total_cap_bytes` backstop, which evicts oldest *across*
/// sources) stays a documented no-op seam: `EarsDataStore.HardTotalCapEnforcement`
/// is where Phase 4 adds real cross-source accounting, and it changes no call
/// site here. Phase 1 is mic-only, so there is exactly one source and nothing
/// to coordinate across.
public actor CaptureActor {
  /// This actor's source id — `nonisolated` so `ControlServer` can key its
  /// source→actor lookup without hopping onto the actor.
  public nonisolated let sourceID: SourceID

  private let descriptor: SourceDescriptor
  private let dataRoot: URL
  private let backend: any CaptureBackend
  private let encoder: ChunkEncoder
  private let indexAppender: IndexAppender
  private let vad: any VAD
  private let clock: any NowProviding
  private let eventSink: EventSink?

  /// Current runtime state, reported by ``status()``.
  private var runtimeState: SourceRuntimeState = .disabled
  /// When paused, the instant capture stopped — the `gap`'s `start`, closed on
  /// ``resume()``. `nil` whenever the source is not paused.
  private var pauseStartInstant: Instant?
  /// The chunks this source has indexed, tracked incrementally so the eviction
  /// pass doesn't re-parse `index.jsonl` on every rollover.
  private var knownChunks: [IndexedChunk] = []
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
  ///   - indexAppender: This source's shared `index.jsonl` writer.
  ///   - vad: The voice-activity index for this source.
  ///   - clock: Wall-clock seam; injected so tests never touch real time.
  ///   - eventSink: Where live-feed `vad` state-change events are published
  ///     (``EarsDaemon`` supplies its ``EventBus``'s `publish`); `nil` (the
  ///     default) publishes nothing — the on-disk index is unaffected either
  ///     way.
  public init(
    descriptor: SourceDescriptor,
    dataRoot: URL,
    backend: any CaptureBackend,
    encoder: ChunkEncoder,
    indexAppender: IndexAppender,
    vad: any VAD,
    clock: any NowProviding = SystemClock(),
    eventSink: EventSink? = nil
  ) {
    self.sourceID = descriptor.id
    self.descriptor = descriptor
    self.dataRoot = dataRoot
    self.backend = backend
    self.encoder = encoder
    self.indexAppender = indexAppender
    self.vad = vad
    self.clock = clock
    self.eventSink = eventSink
  }

  /// Begin continuous capture: append a startup `gap` for any downtime since
  /// the index's last known coverage (via `StartupGapAppender`), start the
  /// backend, and drain its stream — encoding chunks, running the VAD, and
  /// running the per-source eviction pass on each new chunk.
  ///
  /// - Precondition: not already capturing.
  /// - Postcondition: ``status()`` reports `.capturing`.
  /// - Throws: ``CaptureActorError/alreadyCapturing`` if already running; or
  ///   the backend's start error (a denied permission disables just this
  ///   source — `.error` state — rather than propagating fatally).
  public func start() async throws {
    guard runtimeState != .capturing else { throw CaptureActorError.alreadyCapturing }

    // Record any downtime since the index's last known coverage before the
    // first new chunk lands, so the gap is ordered ahead of resumed capture.
    _ = try? await StartupGapAppender.detectAndAppend(
      now: clock.now(), indexAppender: indexAppender)

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
      oldestChunkStart: knownChunks.map(\.range.start).min(),
      newestChunkEnd: knownChunks.map(\.range.end).max(),
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
  private func consume(_ buffer: AudioBuffer) async {
    let bufferStart = playhead

    if let spans = try? vad.detect(in: buffer) {
      for span in spans {
        try? await indexAppender.append(
          .vad(
            state: span.state,
            start: bufferStart.advanced(by: span.start),
            end: bufferStart.advanced(by: span.end)))
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
      // encode failure is logged-by-the-encoder and non-fatal to the loop.
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
  /// was finalized covering `[previousChunkStart, currentChunkStart)`. Track it
  /// (for `status` bounds and eviction) and run the per-source eviction pass.
  private func trackRollover(previousChunkStart: Instant) async {
    let currentStart = await encoder.currentChunkStart
    guard currentStart != previousChunkStart else { return }
    knownChunks.append(makeIndexedChunk(start: previousChunkStart, end: currentStart))
    await runEviction()
  }

  /// Rebuilds the ``IndexedChunk`` the encoder just wrote from the chunk's
  /// wall-clock bounds. Filename/extension/frames are derived exactly as the
  /// encoder derives them, so eviction targets the right on-disk files.
  private func makeIndexedChunk(start: Instant, end: Instant) -> IndexedChunk {
    let settings = ChunkAudioSettings(
      codec: descriptor.codec, sampleRate: descriptor.nativeSampleRate, bitrate: descriptor.bitrate)
    let filename = FilenameTimestampCodec.string(for: start) + "." + settings.fileExtension
    let subdirectory: ChunkSubdirectory = descriptor.storeNative ? .chunks : .asr
    let file = DataStoreLayout.relativeChunkPath(subdirectory: subdirectory, filename: filename)
    let frames = Int((end.interval(since: start) * Double(descriptor.nativeSampleRate)).rounded())
    return IndexedChunk(range: TimeRange(start: start, end: end), file: file, frames: frames)
  }

  /// Runs the per-source eviction pass over the tracked chunks and drops any it
  /// evicted from `knownChunks`. Eviction failure is non-fatal — the aged
  /// chunks simply remain until a later pass retries.
  private func runEviction() async {
    do {
      let evicted = try await EvictionExecutor.evict(
        chunks: knownChunks,
        now: clock.now(),
        timeCapSeconds: Double(descriptor.timeCapSeconds),
        sourceDirectory: DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: sourceID),
        indexAppender: indexAppender)
      guard !evicted.isEmpty else { return }
      let evictedSet = Set(evicted)
      knownChunks.removeAll { evictedSet.contains($0) }
    } catch {
      // Leave knownChunks intact; a later rollover retries the pass.
    }
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

  // MARK: - Test support

  /// Awaits the current consume loop's completion. The synthetic backend's
  /// stream is finite, so this returns once every scripted buffer is
  /// processed. Internal — a test seam, not part of the control surface.
  func drainForTesting() async {
    await consumerTask?.value
  }
}
