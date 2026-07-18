/// Descriptive metadata and capability flags for a ``Transcriber`` backend.
///
/// The pipeline reads these flags to decide what a backend can do — and, in
/// concert, `as?`-casts to the matching capability protocol — rather than
/// switching on the model name. `supportsBiasing` in particular decides whether
/// the known-word list is injected at transcription or left to `cleanup`.
public struct ModelInfo: Sendable, Hashable, Codable {
  public var name: String
  public var version: String
  /// BCP-47-style language tags the backend supports (e.g. `["en"]`).
  public var languages: [String]
  /// Backend conforms to ``StreamingTranscriber`` (incremental `step` decoding).
  public var supportsStreaming: Bool
  /// Backend conforms to ``BiasingTranscriber`` (decoder/CTC keyword boosting).
  public var supportsBiasing: Bool
  /// Backend conforms to ``WordTimingTranscriber`` (populates `Segment.words`).
  public var wordTimings: Bool

  public init(
    name: String,
    version: String,
    languages: [String],
    supportsStreaming: Bool = false,
    supportsBiasing: Bool = false,
    wordTimings: Bool = false
  ) {
    self.name = name
    self.version = version
    self.languages = languages
    self.supportsStreaming = supportsStreaming
    self.supportsBiasing = supportsBiasing
    self.wordTimings = wordTimings
  }
}
