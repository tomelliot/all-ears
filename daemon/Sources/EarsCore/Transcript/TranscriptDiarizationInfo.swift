/// Diarization state recorded in transcript frontmatter's `diarization`
/// mapping (see `docs/data-formats.md`), e.g. `{ enabled: true, backend:
/// pyannote }`.
///
/// Distinct from ``DiarizerInfo`` for the same reason as ``TranscriptModelInfo``
/// is distinct from ``ModelInfo``: this is a small, display-oriented shape
/// scoped exactly to the frontmatter schema. `backend` is `nil` when
/// diarization was not enabled for the run, in which case the rendered
/// mapping omits the `backend` key entirely (`{ enabled: false }`).
public struct TranscriptDiarizationInfo: Sendable, Hashable, Codable {
  public var enabled: Bool
  public var backend: String?

  public init(enabled: Bool, backend: String? = nil) {
    self.enabled = enabled
    self.backend = backend
  }
}
