import Foundation
import Testing

@testable import EarsDataStore

/// Tier-2 per `docs/engineering-practices.md`: exercises the real
/// `AVAudioFile`-backed decoder directly against a real encoded fixture
/// (built with ``AVFoundationChunkFileWriter``, the same writer `earsd`
/// uses), proving decode-then-read round-trips for a sub-range -- closing
/// the "asr/ chunk files are a real codec, not raw PCM" gap
/// `docs/specs/capture-daemon.md` describes.
@Suite("AVFoundationChunkFileReader")
struct AVFoundationChunkFileReaderTests {
  private func makeTempURL(ext: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AVFoundationChunkFileReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("chunk.\(ext)")
  }

  /// A 440Hz tone at `sampleRate`, `seconds` long -- real audio content
  /// (rather than silence) so a broken decode (wrong offset, garbled
  /// samples) would show up as a real waveform mismatch, not just "any
  /// nonzero data came back".
  private func tone(seconds: Double, sampleRate: Int) -> [Float] {
    let count = Int(seconds * Double(sampleRate))
    return (0..<count).map { index in
      Float(sin(2.0 * Double.pi * 440.0 * Double(index) / Double(sampleRate)) * 0.5)
    }
  }

  private func writeFixture(samples: [Float], sampleRate: Int, url: URL) throws {
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: sampleRate, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)
    try writer.write(samples: samples)
    try writer.finish()
  }

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumSquares / Float(samples.count)).squareRoot()
  }

  @Test("reports the sample rate and approximate frame count the file was written with")
  func reportsSampleRateAndFrameCount() throws {
    let url = try makeTempURL(ext: "m4a")
    let samples = tone(seconds: 1, sampleRate: 16000)
    try writeFixture(samples: samples, sampleRate: 16000, url: url)

    let reader = try AVFoundationChunkFileReader(url: url)
    #expect(reader.sampleRate == 16000)
    // AAC's encoder priming/remainder can shift the exact frame count by a
    // small, codec-defined amount (e.g. AAC's ~2048-sample priming delay);
    // this asserts it's in the right ballpark rather than requiring exact
    // equality with the raw sample count fed in.
    #expect(abs(reader.frameCount - samples.count) < 4096)
  }

  @Test("reading the full range round-trips recognisable audio content")
  func readingFullRangeRoundTrips() throws {
    let url = try makeTempURL(ext: "m4a")
    let samples = tone(seconds: 1, sampleRate: 16000)
    try writeFixture(samples: samples, sampleRate: 16000, url: url)

    let reader = try AVFoundationChunkFileReader(url: url)
    let decoded = try reader.read(frames: 0..<reader.frameCount)

    #expect(!decoded.isEmpty)
    // Lossy AAC won't match bit-for-bit; the decoded signal's overall
    // energy (RMS) should still be close to the original tone's, proving
    // this is the same waveform and not silence/garbage.
    let originalRMS = rms(samples)
    let decodedRMS = rms(decoded)
    #expect(abs(originalRMS - decodedRMS) < 0.05)
  }

  @Test("reading a sub-range in the middle of the file returns the right slice")
  func readingSubRangeReturnsRightSlice() throws {
    let url = try makeTempURL(ext: "m4a")
    // Half a second of tone, then half a second of silence -- so a
    // sub-range decode error (wrong seek offset) shows up as picking the
    // wrong half's energy rather than requiring sample-exact comparison.
    let sampleRate = 16000
    let loud = tone(seconds: 0.5, sampleRate: sampleRate)
    let quiet = [Float](repeating: 0, count: sampleRate / 2)
    try writeFixture(samples: loud + quiet, sampleRate: sampleRate, url: url)

    let reader = try AVFoundationChunkFileReader(url: url)

    let firstHalf = try reader.read(frames: 0..<(sampleRate / 2))
    let secondHalf = try reader.read(frames: (sampleRate / 2)..<(sampleRate))

    #expect(rms(firstHalf) > 0.1)
    #expect(rms(secondHalf) < 0.05)
  }

  @Test("a requested range extending past the end of the file throws chunkRangeOutOfBounds")
  func rangePastEndOfFileThrows() throws {
    let url = try makeTempURL(ext: "m4a")
    let samples = tone(seconds: 0.1, sampleRate: 16000)
    try writeFixture(samples: samples, sampleRate: 16000, url: url)

    let reader = try AVFoundationChunkFileReader(url: url)
    let outOfBoundsRange = 0..<(reader.frameCount + 100_000)
    #expect(
      throws: DataStoreError.chunkRangeOutOfBounds(
        requested: outOfBoundsRange, available: reader.frameCount)
    ) {
      _ = try reader.read(frames: outOfBoundsRange)
    }
  }

  @Test("opus/caf fixtures decode too")
  func opusFixtureDecodes() throws {
    let url = try makeTempURL(ext: "caf")
    let sampleRate = 16000
    let samples = tone(seconds: 0.5, sampleRate: sampleRate)
    let settings = ChunkAudioSettings(codec: "opus", sampleRate: sampleRate, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)
    try writer.write(samples: samples)
    try writer.finish()

    let reader = try AVFoundationChunkFileReader(url: url)
    let decoded = try reader.read(frames: 0..<reader.frameCount)
    #expect(rms(decoded) > 0.1)
  }
}
