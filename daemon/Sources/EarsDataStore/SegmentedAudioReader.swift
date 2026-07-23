import EarsCore
import Foundation

/// The `(sourceID, timeRange) -> [AudioSlice]` entry point
/// `docs/specs/transcribe.md` describes: reads a source's
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
    try read(source: sourceID, range: requested).slices
  }

  /// The diagnosable outcome of reading one source over one range: the decoded
  /// ``slices`` a ``Transcriber`` consumes, plus the two counts that make an
  /// empty result explainable after the fact — how many `chunk` events overlap
  /// the range (audio on record at all) and how many of the range's VAD spans
  /// are speech (the silence-skipping input). Together they distinguish "no
  /// audio here", "audio but all silence", and "real speech" — the very
  /// question a `--meeting` run that yields `segments=0` needs answered per
  /// source (all-ears issue #20).
  public struct RangeAudioReport: Sendable, Equatable {
    public var slices: [AudioSlice]
    public var chunksInRange: Int
    public var speechIntervals: Int

    public init(slices: [AudioSlice], chunksInRange: Int, speechIntervals: Int) {
      self.slices = slices
      self.chunksInRange = chunksInRange
      self.speechIntervals = speechIntervals
    }
  }

  /// Like ``slices(source:range:)`` but also reports the chunk and speech-span
  /// counts behind the result, so a caller can log *why* a read came back empty
  /// (no chunks in range vs. chunks but no speech) rather than an
  /// indistinguishable empty array.
  public func read(source sourceID: SourceID, range requested: TimeRange) throws -> RangeAudioReport
  {
    let descriptor = try SourceMetaStore.read(sourceID: sourceID, dataRoot: dataRoot)
    let reconstructed = reconstruct(source: sourceID, range: requested)

    let windows = NaturalPauseSegmenter.segments(
      vadSpans: reconstructed.vadSpans, rangeDuration: requested.duration,
      options: segmentationOptions)
    let counts = rangeCounts(of: reconstructed)
    guard !windows.isEmpty else {
      return RangeAudioReport(
        slices: [], chunksInRange: counts.chunks, speechIntervals: counts.speech)
    }

    let chunkReader = AsrChunkRangeReader(
      dataRoot: dataRoot, sourceID: sourceID, asrSampleRate: descriptor.asrSampleRate,
      readerFactory: readerFactory)

    let slices = try windows.map { window -> AudioSlice in
      let absoluteRange = TimeRange(
        start: requested.start.advanced(by: window.start),
        end: requested.start.advanced(by: window.end))
      let audio = try chunkReader.read(absoluteRange, chunks: reconstructed.chunks)
      return AudioSlice(audio: audio, range: absoluteRange)
    }
    return RangeAudioReport(
      slices: slices, chunksInRange: counts.chunks, speechIntervals: counts.speech)
  }

  /// What ``probe(source:range:)`` reports: whether this source's directory
  /// exists in the reader's data root at all, and — if so — the same chunk /
  /// speech-span counts ``read(source:range:)`` would find, without loading
  /// `meta.toml` or decoding any audio. This is the cheap "is there anything
  /// here, and is it worth reading?" question the `--meeting` store selection
  /// asks of each candidate store before committing to decode one of them.
  public struct RangeProbe: Sendable, Equatable {
    public var sourceExists: Bool
    public var chunksInRange: Int
    public var speechIntervals: Int

    public init(sourceExists: Bool, chunksInRange: Int, speechIntervals: Int) {
      self.sourceExists = sourceExists
      self.chunksInRange = chunksInRange
      self.speechIntervals = speechIntervals
    }
  }

  /// Index-only probe: parses the structural + VAD indexes to count chunks and
  /// speech spans in `requested`, but never reads `meta.toml` or decodes audio.
  /// A missing source directory reports `sourceExists == false` with zero
  /// counts rather than throwing — a candidate store that simply doesn't hold
  /// this source is a normal, expected outcome the `--meeting` fallback keys
  /// off, not an error.
  public func probe(source sourceID: SourceID, range requested: TimeRange) -> RangeProbe {
    let sourceDirectory = DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: sourceID)
    guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
      return RangeProbe(sourceExists: false, chunksInRange: 0, speechIntervals: 0)
    }
    let counts = rangeCounts(of: reconstruct(source: sourceID, range: requested))
    return RangeProbe(
      sourceExists: true, chunksInRange: counts.chunks, speechIntervals: counts.speech)
  }

  /// The `URL` of the source directory this reader would read `sourceID` from —
  /// surfaced so a caller can log the concrete path it consulted.
  public func sourceDirectory(for sourceID: SourceID) -> URL {
    DataStoreLayout.sourceDirectory(dataRoot: dataRoot, sourceID: sourceID)
  }

  /// Structural events (chunk/gap) from `chunks.jsonl`, joined with only the
  /// VAD spans overlapping `requested`, reconstructed into the range's chunks
  /// and speech/silence spans. Shared by ``read`` and ``probe``; requires no
  /// `meta.toml` (that is a decode-time concern).
  private func reconstruct(source sourceID: SourceID, range requested: TimeRange)
    -> ReconstructedRange
  {
    let structuralURL = DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: sourceID)
    let structuralContents =
      (try? String(contentsOf: structuralURL, encoding: .utf8)) ?? ""
    let structuralEvents = IndexLog.parse(structuralContents).events
    let vadEvents = VADSegmentStore.events(
      directory: DataStoreLayout.vadDirectory(dataRoot: dataRoot, sourceID: sourceID),
      overlapping: requested)
    return RangeReconstructor.reconstruct(requested, events: structuralEvents + vadEvents)
  }

  private func rangeCounts(of reconstructed: ReconstructedRange) -> (chunks: Int, speech: Int) {
    (
      chunks: reconstructed.chunks.count,
      speech: reconstructed.vadSpans.filter { $0.state == .speech }.count
    )
  }
}
