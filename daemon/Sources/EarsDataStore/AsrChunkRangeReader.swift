import EarsCore
import Foundation

/// Resolves a requested wall-clock ``TimeRange`` against a source's known
/// ``IndexedChunk``s (typically ``ReconstructedRange/chunks``, from
/// ``RangeReconstructor``) to the `asr/` chunk file(s) that cover it, and
/// stitches exactly that span's `Float32` samples out of them into one
/// ``AudioBuffer`` -- `docs/product/specs/transcribe.md`'s "resolve which
/// on-disk chunk file(s) in `asr/` cover that range" step, made concrete.
///
/// Handles a range spanning multiple chunk files (frames from each
/// overlapping chunk are read in order and concatenated) and a range
/// landing mid-chunk on either end (only the overlapping frames of that
/// chunk are read). Reads via ``ChunkFileReading`` (``AVFoundationChunkFileReader``
/// by default, decoding the real AAC/Opus `asr/` chunk files production
/// writes), so no chunk file is ever loaded in full.
public struct AsrChunkRangeReader: Sendable {
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
  public func read(_ range: TimeRange, chunks: [IndexedChunk]) throws -> AudioBuffer {
    var samples: [Float] = []
    for chunk in chunks.sorted(by: { $0.range.start < $1.range.start }) {
      guard let overlap = Self.clip(range, chunk.range) else { continue }

      let filename = URL(fileURLWithPath: chunk.file).lastPathComponent
      let fileURL = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: sourceID)
        .appendingPathComponent(filename)
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
    }
    return AudioBuffer(samples: samples, sampleRate: asrSampleRate)
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
