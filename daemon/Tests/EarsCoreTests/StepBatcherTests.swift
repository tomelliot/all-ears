import Testing

@testable import EarsCore

/// Tier-0 coverage of ``StepBatcher``, the fixed-cadence batcher from
/// `docs/product/specs/transcribe.md`'s append-only delta contract: input
/// cadence (chunk arrival) is decoupled from model step size.
@Suite("StepBatcher")
struct StepBatcherTests {
  private func buffer(_ count: Int, rate: Int = 16_000, value: Float = 0.25) -> AudioBuffer {
    AudioBuffer(samples: [Float](repeating: value, count: count), sampleRate: rate)
  }

  @Test("accumulates sub-step input until a full step is available")
  func accumulatesUntilFullStep() {
    var batcher = StepBatcher(stepFrameCount: 100)
    #expect(batcher.append(buffer(40)).isEmpty)
    #expect(batcher.append(buffer(40)).isEmpty)
    #expect(batcher.pendingFrameCount == 80)

    let steps = batcher.append(buffer(40))
    #expect(steps.count == 1)
    #expect(steps[0].frameCount == 100)
    #expect(batcher.pendingFrameCount == 20)
  }

  @Test("a large input releases multiple full steps at once, in order")
  func largeInputReleasesMultipleSteps() {
    var batcher = StepBatcher(stepFrameCount: 100)
    var samples = [Float]()
    // Distinct values per step region so ordering is observable.
    samples.append(contentsOf: [Float](repeating: 1, count: 100))
    samples.append(contentsOf: [Float](repeating: 2, count: 100))
    samples.append(contentsOf: [Float](repeating: 3, count: 50))

    let steps = batcher.append(AudioBuffer(samples: samples, sampleRate: 16_000))
    #expect(steps.count == 2)
    #expect(steps[0].samples.allSatisfy { $0 == 1 })
    #expect(steps[1].samples.allSatisfy { $0 == 2 })
    #expect(batcher.pendingFrameCount == 50)
  }

  @Test("steps preserve the input sample rate")
  func preservesSampleRate() {
    var batcher = StepBatcher(stepFrameCount: 10)
    let steps = batcher.append(buffer(10, rate: 16_000))
    #expect(steps.count == 1)
    #expect(steps[0].sampleRate == 16_000)
  }

  @Test("flush releases the sub-step remainder")
  func flushReleasesRemainder() {
    var batcher = StepBatcher(stepFrameCount: 100)
    _ = batcher.append(buffer(130))

    let remainder = batcher.flush()
    #expect(remainder?.frameCount == 30)
    #expect(remainder?.sampleRate == 16_000)
    #expect(batcher.pendingFrameCount == 0)
  }

  @Test("flush with nothing pending returns nil")
  func flushEmptyReturnsNil() {
    var batcher = StepBatcher(stepFrameCount: 100)
    #expect(batcher.flush() == nil)

    // Exactly consumed: a full step leaves nothing behind to flush.
    var exact = StepBatcher(stepFrameCount: 50)
    _ = exact.append(buffer(50))
    #expect(exact.flush() == nil)
  }

  @Test("an empty append is a no-op")
  func emptyAppendIsNoOp() {
    var batcher = StepBatcher(stepFrameCount: 10)
    #expect(batcher.append(buffer(0)).isEmpty)
    #expect(batcher.pendingFrameCount == 0)
    #expect(batcher.flush() == nil)
  }
}
