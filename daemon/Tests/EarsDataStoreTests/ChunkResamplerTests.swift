import Testing

@testable import EarsDataStore

/// Tier-2 per `docs/engineering-practices.md`: exercises the real
/// `AVAudioConverter`-backed resampler rather than mocking it (this is the
/// thin hardware/model-adjacent shim itself, not logic behind it).
@Suite("ChunkResampler")
struct ChunkResamplerTests {
  @Test("init fails for a non-positive sample rate")
  func initFailsForInvalidRate() {
    #expect(ChunkResampler(nativeSampleRate: 0, asrSampleRate: 16000) == nil)
    #expect(ChunkResampler(nativeSampleRate: 48000, asrSampleRate: 0) == nil)
  }

  @Test("resampling 48kHz down to 16kHz shrinks the sample count by ~1/3")
  func resampleShrinksByRatio() throws {
    let resampler = try #require(ChunkResampler(nativeSampleRate: 48000, asrSampleRate: 16000))
    let input = [Float](repeating: 0.5, count: 48000)  // 1 second at 48kHz
    let output = try resampler.resample(input)

    // Expect ~16000 samples (1 second at 16kHz); allow a small tolerance for
    // converter filter latency/edge effects.
    #expect(abs(output.count - 16000) < 200)
  }

  @Test("resampling an empty buffer produces an empty result")
  func resampleEmptyInput() throws {
    let resampler = try #require(ChunkResampler(nativeSampleRate: 48000, asrSampleRate: 16000))
    let output = try resampler.resample([])
    #expect(output.isEmpty)
  }

  @Test("repeated calls on the same resampler each succeed independently")
  func repeatedCallsSucceed() throws {
    let resampler = try #require(ChunkResampler(nativeSampleRate: 48000, asrSampleRate: 16000))
    let input = [Float](repeating: 0.25, count: 4800)  // 0.1 second
    let first = try resampler.resample(input)
    let second = try resampler.resample(input)
    #expect(!first.isEmpty)
    #expect(!second.isEmpty)
  }
}
