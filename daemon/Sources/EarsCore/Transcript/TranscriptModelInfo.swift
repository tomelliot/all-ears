/// The ASR model identity recorded in transcript frontmatter's `model` mapping
/// (see `docs/data-formats.md`), e.g. `{ name: parakeet, backend: fluidaudio,
/// version: "0.x" }`.
///
/// This is deliberately distinct from ``ModelInfo``: that type describes a
/// backend's *capability flags* for the pipeline (streaming, biasing, word
/// timings), and has no `backend` field, while the frontmatter needs exactly
/// `name`/`backend`/`version` for display. Keeping them separate avoids
/// contorting either type to serve both purposes.
public struct TranscriptModelInfo: Sendable, Hashable, Codable {
  public var name: String
  public var backend: String
  public var version: String

  public init(name: String, backend: String, version: String) {
    self.name = name
    self.backend = backend
    self.version = version
  }
}
