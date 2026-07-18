/// Everything that can go wrong decoding a `ConfigValue` tree into
/// ``SourceDescriptor`` (`meta.toml`) or ``SessionDescriptor`` (`session.toml`),
/// per `docs/data-formats.md`'s exact schemas. Shared by both mappers so a
/// caller handles one error type regardless of which descriptor it's decoding.
public enum DescriptorTOMLError: Error, Sendable, Hashable {
  /// The root value wasn't a table at all.
  case notATable
  /// A required key is absent, or present with the wrong `ConfigValueKind`.
  case missingField(String)
  /// A required key is present with the right kind, but its value doesn't
  /// parse into the target type (an unrecognised enum raw value, or a
  /// timestamp that isn't valid ISO-8601).
  case invalidField(String)
}
