/// Builds the ``LLMPrompt`` `cleanup` sends to an ``LLMBackend`` for one
/// segment/chunk of transcript text.
///
/// Two guardrails from `docs/specs/llm-stages.md` live here:
///
/// - **Minimal-change prompt:** "instruct for the smallest edit that fixes
///   errors; keep filler words unless removal is explicitly configured."
///   The instructions text below says exactly that, and only opts into
///   filler removal when ``removeFiller`` is set.
/// - **Stable-prefix/dynamic split for cache reuse:** "split a stable
///   prompt prefix from the dynamic input (system prompt + vocabulary +
///   instructions as the prefix; the transcript as the suffix) so a caching
///   backend can reuse the KV-cache/prompt cache across chunks and runs."
///   ``stablePrefix`` depends only on this builder's configuration (system
///   prompt, vocabulary, filler policy) and is therefore byte-identical
///   across every ``build(transcript:)`` call for a given builder,
///   regardless of the transcript text passed in.
///
/// The vocabulary (merged global + session known-word list, per
/// `docs/data-formats.md`) is injected as an explicit correction backstop --
/// the same list a ``BiasingTranscriber`` uses at transcription time, reused
/// here per `docs/specs/model-interface.md`'s "known-word biasing
/// summary".
public struct CleanupPromptBuilder: Sendable {
  public var systemPrompt: String
  public var vocabulary: [String]
  public var removeFiller: Bool

  public init(
    systemPrompt: String = CleanupPromptBuilder.defaultSystemPrompt,
    vocabulary: [String] = [],
    removeFiller: Bool = false
  ) {
    self.systemPrompt = systemPrompt
    self.vocabulary = vocabulary
    self.removeFiller = removeFiller
  }

  public static let defaultSystemPrompt = """
    You clean up a raw speech transcript for readability. Make the smallest \
    edits that fix errors: correct mis-transcriptions and homophones, fix \
    punctuation and casing. Preserve meaning, timestamps, and speaker turns \
    exactly -- never invent, drop, or reorder content. Output only the \
    corrected text, nothing else.
    """

  /// The part of the prompt identical across every call this builder makes:
  /// the system prompt, the filler-word policy, and the vocabulary
  /// correction backstop (when non-empty).
  public var stablePrefix: String {
    var sections = [systemPrompt]
    if removeFiller {
      sections.append(
        "Remove filler words (\"um\", \"uh\", \"like\") where they add no meaning.")
    } else {
      sections.append("Keep filler words as-is; do not remove them.")
    }
    if !vocabulary.isEmpty {
      var vocabSection = "Known words/names that may be mis-transcribed -- correct to these\n"
      vocabSection += "when the audio clearly matches:\n"
      vocabSection += vocabulary.map { "- \($0)" }.joined(separator: "\n")
      sections.append(vocabSection)
    }
    return sections.joined(separator: "\n\n") + "\n\n"
  }

  /// Builds the full prompt for one segment/chunk's `transcript` text -- the
  /// dynamic suffix, sent verbatim with no additional wrapping so the
  /// backend's completion corresponds 1:1 with the input `cleanup` will run
  /// through ``CleanupValidator``.
  public func build(transcript: String) -> LLMPrompt {
    LLMPrompt(stablePrefix: stablePrefix, dynamicSuffix: transcript)
  }
}
