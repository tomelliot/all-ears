import EarsCore
import Foundation

/// The `(sourceID, timeRange) -> [AudioSlice]` entry point
/// `docs/product/specs/transcribe.md` describes: reads a source's
/// `index.jsonl`, reconstructs the requested range's chunks/VAD spans
/// (``RangeReconstructor``), segments at natural pauses while skipping pure
/// silence (``NaturalPauseSegmenter``), and reads each resulting window's
/// audio off disk (``AsrChunkRangeReader``) -- ready for a ``Transcriber``.
///
/// This is the composition root the future `transcribe` CLI wires into;
/// nothing here runs a model or decides *when* to transcribe, matching
/// `docs/specs/capture-daemon.md`'s "does not decide when to transcribe"
/// non-responsibility (that's the caller's job, one layer up).
public struct SegmentedAudioReader: Sendable {
  private let dataRoot: URL
  private let segmentationOptions: SegmentationOptions
  private let readerFactory: ChunkFileReaderFactory

  public init(
    dataRoot: URL,
    segmentationOptions: SegmentationOptions = SegmentationOptions(),
    readerFactory: @escaping ChunkFileReaderFactory = AVFoundationChunkFileReader.make
  ) {
    self.dataRoot = dataRoot
    self.segmentationOptions = segmentationOptions
    self.readerFactory = readerFactory
  }

  /// - Parameters:
  ///   - sourceID: The source to read (resolves its `meta.toml` for the ASR
  ///     sample rate, and its `index.jsonl`/`asr/` chunk files).
  ///   - requested: The wall-clock range to segment and read.
  /// - Returns: One ``AudioSlice`` per natural-pause segment window, in
  ///   time order; empty if the range has no VAD-flagged speech on record
  ///   at all (silence-skipping) or no index/chunks exist yet.
  /// - Throws: Whatever ``SourceMetaStore/read(sourceID:dataRoot:)`` or the
  ///   underlying chunk reads throw (missing source, unreadable chunk file).
  public func slices(source sourceID: SourceID, range requested: TimeRange) throws -> [AudioSlice] {
    let descriptor = try SourceMetaStore.read(sourceID: sourceID, dataRoot: dataRoot)

    let indexURL = DataStoreLayout.indexFile(dataRoot: dataRoot, sourceID: sourceID)
    let indexContents =
      FileManager.default.fileExists(atPath: indexURL.path)
      ? try String(contentsOf: indexURL, encoding: .utf8) : ""
    let parsed = IndexLog.parse(indexContents)
    let reconstructed = RangeReconstructor.reconstruct(requested, events: parsed.events)

    let windows = NaturalPauseSegmenter.segments(
      vadSpans: reconstructed.vadSpans, rangeDuration: requested.duration,
      options: segmentationOptions)
    guard !windows.isEmpty else { return [] }

    let chunkReader = AsrChunkRangeReader(
      dataRoot: dataRoot, sourceID: sourceID, asrSampleRate: descriptor.asrSampleRate,
      readerFactory: readerFactory)

    return try windows.map { window in
      let absoluteRange = TimeRange(
        start: requested.start.advanced(by: window.start),
        end: requested.start.advanced(by: window.end))
      let audio = try chunkReader.read(absoluteRange, chunks: reconstructed.chunks)
      return AudioSlice(audio: audio, range: absoluteRange)
    }
  }
}
