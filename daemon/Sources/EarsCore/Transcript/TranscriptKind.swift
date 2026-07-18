/// The kind of transcript document being rendered, mirroring the frontmatter
/// `kind` field in `docs/data-formats.md`.
///
/// `transcript` is the direct output of `transcribe`; `clean` and `summary` are
/// produced by `cleanup`/`summarize` from an existing transcript and carry a
/// `derived_from` field in their frontmatter (see ``TranscriptFrontmatter``).
public enum TranscriptKind: String, Sendable, Hashable, Codable {
  case transcript
  case clean
  case summary
}
