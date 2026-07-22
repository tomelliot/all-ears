import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Covers ``SegmentedAudioReader``: the `(sourceID, timeRange) -> [AudioSlice]`
/// wiring a future `transcribe` reads through -- index parsing +
/// `RangeReconstructor` + `NaturalPauseSegmenter` + `AsrChunkRangeReader`,
/// composed end to end against a fixture source directory on disk. Per
/// `docs/engineering-practices.md`'s tier-1 rule ("given these chunks +
/// index, `transcribe` produces this transcript"), this is fixture-driven:
/// a real `sources/mic/` directory (`meta.toml`, `asr/*.pcm`, `index.jsonl`)
/// built once per test and read back through real file I/O.
@Suite("SegmentedAudioReader")
struct SegmentedAudioReaderTests {
  private let sampleRate = 10  // 10Hz keeps sample counts small and readable.
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func instant(_ offset: Double) -> Instant { base.advanced(by: offset) }
  private func range(_ start: Double, _ end: Double) -> TimeRange {
    TimeRange(start: instant(start), end: instant(end))
  }

  /// A `sources/mic/` fixture: `meta.toml` (via `SourceMetaStore`, so
  /// `asrSampleRate` round-trips exactly like production), one or more raw
  /// Float32 PCM chunk files under `asr/` (each a `0, 1, 2, ...` ramp so a
  /// stitched read is checked sample-for-sample), and `index.jsonl` built
  /// from real `IndexEvent`s via `IndexAppender`.
  private struct Fixture {
    let dataRoot: URL
  }

  private func makeFixture(
    chunks: [(filename: String, start: Double, end: Double, sampleCount: Int)],
    vadSpans: [(state: VADState, start: Double, end: Double)]
  ) async throws -> Fixture {
    let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SegmentedAudioReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    try SourceMetaStore.write(
      SourceDescriptor(
        schema: 1, id: "mic", sourceClass: .mic, label: "Mic",
        nativeSampleRate: sampleRate, asrSampleRate: sampleRate, storeNative: true, channels: 1,
        codec: "aac", bitrate: 64000, timeCapSeconds: 7200, created: instant(-7200)),
      dataRoot: dataRoot)

    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic")
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)

    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: "mic"))
    for chunk in chunks {
      let samples = (0..<chunk.sampleCount).map { Float($0) }
      let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
      try data.write(to: asrDirectory.appendingPathComponent(chunk.filename))
      try await indexAppender.append(
        .chunk(
          start: instant(chunk.start), end: instant(chunk.end),
          file: "asr/\(chunk.filename)", frames: chunk.sampleCount))
    }
    let vadWriter = VADSegmentWriter(
      directory: DataStoreLayout.vadDirectory(dataRoot: dataRoot, sourceID: "mic"))
    for span in vadSpans {
      try await vadWriter.append(
        state: span.state, start: instant(span.start), end: instant(span.end))
    }

    return Fixture(dataRoot: dataRoot)
  }

  /// This fixture writes raw `Float32` ramp samples directly under `asr/`
  /// (not real encoded audio), so it needs ``MmapPCMChunkFileReader``
  /// explicitly: the default `readerFactory` is now
  /// ``AVFoundationChunkFileReader``, which decodes real AAC/Opus
  /// containers. These tests care about index/segmentation/stitching logic
  /// with exact-sample assertions, not codec decoding, so they keep the
  /// raw-PCM reader.
  private func makeReader(dataRoot: URL) -> SegmentedAudioReader {
    SegmentedAudioReader(
      dataRoot: dataRoot,
      segmentationOptions: SegmentationOptions(maxPauseSeconds: 1.5, preRollSeconds: 0.3),
      readerFactory: MmapPCMChunkFileReader.make)
  }

  @Test("a range within one chunk, with a single speech span, produces one slice")
  func rangeWithinOneChunk() async throws {
    let fixture = try await makeFixture(
      chunks: [("chunk1.pcm", 0, 3, 30)],
      vadSpans: [(.speech, 1, 2)])

    let slices = try makeReader(dataRoot: fixture.dataRoot).slices(
      source: "mic", range: range(0, 3))

    #expect(slices.count == 1)
    let slice = slices[0]
    #expect(slice.audio.sampleRate == sampleRate)
    // Pre-roll 0.3s -> frame 7 through frame 20 (2s).
    #expect(slice.audio.samples == (7..<20).map { Float($0) })
    #expect(slice.range == range(0.7, 2))
  }

  @Test("a request spanning two chunks with one continuous speech span stitches both chunks")
  func rangeSpanningTwoChunks() async throws {
    let fixture = try await makeFixture(
      chunks: [
        ("chunk1.pcm", 0, 2, 20),
        ("chunk2.pcm", 2, 4, 20),
      ],
      vadSpans: [(.speech, 0.5, 3.5)])

    let slices = try makeReader(dataRoot: fixture.dataRoot).slices(
      source: "mic", range: range(0, 4))

    #expect(slices.count == 1)
    // Pre-roll clamps the start to 0.2s -> frame 2 of chunk1 through the
    // end of the speech span at 3.5s -> frame 15 of chunk2.
    #expect(slices[0].audio.samples == (2..<20).map { Float($0) } + (0..<15).map { Float($0) })
  }

  @Test("a stretch with only silence (no VAD speech) produces no slices -- silence-skipping")
  func silenceOnlyProducesNoSlices() async throws {
    let fixture = try await makeFixture(
      chunks: [("chunk1.pcm", 0, 3, 30)],
      vadSpans: [(.silence, 0, 3)])

    let slices = try makeReader(dataRoot: fixture.dataRoot).slices(
      source: "mic", range: range(0, 3))

    #expect(slices.isEmpty)
  }

  @Test("two speech spans separated by a long pause split into two separate slices")
  func naturalPauseSplitsIntoTwoSlices() async throws {
    let fixture = try await makeFixture(
      chunks: [("chunk1.pcm", 0, 10, 100)],
      vadSpans: [(.speech, 1, 3), (.speech, 6, 8)])  // 3s gap, over the 1.5s threshold

    let slices = try makeReader(dataRoot: fixture.dataRoot).slices(
      source: "mic", range: range(0, 10))

    #expect(slices.count == 2)
    // First: pre-roll 0.7..<3 -> frames 7..<30.
    #expect(slices[0].audio.samples == (7..<30).map { Float($0) })
    #expect(slices[0].range == range(0.7, 3))
    // Second: pre-roll 5.7..<8 -> frames 57..<80.
    #expect(slices[1].audio.samples == (57..<80).map { Float($0) })
    #expect(slices[1].range == range(5.7, 8))
  }

  @Test("a range with no chunks or VAD spans on record at all produces no slices")
  func emptyIndexProducesNoSlices() async throws {
    let fixture = try await makeFixture(chunks: [], vadSpans: [])

    let slices = try makeReader(dataRoot: fixture.dataRoot).slices(
      source: "mic", range: range(0, 10))

    #expect(slices.isEmpty)
  }
}
