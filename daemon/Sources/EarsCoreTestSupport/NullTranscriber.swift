import EarsCore

/// A ``Transcriber`` that conforms to the base protocol only, advertising no
/// capabilities and returning no segments.
///
/// Proves the base seam is satisfiable in isolation and gives tests a value whose
/// `as?` casts to the capability protocols all fail. Not shipped capability —
/// this is scaffolding to prove the design is testable.
public struct NullTranscriber: Transcriber {
  public var info: ModelInfo

  public init(info: ModelInfo = ModelInfo(name: "null", version: "0", languages: ["en"])) {
    self.info = info
  }

  public func load(_ options: LoadOptions) throws {}

  public func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] {
    []
  }
}
