/// The result of one ``LLMBackend/complete(_:)`` call.
///
/// Carries only the metadata `docs/specs/llm-stages.md` says logging
/// may record at `notice` and above -- "model, token counts, latency,
/// retries" -- never the prompt/response bodies; token counts are optional
/// since not every backend reports them (the `llm` CLI's plain-text stdout
/// contract has no structured usage field unless `--usage`-style output is
/// parsed separately).
public struct LLMCompletionResult: Sendable, Hashable, Codable {
  /// The completion text.
  public var text: String
  /// The model that produced it, when the backend reports one distinct from
  /// its configured model (e.g. an alias resolved to a concrete version).
  public var model: String?
  public var promptTokens: Int?
  public var completionTokens: Int?

  public init(
    text: String,
    model: String? = nil,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil
  ) {
    self.text = text
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
  }
}
