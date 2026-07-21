import EarsCore
import Foundation

/// Accumulates a source's incoming native-rate ``AudioBuffer``s and rolls
/// them over into fixed-duration, dual-rate chunk files, per
/// `docs/data-formats.md`'s "Audio chunks" and "Dual-rate audio storage"
/// sections.
///
/// One `ChunkEncoder` per source: an `actor` because it owns in-progress
/// chunk state (`pendingBuffers`, the running duration, the current chunk's
/// start instant) that must only ever be mutated by one writer at a time --
/// `docs/architecture.md`'s "single writer per source" rule.
///
/// ## Chunk rollover
///
/// `append(_:)` accumulates buffers and their durations; once the
/// accumulated duration reaches the configured `chunkSeconds`, the whole
/// accumulated set is finalized as one chunk and a new one starts. A single
/// incoming buffer that alone exceeds `chunkSeconds` is *not* split further
/// -- real capture backends push small (tens-of-milliseconds) buffers, so
/// this never happens in practice; splitting one buffer mid-chunk would add
/// complexity for a case that can't occur.
///
/// Chunk start instants are **not** re-read from a clock at every rollover.
/// The first chunk's start is the `startInstant` given at construction
/// (the caller's `clock.now()` or a continuation point); every later
/// chunk's start is the previous chunk's `end` -- contiguous, per
/// ``TimeRange``'s documented half-open convention ("a chunk's `end` is the
/// next chunk's `start`"). This keeps rollover timing fully deterministic
/// from buffer durations alone, with no wall-clock read anywhere in this
/// type.
///
/// ## Dual-rate write and the index
///
/// Each finalized chunk writes up to two files sharing one filename (the
/// chunk start instant, per ``FilenameTimestampCodec``): the native-rate
/// copy under `chunks/` (skipped when `storeNative` is `false`) and the
/// ASR-rate copy under `asr/` (always written -- it's the ASR feed the
/// transcriber depends on). One `chunk` index event is appended per
/// finalized chunk, per `docs/data-formats.md`'s single-event-per-chunk
/// example; its `file` references the `chunks/` copy when `storeNative` is
/// `true`, and the `asr/` copy otherwise (the only feed that exists in that
/// mode).
///
/// ## Partial writes on encode failure
///
/// If either feed's underlying ``ChunkFileWriting`` throws partway through
/// a chunk's buffers, per `docs/specs/capture-daemon.md`'s "on an encode
/// failure, keep the partial chunk": the buffers written *before* the
/// failure are still promoted to the final chunk file (``AtomicFileIO``'s
/// job), the `chunk` index event reflects only that truncated coverage
/// (`frames`/`end` shrink to match), and ``finalizeChunk()`` still throws
/// ``DataStoreError/partialChunkWrite(nativeFailed:asrFailed:)`` afterwards
/// so the caller can log it -- the encoder itself never crashes, and is
/// immediately ready to accept the next chunk's buffers.
///
/// A caveat this simplification accepts: the buffer(s) that failed to
/// encode are dropped, not retried or carried into the next chunk, so the
/// wall-clock time they represented becomes unaccounted for in this
/// encoder's own timeline (the next chunk's start is the truncated `end`,
/// not where the failed buffer would have ended). Encode failures are rare
/// hardware/disk-pressure events, not a steady-state path, so this is an
/// acceptable Phase 1 simplification rather than plumbing a clock through
/// this type solely to re-anchor after one.
public actor ChunkEncoder {
  private let sourceID: SourceID
  private let dataRoot: URL
  private let nativeSampleRate: Int
  private let storeNative: Bool
  private let chunkSeconds: Double
  private let nativeSettings: ChunkAudioSettings
  private let asrSettings: ChunkAudioSettings
  private let resampler: ChunkResampler
  private let indexAppender: IndexAppender
  private let chunkFileWriterFactory: ChunkFileWriterFactory

  private var pendingBuffers: [AudioBuffer] = []
  private var accumulatedDuration: Double = 0
  private var chunkStart: Instant

  /// - Parameters:
  ///   - sourceID: The source these chunks belong to.
  ///   - dataRoot: The suite's data root (`docs/configuration.md`'s
  ///     `data_root`); chunk paths are derived via ``DataStoreLayout``.
  ///   - codec: `meta.toml`'s `codec` (`"aac"` or `"opus"`); see
  ///     ``ChunkAudioSettings``.
  ///   - bitrate: `meta.toml`'s `bitrate`.
  ///   - nativeSampleRate: The listenable `chunks/` feed's rate.
  ///   - asrSampleRate: The derived `asr/` feed's rate.
  ///   - storeNative: `meta.toml`'s `store_native`; `false` skips the
  ///     `chunks/` copy entirely (ASR-feed-only).
  ///   - chunkSeconds: `earsd`'s `chunk_seconds` (default 30).
  ///   - startInstant: The first chunk's start instant -- injected, never
  ///     read from a clock internally (see the type's "Chunk rollover"
  ///     doc above).
  ///   - indexAppender: The source's shared index writer.
  ///   - chunkFileWriterFactory: Defaults to the real `AVAudioFile`-backed
  ///     writer; tests inject a fake to exercise partial-write handling.
  public init(
    sourceID: SourceID,
    dataRoot: URL,
    codec: String,
    bitrate: Int,
    nativeSampleRate: Int,
    asrSampleRate: Int,
    storeNative: Bool,
    chunkSeconds: Double,
    startInstant: Instant,
    indexAppender: IndexAppender,
    chunkFileWriterFactory: @escaping ChunkFileWriterFactory = AVFoundationChunkFileWriter.make
  ) throws {
    guard
      let resampler = ChunkResampler(
        nativeSampleRate: nativeSampleRate, asrSampleRate: asrSampleRate)
    else {
      throw DataStoreError.invalidAudioFormat
    }
    self.sourceID = sourceID
    self.dataRoot = dataRoot
    self.nativeSampleRate = nativeSampleRate
    self.storeNative = storeNative
    self.chunkSeconds = chunkSeconds
    self.nativeSettings = ChunkAudioSettings(
      codec: codec, sampleRate: nativeSampleRate, bitrate: bitrate)
    self.asrSettings = ChunkAudioSettings(codec: codec, sampleRate: asrSampleRate, bitrate: bitrate)
    self.resampler = resampler
    self.indexAppender = indexAppender
    self.chunkFileWriterFactory = chunkFileWriterFactory
    self.chunkStart = startInstant
  }

  /// The current chunk's start instant -- exposed for tests/callers that
  /// need to confirm rollover contiguity; not otherwise part of the
  /// operational API.
  public var currentChunkStart: Instant {
    chunkStart
  }

  /// Re-anchors the next chunk's start to `instant`. Called by
  /// ``CaptureActor/resume()`` after a pause/gap so post-gap audio is stamped
  /// at real wall-clock time instead of continuing the sample-derived timeline
  /// from where it froze.
  ///
  /// This timeline is `startInstant + Σ(written chunk durations)` — it advances
  /// only as audio is encoded and never reads a clock (see the type doc). A
  /// pause therefore freezes it while wall-clock marches on, and without this
  /// re-anchor a pause of duration D leaves every later chunk stamped D behind
  /// wall clock, compounding across gaps. A daemon *restart* avoids the drift
  /// for free by constructing a fresh encoder with `startInstant: clock.now()`;
  /// pause/resume reuses the same encoder, so it must re-anchor explicitly.
  ///
  /// Only valid with no pending buffers — `chunkStart` is the start of the
  /// in-flight accumulation, so re-anchoring mid-chunk would mis-stamp audio
  /// already buffered. ``CaptureActor`` flushes the encoder in its pause
  /// teardown, so the pending set is empty by the time it resumes; a non-empty
  /// set (an unexpected caller) is left untouched rather than corrupting the
  /// in-flight chunk.
  public func reanchor(to instant: Instant) {
    guard pendingBuffers.isEmpty else { return }
    chunkStart = instant
  }

  /// Appends one incoming buffer, rolling over to a new chunk once the
  /// accumulated duration reaches `chunkSeconds`.
  ///
  /// - Throws: ``DataStoreError/sampleRateMismatch(expected:got:)`` if
  ///   `buffer.sampleRate` doesn't match the encoder's configured native
  ///   rate; ``DataStoreError/partialChunkWrite(nativeFailed:asrFailed:)``
  ///   if this append triggered a rollover and either feed's encode failed
  ///   partway through (see the type's "Partial writes" doc above).
  public func append(_ buffer: AudioBuffer) async throws {
    guard buffer.sampleRate == nativeSampleRate else {
      throw DataStoreError.sampleRateMismatch(expected: nativeSampleRate, got: buffer.sampleRate)
    }
    pendingBuffers.append(buffer)
    accumulatedDuration += buffer.duration
    if accumulatedDuration >= chunkSeconds {
      try await finalizeChunk()
    }
  }

  /// Finalizes whatever's currently pending as a (possibly short) chunk.
  /// A no-op if nothing has been appended since the last rollover. Used on
  /// graceful shutdown so no in-flight audio is left unwritten and
  /// unindexed.
  public func flush() async throws {
    try await finalizeChunk()
  }

  private func finalizeChunk() async throws {
    guard !pendingBuffers.isEmpty else { return }
    let buffers = pendingBuffers
    let start = chunkStart
    let filename = FilenameTimestampCodec.string(for: start) + "." + nativeSettings.fileExtension

    let nativeFinalURL =
      DataStoreLayout.chunksDirectory(dataRoot: dataRoot, sourceID: sourceID)
      .appendingPathComponent(filename)
    let asrFinalURL =
      DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: sourceID)
      .appendingPathComponent(filename)

    var nativeFrames = 0
    var nativeFailed = false
    if storeNative {
      do {
        try writeFeed(
          buffers: buffers, finalURL: nativeFinalURL, settings: nativeSettings, resample: false
        ) { nativeFrames += $0 }
      } catch {
        nativeFailed = true
      }
    }

    var asrFrames = 0
    var asrFailed = false
    do {
      try writeFeed(buffers: buffers, finalURL: asrFinalURL, settings: asrSettings, resample: true)
      {
        asrFrames += $0
      }
    } catch {
      asrFailed = true
    }

    let canonicalFrames = storeNative ? nativeFrames : asrFrames
    let writtenDuration = Double(canonicalFrames) / Double(nativeSampleRate)
    let end = start.advanced(by: writtenDuration)

    if canonicalFrames > 0 {
      let relativeFile =
        storeNative
        ? DataStoreLayout.relativeChunkPath(subdirectory: .chunks, filename: filename)
        : DataStoreLayout.relativeChunkPath(subdirectory: .asr, filename: filename)
      try await indexAppender.append(
        .chunk(start: start, end: end, file: relativeFile, frames: canonicalFrames))
    }

    pendingBuffers = []
    accumulatedDuration = 0
    chunkStart = end

    if nativeFailed || asrFailed {
      throw DataStoreError.partialChunkWrite(nativeFailed: nativeFailed, asrFailed: asrFailed)
    }
  }

  /// Writes one feed (native or ASR) for a chunk: creates a writer via
  /// ``chunkFileWriterFactory``, writes each buffer in order (resampling
  /// first when `resample` is `true`), and finalizes it -- all inside
  /// ``AtomicFileIO/writeAtomically(to:write:)`` so the result is an
  /// atomic temp+rename, with the partial file promoted (not discarded) if
  /// a write throws partway through. `onProgress` reports each
  /// successfully-written buffer's native-domain sample count, so the
  /// caller can determine exactly how much survived a partial failure.
  private func writeFeed(
    buffers: [AudioBuffer],
    finalURL: URL,
    settings: ChunkAudioSettings,
    resample: Bool,
    onProgress: (Int) -> Void
  ) throws {
    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      let writer = try chunkFileWriterFactory(tempURL, settings)
      do {
        for buffer in buffers {
          let outputSamples = resample ? try resampler.resample(buffer.samples) : buffer.samples
          try writer.write(samples: outputSamples)
          onProgress(buffer.samples.count)
        }
        try writer.finish()
      } catch {
        try? writer.finish()
        throw error
      }
    }
  }
}
