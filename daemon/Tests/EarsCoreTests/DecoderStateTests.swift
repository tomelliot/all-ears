import Testing

@testable import EarsCore

/// Covers ``DecoderState``'s backend-box seam: the opaque
/// ``BackendDecoderState`` reference a backend shim threads its real decoder
/// state through, compared by identity for `Hashable`.
@Suite("DecoderState")
struct DecoderStateTests {
  private final class FakeBackendState: BackendDecoderState, @unchecked Sendable {}

  @Test("fresh states with no backend box are equal")
  func freshStatesEqual() {
    #expect(DecoderState() == DecoderState())
    #expect(DecoderState().hashValue == DecoderState().hashValue)
  }

  @Test("states sharing one backend box are equal; distinct boxes are not")
  func backendBoxComparesByIdentity() {
    let box = FakeBackendState()
    let a = DecoderState(priorText: "hi", framesConsumed: 10, backend: box)
    let b = DecoderState(priorText: "hi", framesConsumed: 10, backend: box)
    #expect(a == b)

    let c = DecoderState(priorText: "hi", framesConsumed: 10, backend: FakeBackendState())
    #expect(a != c)

    let d = DecoderState(priorText: "hi", framesConsumed: 10, backend: nil)
    #expect(a != d)
  }

  @Test("pure fields still participate in equality alongside the box")
  func pureFieldsStillCompared() {
    let box = FakeBackendState()
    let a = DecoderState(priorText: "hi", framesConsumed: 10, backend: box)
    let b = DecoderState(priorText: "bye", framesConsumed: 10, backend: box)
    #expect(a != b)
  }
}
