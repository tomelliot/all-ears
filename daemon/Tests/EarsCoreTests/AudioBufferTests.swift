import Testing

@testable import EarsCore

@Suite("AudioBuffer")
struct AudioBufferTests {
  @Test("reports frame count and duration from sample rate")
  func frameCountAndDuration() {
    let buffer = AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
    #expect(buffer.frameCount == 16_000)
    #expect(buffer.duration == 1.0)
  }

  @Test("guards against a non-positive sample rate")
  func zeroSampleRate() {
    let buffer = AudioBuffer(samples: [0, 0, 0], sampleRate: 0)
    #expect(buffer.duration == 0)
  }
}
