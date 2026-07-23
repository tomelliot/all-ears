import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Covers ``AsrChunkRangeReader``: resolving a requested wall-clock
/// ``TimeRange`` against a source's known ``IndexedChunk``s (as
/// ``RangeReconstructor`` would produce) to the `asr/` chunk file(s) that
/// cover it, and stitching exactly the requested span of `Float32` samples
/// out of them via ``ChunkFileReading`` -- correctly handling a range
/// within one chunk, a range spanning multiple chunks, and a range landing
/// on a partial-chunk boundary.
@Suite("AsrChunkRangeReader")
struct AsrChunkRangeReaderTests {
  private let sampleRate = 10  // 10Hz keeps sample counts small and readable.
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func range(_ start: Double, _ end: Double) -> TimeRange {
    TimeRange(start: base.advanced(by: start), end: base.advanced(by: end))
  }

  /// Writes a raw Float32 PCM fixture chunk under `<dataRoot>/sources/mic/asr/`
  /// whose N samples are `0, 1, 2, ..., N-1` (as floats) -- a distinguishing
  /// ramp so a stitched read can be checked sample-for-sample.
  private func writeAsrChunk(
    dataRoot: URL, filename: String, sampleCount: Int, startValue: Float = 0
  ) throws {
    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic")
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
    let samples = (0..<sampleCount).map { startValue + Float($0) }
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: asrDirectory.appendingPathComponent(filename))
  }

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsrChunkRangeReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Raw-PCM fixture chunks (written via `writeAsrChunk` above) need
  /// ``MmapPCMChunkFileReader`` explicitly: the default `readerFactory` is
  /// now ``AVFoundationChunkFileReader``, which decodes real AAC/Opus
  /// containers, not raw `Float32` files -- these tests want exact-sample
  /// assertions a lossy codec round-trip can't give, so they keep using the
  /// raw-PCM reader directly rather than the production default.
  private func makeReader(dataRoot: URL) -> AsrChunkRangeReader {
    AsrChunkRangeReader(
      dataRoot: dataRoot, sourceID: "mic", asrSampleRate: sampleRate,
      readerFactory: MmapPCMChunkFileReader.make)
  }

  @Test("a range fully inside a single chunk reads exactly that sub-range")
  func rangeWithinOneChunk() throws {
    let dataRoot = try makeDataRoot()
    // Chunk covers base+0..<base+3 (30 frames @ 10Hz).
    try writeAsrChunk(dataRoot: dataRoot, filename: "chunk1.pcm", sampleCount: 30)
    let chunks = [IndexedChunk(range: range(0, 3), file: "asr/chunk1.pcm", frames: 30)]

    let audio = try makeReader(dataRoot: dataRoot).read(range(1, 2), chunks: chunks)

    #expect(audio.sampleRate == sampleRate)
    // Frames 10..<20 of the ramp.
    #expect(audio.samples == (10..<20).map { Float($0) })
  }

  @Test("a range spanning two chunks stitches both in order")
  func rangeSpanningTwoChunks() throws {
    let dataRoot = try makeDataRoot()
    // chunk1: base+0..<base+2 (20 frames); chunk2: base+2..<base+4 (20 frames),
    // its ramp starting fresh at 0 so the stitch is provably ordered.
    try writeAsrChunk(dataRoot: dataRoot, filename: "chunk1.pcm", sampleCount: 20)
    try writeAsrChunk(dataRoot: dataRoot, filename: "chunk2.pcm", sampleCount: 20)
    let chunks = [
      IndexedChunk(range: range(0, 2), file: "asr/chunk1.pcm", frames: 20),
      IndexedChunk(range: range(2, 4), file: "asr/chunk2.pcm", frames: 20),
    ]

    // Request base+1..<base+3: last half of chunk1 (frames 10..<20) plus
    // first half of chunk2 (frames 0..<10).
    let audio = try makeReader(dataRoot: dataRoot).read(range(1, 3), chunks: chunks)

    #expect(audio.samples == (10..<20).map { Float($0) } + (0..<10).map { Float($0) })
  }

  @Test("a range landing mid-chunk on both ends reads only the overlapping frames")
  func partialChunkBoundaries() throws {
    let dataRoot = try makeDataRoot()
    try writeAsrChunk(dataRoot: dataRoot, filename: "chunk1.pcm", sampleCount: 50)
    let chunks = [IndexedChunk(range: range(0, 5), file: "asr/chunk1.pcm", frames: 50)]

    // 1.3s..<1.7s within a 0..<5s chunk @ 10Hz -> frames 13..<17.
    let audio = try makeReader(dataRoot: dataRoot).read(range(1.3, 1.7), chunks: chunks)

    #expect(audio.samples == (13..<17).map { Float($0) })
  }

  @Test("chunks that don't overlap the requested range are skipped")
  func nonOverlappingChunksSkipped() throws {
    let dataRoot = try makeDataRoot()
    try writeAsrChunk(dataRoot: dataRoot, filename: "before.pcm", sampleCount: 20)
    try writeAsrChunk(dataRoot: dataRoot, filename: "target.pcm", sampleCount: 20)
    try writeAsrChunk(dataRoot: dataRoot, filename: "after.pcm", sampleCount: 20)
    let chunks = [
      IndexedChunk(range: range(-2, 0), file: "asr/before.pcm", frames: 20),
      IndexedChunk(range: range(0, 2), file: "asr/target.pcm", frames: 20),
      IndexedChunk(range: range(2, 4), file: "asr/after.pcm", frames: 20),
    ]

    let audio = try makeReader(dataRoot: dataRoot).read(range(0, 2), chunks: chunks)

    #expect(audio.samples == (0..<20).map { Float($0) })
  }

  @Test("the chunk event's file basename is resolved against the asr/ directory, not chunks/")
  func resolvesAgainstAsrDirectory() throws {
    let dataRoot = try makeDataRoot()
    try writeAsrChunk(dataRoot: dataRoot, filename: "shared-name.pcm", sampleCount: 10)
    // The index event's recorded `file` points at chunks/ (the canonical
    // native-feed path per ChunkEncoder), but reads must come from asr/.
    let chunks = [IndexedChunk(range: range(0, 1), file: "chunks/shared-name.pcm", frames: 10)]

    let audio = try makeReader(dataRoot: dataRoot).read(range(0, 1), chunks: chunks)

    #expect(audio.samples == (0..<10).map { Float($0) })
  }

  @Test(
    "using the production default reader (AVFoundationChunkFileReader), a real encoded AAC chunk is decoded and stitched correctly"
  )
  func realEncodedChunkViaDefaultReaderFactory() throws {
    let dataRoot = try makeDataRoot()
    let asrDirectory = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic")
    try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)

    // A real AAC-encoded chunk, written exactly as `earsd` writes one --
    // proves the *default* readerFactory (no override) actually decodes
    // production-shaped `asr/` files, not just raw PCM fixtures.
    let asrSampleRate = 16000
    let loud = (0..<(asrSampleRate / 2)).map { index in
      Float(sin(2.0 * Double.pi * 440.0 * Double(index) / Double(asrSampleRate)) * 0.5)
    }
    let quiet = [Float](repeating: 0, count: asrSampleRate / 2)
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: asrSampleRate, bitrate: 64000)
    let url = asrDirectory.appendingPathComponent("real.m4a")
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)
    try writer.write(samples: loud + quiet)
    try writer.finish()

    let chunkRange = TimeRange(
      start: base, end: base.advanced(by: 1))
    let chunks = [IndexedChunk(range: chunkRange, file: "asr/real.m4a", frames: asrSampleRate)]

    // Default readerFactory: no override, so this exercises
    // `AVFoundationChunkFileReader.make` exactly as production wires it.
    let reader = AsrChunkRangeReader(dataRoot: dataRoot, sourceID: "mic", asrSampleRate: 16000)
    let firstHalf = try reader.read(
      TimeRange(start: base, end: base.advanced(by: 0.5)), chunks: chunks)
    let secondHalf = try reader.read(
      TimeRange(start: base.advanced(by: 0.5), end: base.advanced(by: 1)), chunks: chunks)

    #expect(firstHalf.sampleRate == 16000)
    #expect(rms(firstHalf.samples) > 0.1)
    #expect(rms(secondHalf.samples) < 0.05)
  }

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumSquares / Float(samples.count)).squareRoot()
  }

  // MARK: - Unreadable-chunk degradation (all-ears issue #26)

  /// Wraps ``MmapPCMChunkFileReader`` but throws for any file whose basename
  /// contains `poisonMarker` — modelling a chunk an `ExtAudioFileOpenURL` would
  /// refuse (a Bluetooth-rate-switch-poisoned m4a) without needing a real
  /// corrupt codec container.
  private func poisoningReaderFactory(poisonMarker: String) -> ChunkFileReaderFactory {
    { url in
      if url.lastPathComponent.contains(poisonMarker) {
        throw ChunkReadTestError.poisoned
      }
      return try MmapPCMChunkFileReader.make(url: url)
    }
  }

  @Test("an unreadable chunk is skipped and reported, and the surrounding audio still reads")
  func unreadableChunkDegradesToItsOwnSpan() throws {
    let dataRoot = try makeDataRoot()
    // Three abutting chunks; the middle one is poisoned. before/after ramps
    // start fresh at 0 so the stitch is provably ordered and gap-free-across
    // -the-hole.
    try writeAsrChunk(dataRoot: dataRoot, filename: "before.pcm", sampleCount: 20)
    try writeAsrChunk(dataRoot: dataRoot, filename: "poison-mid.pcm", sampleCount: 20)
    try writeAsrChunk(dataRoot: dataRoot, filename: "after.pcm", sampleCount: 20)
    let chunks = [
      IndexedChunk(range: range(0, 2), file: "asr/before.pcm", frames: 20),
      IndexedChunk(range: range(2, 4), file: "asr/poison-mid.pcm", frames: 20),
      IndexedChunk(range: range(4, 6), file: "asr/after.pcm", frames: 20),
    ]
    let reader = AsrChunkRangeReader(
      dataRoot: dataRoot, sourceID: "mic", asrSampleRate: sampleRate,
      readerFactory: poisoningReaderFactory(poisonMarker: "poison"))

    let result = try reader.readReporting(range(0, 6), chunks: chunks)

    // The poisoned chunk contributes nothing; before + after still stitch, in
    // order, with only the middle span missing.
    #expect(result.audio.samples == (0..<20).map { Float($0) } + (0..<20).map { Float($0) })
    let expected = [AsrChunkRangeReader.UnreadableChunk(file: "poison-mid.pcm", error: "poisoned")]
    #expect(result.unreadableChunks == expected)

    // The non-reporting entry point returns the same surviving audio and does
    // NOT throw — one corrupt chunk no longer aborts the whole read.
    let audio = try reader.read(range(0, 6), chunks: chunks)
    #expect(audio.samples == result.audio.samples)
  }

  @Test(
    "a chunk whose actual on-disk frame count is shorter than its nominal duration clamps rather than throwing"
  )
  func chunkShorterThanNominalDurationClamps() throws {
    let dataRoot = try makeDataRoot()
    // The chunk nominally covers 0..<2s (20 frames @ 10Hz) but an encode
    // failure left only 15 frames on disk (per ChunkEncoder's "keep partial
    // chunk on encode failure" behaviour) -- 1.5s worth, not 2s.
    try writeAsrChunk(dataRoot: dataRoot, filename: "short.pcm", sampleCount: 15)
    let chunks = [IndexedChunk(range: range(0, 2), file: "asr/short.pcm", frames: 20)]

    let audio = try makeReader(dataRoot: dataRoot).read(range(1, 2), chunks: chunks)

    #expect(audio.samples == (10..<15).map { Float($0) })
  }
}

private enum ChunkReadTestError: Error {
  case poisoned
}
