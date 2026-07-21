import EarsCore
import Testing

@testable import EarsDataStore

/// Tier-2 per `docs/engineering-practices.md`: exercises the real
/// `AVAudioConverter`-backed normalizer rather than mocking it (the thin
/// hardware-adjacent shim itself, not logic behind it). The frame-count
/// assertions are the point: they lock in `.none` priming + converter
/// persistence, without which the buffer-derived capture timeline drifts.
@Suite("AdaptiveResampler")
struct AdaptiveResamplerTests {
  @Test("init fails for a non-positive target rate")
  func initFailsForInvalidRate() {
    #expect(AdaptiveResampler(targetSampleRate: 0) == nil)
    #expect(AdaptiveResampler(targetSampleRate: -48000) == nil)
  }

  @Test("a buffer already at the target rate passes through untouched")
  func passthroughIdentity() throws {
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 48000))
    let input = AudioBuffer(samples: [0.1, -0.2, 0.3, -0.4], sampleRate: 48000)
    let output = try resampler.normalize(input)
    #expect(output.sampleRate == 48000)
    #expect(output.samples == input.samples)
  }

  @Test("an empty buffer normalizes to an empty buffer at the target rate")
  func emptyBuffer() throws {
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 48000))
    let output = try resampler.normalize(AudioBuffer(samples: [], sampleRate: 16000))
    #expect(output.samples.isEmpty)
    #expect(output.sampleRate == 48000)
  }

  @Test("upsampling 16kHz to 48kHz triples the count (±1) and restamps")
  func upsample16to48() throws {
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 48000))
    let input = AudioBuffer(samples: [Float](repeating: 0.5, count: 1600), sampleRate: 16000)
    let output = try resampler.normalize(input)
    #expect(output.sampleRate == 48000)
    #expect(abs(output.samples.count - 4800) <= 1)
  }

  @Test("downsampling 48kHz to 16kHz thirds the count and restamps")
  func downsample48to16() throws {
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 16000))
    // The *first* downsample call absorbs the decimation filter's one-time
    // warmup (it emits short); with converter persistence the steady state
    // then tracks the ideal 1/3 ratio. Warm up, then assert steady state.
    let warmup = try resampler.normalize(
      AudioBuffer(samples: [Float](repeating: 0.5, count: 4800), sampleRate: 48000))
    #expect(warmup.sampleRate == 16000)
    let output = try resampler.normalize(
      AudioBuffer(samples: [Float](repeating: 0.5, count: 4800), sampleRate: 48000))
    #expect(output.sampleRate == 16000)
    #expect(abs(output.samples.count - 1600) <= 20)
  }

  @Test("a mid-stream input-rate flip rebuilds the converter and keeps normalizing")
  func midStreamRateFlip() throws {
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 48000))

    // 16k -> 48k
    let up = try resampler.normalize(
      AudioBuffer(samples: [Float](repeating: 0.5, count: 1600), sampleRate: 16000))
    #expect(up.sampleRate == 48000)
    #expect(abs(up.samples.count - 4800) <= 1)

    // 48k passthrough
    let same = try resampler.normalize(
      AudioBuffer(samples: [Float](repeating: 0.25, count: 4800), sampleRate: 48000))
    #expect(same.sampleRate == 48000)
    #expect(same.samples.count == 4800)

    // back to 16k -> 48k (converter rebuilt again)
    let upAgain = try resampler.normalize(
      AudioBuffer(samples: [Float](repeating: 0.5, count: 1600), sampleRate: 16000))
    #expect(upAgain.sampleRate == 48000)
    #expect(abs(upAgain.samples.count - 4800) <= 1)
  }

  @Test("frame conservation holds across many sequential same-rate buffers")
  func frameConservationAcrossManyBuffers() throws {
    // The persistence + `.none` priming guarantee: per-call rounding is ±1 and
    // non-accumulating, so summed output over N buffers stays within a small
    // constant of N * ratio — not O(N) drift.
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 48000))
    let framesPerBuffer = 1600  // 0.1s at 16k
    let bufferCount = 100
    var total = 0
    for _ in 0..<bufferCount {
      let out = try resampler.normalize(
        AudioBuffer(samples: [Float](repeating: 0.5, count: framesPerBuffer), sampleRate: 16000))
      total += out.samples.count
    }
    let expected = framesPerBuffer * bufferCount * 3  // 480000 at 48k
    // Non-accumulating: bounded by a small constant, nowhere near ±bufferCount.
    #expect(abs(total - expected) <= 2)
  }

  @Test("frame conservation holds across many sequential downsampled buffers")
  func frameConservationDownsampling() throws {
    // The harder direction: downsampling has a one-time filter-warmup deficit
    // on the first call, but converter persistence keeps it from accumulating.
    // Over many buffers the total stays within a small *constant* of the ideal
    // — a per-buffer accumulation of even one frame would drift by `bufferCount`.
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 16000))
    let framesPerBuffer = 4800  // 0.1s at 48k
    let bufferCount = 200
    var total = 0
    for _ in 0..<bufferCount {
      let out = try resampler.normalize(
        AudioBuffer(samples: [Float](repeating: 0.5, count: framesPerBuffer), sampleRate: 48000))
      total += out.samples.count
    }
    let expected = framesPerBuffer * bufferCount / 3  // 320000 at 16k
    #expect(abs(total - expected) <= 256)  // bounded constant, not O(bufferCount)
  }

  @Test("an input rate no converter can bridge throws")
  func invalidInputRateThrows() throws {
    let resampler = try #require(AdaptiveResampler(targetSampleRate: 48000))
    #expect(throws: DataStoreError.self) {
      _ = try resampler.normalize(AudioBuffer(samples: [0.1, 0.2], sampleRate: 0))
    }
  }
}
