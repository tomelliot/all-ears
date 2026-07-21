import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Pure, decoder-injected coverage of ``FileAudioReader``: a fake ``Decoder``
/// stands in for the real `AVFoundation` decode, so the resample-and-slice
/// logic is exercised with no audio file on disk. The one test that does touch
/// disk round-trips a real `.m4a` through the production decoder to prove the
/// `AVFoundation` shim itself decodes a real container.
@Suite("FileAudioReader")
struct FileAudioReaderTests {
  private let targetRate = 16000
  private let anchor = Instant(secondsSinceEpoch: 0)

  @Test("a file already at the target rate is returned as one whole-file slice, untouched")
  func alreadyAtTargetRate() throws {
    let samples = (0..<targetRate).map { Float($0) / Float(targetRate) }  // 1 second
    let reader = FileAudioReader(decode: { _ in
      AudioBuffer(samples: samples, sampleRate: self.targetRate)
    })

    let slices = try reader.slices(
      fileURL: URL(fileURLWithPath: "/ignored.m4a"), targetSampleRate: targetRate, anchor: anchor)

    #expect(slices.count == 1)
    #expect(slices[0].audio.samples == samples)
    #expect(slices[0].audio.sampleRate == targetRate)
    #expect(slices[0].range.start == anchor)
    // 16000 samples at 16 kHz is exactly one second.
    #expect(abs(slices[0].range.duration - 1.0) < 1e-9)
  }

  @Test("a file at a different rate is resampled to the target rate before slicing")
  func resamplesToTargetRate() throws {
    // One second of 48 kHz audio -> resampled to 16 kHz should be ~16000 frames.
    let sourceRate = 48000
    let samples = (0..<sourceRate).map { index in
      Float(sin(2.0 * Double.pi * 440.0 * Double(index) / Double(sourceRate)))
    }
    let reader = FileAudioReader(decode: { _ in
      AudioBuffer(samples: samples, sampleRate: sourceRate)
    })

    let slices = try reader.slices(
      fileURL: URL(fileURLWithPath: "/ignored.m4a"), targetSampleRate: targetRate, anchor: anchor)

    #expect(slices.count == 1)
    #expect(slices[0].audio.sampleRate == targetRate)
    // Rational 48k->16k is a clean 3:1 decimation; allow a few frames of
    // converter rounding either way rather than asserting an exact count.
    #expect(abs(slices[0].audio.samples.count - targetRate) <= 8)
  }

  @Test("an empty (or silent) file yields no slices")
  func emptyFileYieldsNoSlices() throws {
    let reader = FileAudioReader(decode: { _ in
      AudioBuffer(samples: [], sampleRate: self.targetRate)
    })

    let slices = try reader.slices(
      fileURL: URL(fileURLWithPath: "/ignored.m4a"), targetSampleRate: targetRate, anchor: anchor)

    #expect(slices.isEmpty)
  }

  @Test("the slice range starts at the given anchor")
  func sliceRangeStartsAtAnchor() throws {
    let customAnchor = Instant(secondsSinceEpoch: 1_000)
    let reader = FileAudioReader(decode: { _ in
      AudioBuffer(
        samples: [Float](repeating: 0.1, count: self.targetRate), sampleRate: self.targetRate)
    })

    let slices = try reader.slices(
      fileURL: URL(fileURLWithPath: "/ignored.m4a"), targetSampleRate: targetRate,
      anchor: customAnchor)

    #expect(slices.count == 1)
    #expect(slices[0].range.start == customAnchor)
  }

  @Test("a decode failure propagates as a throw")
  func decodeFailurePropagates() {
    struct Boom: Error {}
    let reader = FileAudioReader(decode: { _ in throw Boom() })

    #expect(throws: Boom.self) {
      try reader.slices(fileURL: URL(fileURLWithPath: "/ignored.m4a"), targetSampleRate: targetRate)
    }
  }

  @Test("the production AVFoundation decoder reads a real encoded .m4a")
  func productionDecoderReadsRealM4A() throws {
    // Write a real AAC .m4a via the same writer earsd uses, then decode it
    // back through the production path -- proving the shim handles a real
    // container, not just a fake buffer.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FileAudioReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("clip.m4a")
    let writeRate = 16000
    let tone = (0..<writeRate).map { index in
      Float(sin(2.0 * Double.pi * 440.0 * Double(index) / Double(writeRate)) * 0.5)
    }
    let writer = try AVFoundationChunkFileWriter(
      url: fileURL,
      settings: ChunkAudioSettings(codec: "aac", sampleRate: writeRate, bitrate: 64000))
    try writer.write(samples: tone)
    try writer.finish()

    let decoded = try FileAudioReader.decodeWithAVFoundation(fileURL)
    #expect(decoded.sampleRate == writeRate)
    // AAC is lossy and primes a few frames, so assert a roughly-one-second
    // decode rather than an exact sample count.
    #expect(abs(decoded.samples.count - writeRate) <= writeRate / 10)
  }
}
