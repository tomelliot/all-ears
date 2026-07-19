/// Opaque, backend-owned continuity state carried inside ``DecoderState``.
///
/// `EarsCore` deliberately knows nothing about any concrete decoder
/// representation (Core ML arrays, token ids, hidden LSTM state); a backend
/// shim (e.g. `EarsTranscribeKit`'s FluidAudio TDT state) conforms a small
/// reference type and stashes it here, so ``DecoderState`` stays a plain
/// value the caller threads `inout` while the backend keeps whatever real
/// state its decoder needs. Class-bound so ``DecoderState`` can stay
/// `Hashable` by comparing box *identity* — two states are interchangeable
/// exactly when they share the same underlying decoder continuity.
public protocol BackendDecoderState: AnyObject, Sendable {}

/// Explicit, caller-owned continuity state for streaming decoding.
///
/// Passed `inout` to ``StreamingTranscriber/step(_:state:)`` so the transcription
/// manager itself stays stateless across sources (FluidAudio's pattern): one
/// manager serves many sources, and a light streaming instance and a
/// vocab-boosted final instance can share one underlying model, the second
/// costing only decoder state rather than a second model load.
///
/// The pure fields (`priorText`, `framesConsumed`) are the caller-visible
/// bookkeeping; ``backend`` carries the real token/hidden-decoder state,
/// owned entirely by whichever backend shim populated it (see
/// ``BackendDecoderState``). Start a fresh stream with `DecoderState()`; a
/// state populated by one backend must not be handed to a different backend
/// (a shim finding a foreign box starts fresh rather than misreading it).
public struct DecoderState: Sendable, Hashable {
  /// Text decoded so far in this stream, for continuity across `step` calls.
  public var priorText: String
  /// Number of audio frames consumed so far in this stream.
  public var framesConsumed: Int
  /// The backend shim's real decoder state (e.g. FluidAudio's TDT LSTM
  /// hidden state + last token), or `nil` before the first `step` of a
  /// stream. Compared by identity for `Hashable`.
  public var backend: (any BackendDecoderState)?

  public init(
    priorText: String = "",
    framesConsumed: Int = 0,
    backend: (any BackendDecoderState)? = nil
  ) {
    self.priorText = priorText
    self.framesConsumed = framesConsumed
    self.backend = backend
  }

  public static func == (lhs: DecoderState, rhs: DecoderState) -> Bool {
    lhs.priorText == rhs.priorText
      && lhs.framesConsumed == rhs.framesConsumed
      && lhs.backend.map { ObjectIdentifier($0) } == rhs.backend.map { ObjectIdentifier($0) }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(priorText)
    hasher.combine(framesConsumed)
    hasher.combine(backend.map { ObjectIdentifier($0) })
  }
}
