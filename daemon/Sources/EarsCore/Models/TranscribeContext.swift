/// Per-call context handed to a ``Transcriber``: biasing vocabulary, a language
/// hint, and prior text for continuity.
///
/// The vocabulary is the merged global + per-session known-word list; a
/// ``BiasingTranscriber`` uses it for decoder/CTC keyword boosting, and it is
/// also reused as a correction backstop in `cleanup`. `priorText` carries recent
/// decoded text so a backend can maintain continuity across successive calls
/// without the caller's manager holding per-source state.
public struct TranscribeContext: Sendable, Hashable, Codable {
  /// Known-word / biasing terms (merged global + session vocabulary).
  public var vocabulary: [String]
  /// Language hint (e.g. `"en"`), or `nil` to let the backend decide.
  public var languageHint: String?
  /// Recently decoded text, for cross-call continuity.
  public var priorText: String?

  public init(
    vocabulary: [String] = [],
    languageHint: String? = nil,
    priorText: String? = nil
  ) {
    self.vocabulary = vocabulary
    self.languageHint = languageHint
    self.priorText = priorText
  }
}
