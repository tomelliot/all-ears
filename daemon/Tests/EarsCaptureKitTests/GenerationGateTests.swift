import Testing

@testable import EarsCaptureKit

@Suite("GenerationGate")
struct GenerationGateTests {
  @Test("a freshly-captured generation is current")
  func freshGenerationIsCurrent() {
    let gate = GenerationGate()
    let g = gate.generation
    #expect(gate.isCurrent(g))
  }

  @Test("invalidate makes a previously-captured generation stale")
  func invalidateMakesStale() {
    let gate = GenerationGate()
    let old = gate.generation
    gate.invalidate()
    #expect(!gate.isCurrent(old))
  }

  @Test("a stale callback is rejected after teardown increments the counter")
  func staleCallbackRejectedAfterTeardown() {
    // Simulate the load-bearing property: a callback holds the generation it
    // was installed with; teardown invalidates; the callback path must now be
    // recognised as stale and drop its data.
    let gate = GenerationGate()
    let installGeneration = gate.generation

    var published: [Int] = []
    func callback(_ sample: Int) {
      guard gate.isCurrent(installGeneration) else { return }  // drop stale
      published.append(sample)
    }

    callback(1)  // live: published
    gate.invalidate()  // teardown begins before the next callback fires
    callback(2)  // stale: dropped

    #expect(published == [1])
  }

  @Test("a callback re-installed with the new generation is accepted again")
  func reinstallAcceptsNewGeneration() {
    let gate = GenerationGate()
    let firstGen = gate.generation
    let secondGen = gate.invalidate()
    #expect(!gate.isCurrent(firstGen))
    #expect(gate.isCurrent(secondGen))
  }
}
