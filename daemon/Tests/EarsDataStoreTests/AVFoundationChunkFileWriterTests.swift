import Foundation
import Testing

@testable import EarsDataStore

/// Tier-2 per `docs/engineering-practices.md`: exercises the real
/// `AVAudioFile`-backed writer directly (this is the thin shim itself).
@Suite("AVFoundationChunkFileWriter")
struct AVFoundationChunkFileWriterTests {
  private func makeTempURL(ext: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AVFoundationChunkFileWriterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("chunk.\(ext)")
  }

  @Test("writing samples then finishing produces a non-empty file")
  func writeThenFinishProducesFile() throws {
    let url = try makeTempURL(ext: "m4a")
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 48000, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)

    try writer.write(samples: [Float](repeating: 0.1, count: 48000))
    try writer.finish()

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = attributes[.size] as? Int ?? 0
    #expect(size > 0)
  }

  @Test("writing after finish throws writerClosed")
  func writeAfterFinishThrows() throws {
    let url = try makeTempURL(ext: "m4a")
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 48000, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)

    try writer.write(samples: [Float](repeating: 0.1, count: 4800))
    try writer.finish()

    #expect(throws: DataStoreError.writerClosed) {
      try writer.write(samples: [Float](repeating: 0.1, count: 100))
    }
  }

  @Test("writing an empty sample array is a no-op, not a failure")
  func writeEmptyIsNoOp() throws {
    let url = try makeTempURL(ext: "m4a")
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 48000, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)
    try writer.write(samples: [])
    try writer.finish()
  }

  // Regression test: the documented default bitrate (64000, valid at the
  // native 48kHz rate) throws when applied at the derived 16kHz ASR rate --
  // AudioConverterSetProperty(kAudioConverterEncodeBitRate) rejects a
  // bitrate too high for the sample rate. ChunkAudioSettings clamps for
  // exactly this; this test writes a real 16kHz file with the documented
  // default bitrate end to end to prove the clamp actually prevents the
  // failure, not just that the clamped number looks right in isolation.
  @Test("writing a 16kHz feed with the documented default bitrate (64000) succeeds")
  func writes16kHzWithDocumentedDefaultBitrate() throws {
    let url = try makeTempURL(ext: "m4a")
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 16000, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)

    try writer.write(samples: [Float](repeating: 0.1, count: 16000))
    try writer.finish()

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = attributes[.size] as? Int ?? 0
    #expect(size > 0)
  }

  @Test("opus/caf settings also produce a writable file")
  func opusWrites() throws {
    let url = try makeTempURL(ext: "caf")
    let settings = ChunkAudioSettings(codec: "opus", sampleRate: 48000, bitrate: 64000)
    let writer = try AVFoundationChunkFileWriter(url: url, settings: settings)

    try writer.write(samples: [Float](repeating: 0.1, count: 48000))
    try writer.finish()

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = attributes[.size] as? Int ?? 0
    #expect(size > 0)
  }
}
