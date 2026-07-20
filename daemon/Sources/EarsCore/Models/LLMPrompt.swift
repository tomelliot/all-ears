/// A completion request already split into a stable prefix and a dynamic
/// suffix, per `docs/specs/llm-stages.md`'s cache-reuse guardrail:
/// "split a stable prompt prefix from the dynamic input (system prompt +
/// vocabulary + instructions as the prefix; the transcript as the suffix) so
/// a caching backend can reuse the KV-cache/prompt cache across chunks and
/// runs."
///
/// A backend with no cache (the `command`/`llm`-CLI backend) simply
/// concatenates the two via ``fullText``; a future caching backend (e.g.
/// `anthropic-sdk`) can key its cache on `stablePrefix` alone and only pay
/// for `dynamicSuffix` on each call. Building this split is the *caller's*
/// job (`cleanup`'s prompt builder) — the backend only ever sees the two
/// pieces together.
public struct LLMPrompt: Sendable, Hashable, Codable {
  /// The part identical across every chunk/segment in a run: system prompt,
  /// vocabulary, and instructions.
  public var stablePrefix: String
  /// The part that varies per call: the transcript text being cleaned.
  public var dynamicSuffix: String

  public init(stablePrefix: String, dynamicSuffix: String) {
    self.stablePrefix = stablePrefix
    self.dynamicSuffix = dynamicSuffix
  }

  /// The concatenated text a non-caching backend sends verbatim.
  public var fullText: String { stablePrefix + dynamicSuffix }
}
