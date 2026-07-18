import EarsCore

/// A ``VAD`` that reports no spans. Proves the seam is mockable; not shipped
/// capability.
public struct NullVAD: VAD {
  public init() {}

  public func detect(in audio: AudioBuffer) throws -> [VADSpan] {
    []
  }
}
