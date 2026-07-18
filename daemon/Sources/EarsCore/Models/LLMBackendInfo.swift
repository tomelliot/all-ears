/// Descriptive metadata for an ``LLMBackend``: which backend kind is running
/// and which model it invoked, for logging and for `clean.md`/`summary.md`
/// frontmatter (`model:`) per `docs/data-formats.md`'s reproducibility field.
public struct LLMBackendInfo: Sendable, Hashable, Codable {
  /// The backend kind, e.g. `"llm-cli"` (the default `command` backend) or
  /// `"anthropic-sdk"` (a future native backend). See
  /// `docs/product/specs/llm-stages.md`.
  public var name: String
  /// The model name passed to the backend (e.g. `llm -m <model>`), when known.
  public var model: String?

  public init(name: String, model: String? = nil) {
    self.name = name
    self.model = model
  }
}
