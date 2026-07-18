import EarsCore

/// A ``Transcriber`` that conforms to *all* capability protocols
/// (``StreamingTranscriber``, ``BiasingTranscriber``, ``WordTimingTranscriber``),
/// with matching `info` flags set.
///
/// Proves the capability-by-protocol pattern composes and that a consumer can
/// `as?`-cast a base ``Transcriber`` to each capability. Behaviour is trivial;
/// this is test scaffolding, not shipped capability.
public struct CapableTranscriber: StreamingTranscriber, BiasingTranscriber, WordTimingTranscriber {
  public var info: ModelInfo

  public init(
    info: ModelInfo = ModelInfo(
      name: "capable",
      version: "0",
      languages: ["en"],
      supportsStreaming: true,
      supportsBiasing: true,
      wordTimings: true
    )
  ) {
    self.info = info
  }

  public func load(_ options: LoadOptions) throws {}

  public func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] {
    []
  }

  public func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment] {
    state.framesConsumed += frames.frameCount
    return []
  }

  public func setBias(_ terms: [String]) throws {}
}
