import EarsCore

/// A ``Diarizer`` that assigns no speaker spans. Proves the seam is mockable; not
/// shipped capability.
public struct NullDiarizer: Diarizer {
  public var info: DiarizerInfo

  public init(info: DiarizerInfo = DiarizerInfo(name: "null", version: "0")) {
    self.info = info
  }

  public func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan] {
    []
  }
}
