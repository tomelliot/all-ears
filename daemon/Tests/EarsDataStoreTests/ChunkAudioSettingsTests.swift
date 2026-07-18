import Testing

@testable import EarsDataStore

/// Pure unit tests for ``ChunkAudioSettings`` -- tier-0, no I/O.
@Suite("ChunkAudioSettings")
struct ChunkAudioSettingsTests {
  @Test("aac codec maps to an m4a container")
  func aacMapsToM4A() {
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 48000, bitrate: 64000)
    #expect(settings.fileExtension == "m4a")
  }

  @Test("opus codec maps to a caf container")
  func opusMapsToCAF() {
    let settings = ChunkAudioSettings(codec: "opus", sampleRate: 48000, bitrate: 64000)
    #expect(settings.fileExtension == "caf")
  }

  @Test("an unrecognised codec falls back to aac/m4a")
  func unknownCodecFallsBackToAAC() {
    let settings = ChunkAudioSettings(codec: "flac", sampleRate: 48000, bitrate: 64000)
    #expect(settings.fileExtension == "m4a")
  }

  @Test("sampleRate is threaded through")
  func sampleRateThreadedThrough() {
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 16000, bitrate: 64000)
    #expect(settings.sampleRate == 16000)
  }

  @Test("foundationSettings carries the sample rate and bitrate")
  func foundationSettingsCarriesValues() {
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 48000, bitrate: 64000)
    let foundation = settings.foundationSettings
    #expect(foundation["AVSampleRateKey"] as? Double == 48000)
    #expect(foundation["AVEncoderBitRateKey"] as? Int == 64000)
    #expect(foundation["AVNumberOfChannelsKey"] as? Int == 1)
  }

  // Regression test: a real AVAudioFile write with AVEncoderBitRateKey =
  // 64000 (the documented default, valid at 48kHz) throws outright at
  // 16kHz -- AudioConverterSetProperty(kAudioConverterEncodeBitRate)
  // rejects a bitrate the sample rate can't support. This is exactly the
  // native/ASR feed split this module's chunk encoder writes, so the
  // configured bitrate must be clamped per feed rather than passed through
  // unchanged. See ``AVFoundationChunkFileWriterTests`` for the real-write
  // regression test that first caught this.
  @Test("a bitrate too high for the sample rate is clamped down, not passed through unchanged")
  func highBitrateIsClampedForLowSampleRate() {
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 16000, bitrate: 64000)
    let clamped = settings.foundationSettings["AVEncoderBitRateKey"] as? Int
    #expect(clamped != nil)
    #expect((clamped ?? 0) <= 16000 * 3)
  }

  @Test("a bitrate already within range for the sample rate is passed through unchanged")
  func bitrateWithinRangeIsUnchanged() {
    let settings = ChunkAudioSettings(codec: "aac", sampleRate: 48000, bitrate: 64000)
    let bitrate = settings.foundationSettings["AVEncoderBitRateKey"] as? Int
    #expect(bitrate == 64000)
  }
}
