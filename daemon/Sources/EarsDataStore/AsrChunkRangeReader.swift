import EarsCore
import Foundation

/// Resolves a requested wall-clock ``TimeRange`` against a source's known
/// ``IndexedChunk``s (typically ``ReconstructedRange/chunks``, from
/// ``RangeReconstructor``) to the `asr/` chunk file(s) that cover it, and
/// stitches exactly that span's `Float32` samples out of them into one
/// ``AudioBuffer`` -- `docs/specs/transcribe.md`'s "resolve which
/// on-disk chunk file(s) in `asr/` cover that range" step, made concrete.
///
/// Handles a range spanning multiple chunk files (frames from each
/// overlapping chunk are read in order and concatenated) and a range
/// landing mid-chunk on either end (only the overlapping frames of that
/// chunk are read). Reads via ``ChunkFileReading`` (``AVFoundationChunkFileReader``
/// by default, decoding the real AAC/Opus `asr/` chunk files production
/// writes), so no chunk file is ever loaded in full.
public struct AsrChunkRangeReader: Sendable {
  /// One `asr/` chunk file that could not be opened or decoded during a range
  /// read. Surfaced (rather than thrown) so a single corrupt chunk — a
  /// Bluetooth-rate-switch-poisoned `.m4a` that `ExtAudioFileOpenURL` refuses,
  /// all-ears issue #26 — degrades only its own span of the range: the
  /// surrounding chunks still contribute their audio, instead of one unreadable
  /// file aborting the whole transcribe run. `file` is the chunk's on-disk
  /// basename; `error` is the underlying failure rendered for the log.
  public struct UnreadableChunk: Sendable, Equatable {
    public var file: String
    public var error: String

    public init(file: String, error: String) {
      self.file = file
      self.error = error
    }
  }

  /// The stitched samples for a requested range, plus any chunk files that had
  /// to be skipped because they wouldn't open/decode. ``unreadableChunks`` is
  /// empty on the healthy path; a non-empty list is what the caller logs
  /// per-chunk and what proves the read degraded gracefully rather than failing.
  public struct StitchedRangeAudio: Sendable {
    public var audio: AudioBuffer
    public var unreadableChunks: [UnreadableChunk]

    public init(audio: AudioBuffer, unreadableChunks: [UnreadableChunk]) {
      self.audio = audio
      self.unreadableChunks = unreadableChunks
    }
  }

  private let dataRoot: URL
  private let sourceID: SourceID
  private let asrSampleRate: Int
  private let readerFactory: ChunkFileReaderFactory

  public init(
    dataRoot: URL,
    sourceID: SourceID,
    asrSampleRate: Int,
    readerFactory: @escaping ChunkFileReaderFactory = AVFoundationChunkFileReader.make
  ) {
    self.dataRoot = dataRoot
    self.sourceID = sourceID
    self.asrSampleRate = asrSampleRate
    self.readerFactory = readerFactory
  }

  /// Reads `range`, stitched from every entry of `chunks` that overlaps it.
  /// `chunks` need not be pre-sorted or pre-filtered to the range -- this
  /// sorts by start and skips non-overlapping entries itself, same
  /// tolerance ``RangeReconstructor`` already gives its own inputs.
  ///
  /// A chunk file that won't open or decode is skipped, not thrown (see
  /// ``readReporting(_:chunks:)``); use that variant when the caller needs to
  /// know *which* chunks were skipped.
  public func read(_ range: TimeRange, chunks: [IndexedChunk]) throws -> AudioBuffer {
    try readReporting(range, chunks: chunks).audio
  }

  /// Like ``read(_:chunks:)`` but also reports every chunk file that had to be
  /// skipped because it wouldn't open or decode. A single unreadable chunk (a
  /// Bluetooth-rate-switch-poisoned `.m4a` that `ExtAudioFileOpenURL` refuses,
  /// all-ears issue #26) is caught per-chunk and recorded rather than aborting
  /// the whole read: the surrounding chunks still contribute their samples, so
  /// audio from before and after the corrupt span survives.
  public func readReporting(_ range: TimeRange, chunks: [IndexedChunk]) throws -> StitchedRangeAudio
  {
    var samples: [Float] = []
    var unreadable: [UnreadableChunk] = []
    for chunk in chunks.sorted(by: { $0.range.start < $1.range.start }) {
      guard let overlap = Self.clip(range, chunk.range) else { continue }

      let filename = URL(fileURLWithPath: chunk.file).lastPathComponent
      let fileURL = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: sourceID)
        .appendingPathComponent(filename)

      // Open + decode this one chunk defensively: an unreadable file is
      // recorded and skipped, never rethrown, so it degrades only its own span
      // instead of failing every other chunk in the range with it.
      do {
        let reader = try readerFactory(fileURL)

        let startFrame = frame(for: overlap.start, chunkStart: chunk.range.start)
        let endFrame = frame(for: overlap.end, chunkStart: chunk.range.start)
        // The chunk's actual on-disk frame count is authoritative over its
        // nominal wall-clock duration -- a partial-write chunk (encode
        // failure kept the partial file, per ChunkEncoder) can be shorter.
        let clampedEnd = min(endFrame, reader.frameCount)
        let clampedStart = min(startFrame, clampedEnd)
        guard clampedStart < clampedEnd else { continue }

        samples.append(contentsOf: try reader.read(frames: clampedStart..<clampedEnd))
      } catch {
        unreadable.append(UnreadableChunk(file: filename, error: String(describing: error)))
      }
    }
    return StitchedRangeAudio(
      audio: AudioBuffer(samples: samples, sampleRate: asrSampleRate),
      unreadableChunks: unreadable)
  }

  private func frame(for instant: Instant, chunkStart: Instant) -> Int {
    max(0, Int((instant.interval(since: chunkStart) * Double(asrSampleRate)).rounded()))
  }

  private static func clip(_ requested: TimeRange, _ chunkRange: TimeRange) -> TimeRange? {
    let start = max(requested.start, chunkRange.start)
    let end = min(requested.end, chunkRange.end)
    guard start < end else { return nil }
    return TimeRange(start: start, end: end)
  }
}
