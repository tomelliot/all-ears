import Testing

@testable import EarsCore

/// Tracks concurrent entries into a guarded section without touching wall-clock
/// time (`docs/engineering-practices.md`'s "no wall-clock time in tests,
/// anywhere"): `Task.yield()` gives the scheduler a genuine opportunity to run
/// another queued operation while this one is "in flight", so a gate that
/// merely delegated to actor reentrancy (rather than genuinely serializing)
/// would show `maxObserved > 1`.
private actor OverlapTracker {
  private(set) var current = 0
  private(set) var maxObserved = 0
  private(set) var order: [Int] = []

  func enter(_ id: Int) async {
    current += 1
    maxObserved = max(maxObserved, current)
    order.append(id)
    // Yield repeatedly while "in" the section so any concurrent entrant has
    // ample opportunity to interleave if the gate fails to serialize.
    await Task.yield()
    await Task.yield()
  }

  func exit() {
    current -= 1
  }
}

@Suite("ANEInferenceGate")
struct ANEInferenceGateTests {
  @Test("funnels many concurrent operations so at most one runs at a time")
  func neverOverlaps() async throws {
    let gate = ANEInferenceGate()
    let tracker = OverlapTracker()
    let operationCount = 25

    await withTaskGroup(of: Void.self) { group in
      for id in 0..<operationCount {
        group.addTask {
          try? await gate.run {
            await tracker.enter(id)
            await tracker.exit()
          }
        }
      }
    }

    #expect(await tracker.maxObserved == 1)
    #expect(await tracker.order.count == operationCount)
  }

  @Test("returns the operation's value")
  func returnsValue() async throws {
    let gate = ANEInferenceGate()
    let result = try await gate.run { 42 }
    #expect(result == 42)
  }

  @Test("propagates a thrown error and still releases the gate for the next caller")
  func propagatesErrorsAndReleases() async throws {
    struct Boom: Error, Equatable {}
    let gate = ANEInferenceGate()

    await #expect(throws: Boom.self) {
      try await gate.run {
        throw Boom()
      }
    }

    // The failed call must not leave the gate stuck "held".
    let result = try await gate.run { "ok" }
    #expect(result == "ok")
  }

  @Test("later callers still see every earlier call finish before starting")
  func fifoIsh() async throws {
    let gate = ANEInferenceGate()
    let tracker = OverlapTracker()

    async let first: Void = gate.run {
      await tracker.enter(1)
      await tracker.exit()
    }
    async let second: Void = gate.run {
      await tracker.enter(2)
      await tracker.exit()
    }
    async let third: Void = gate.run {
      await tracker.enter(3)
      await tracker.exit()
    }
    _ = try await (first, second, third)

    #expect(await tracker.maxObserved == 1)
    #expect(await tracker.order.count == 3)
  }
}
