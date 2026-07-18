/// The YAML frontmatter block of a rendered transcript document, matching the
/// fixed schema shown in `docs/data-formats.md`'s "Transcript format" section
/// field-for-field and in field order:
///
/// ```yaml
/// schema: 1
/// kind: transcript
/// session: 2026-07-17T10-30-00Z_standup
/// sources: [mic, "app:us.zoom.xos"]
/// range: { start: 2026-07-17T10:30:00Z, end: 2026-07-17T11:02:00Z }
/// model: { name: parakeet, backend: fluidaudio, version: "0.x" }
/// diarization: { enabled: true, backend: pyannote }
/// generated: 2026-07-17T11:02:14Z
/// duration_seconds: 1920
/// speech_seconds: 1440
/// word_count: 3120
/// vocab: [global, standup]
/// ```
///
/// `derivedFrom` is only present for `kind: clean` / `kind: summary` documents
/// (see `docs/data-formats.md`); when non-`nil` it renders as a `derived_from`
/// line immediately after `kind`.
public struct TranscriptFrontmatter: Sendable, Hashable {
  public var schema: Int
  public var kind: TranscriptKind
  /// The session id, e.g. `2026-07-17T10-30-00Z_standup` (``SessionDescriptor/id``).
  public var session: String
  public var sources: [SourceID]
  public var range: TimeRange
  public var model: TranscriptModelInfo
  public var diarization: TranscriptDiarizationInfo
  /// When this document was rendered. Always a parameter — never the wall clock.
  public var generated: Instant
  public var durationSeconds: Double
  public var speechSeconds: Double
  public var wordCount: Int
  /// Vocabulary list names merged for this run, e.g. `["global", "standup"]`.
  public var vocab: [String]
  /// Names the source transcript this document was derived from
  /// (`cleanup`/`summarize` only); `nil` for `kind: transcript`.
  public var derivedFrom: String?

  public init(
    schema: Int,
    kind: TranscriptKind,
    session: String,
    sources: [SourceID],
    range: TimeRange,
    model: TranscriptModelInfo,
    diarization: TranscriptDiarizationInfo,
    generated: Instant,
    durationSeconds: Double,
    speechSeconds: Double,
    wordCount: Int,
    vocab: [String],
    derivedFrom: String? = nil
  ) {
    self.schema = schema
    self.kind = kind
    self.session = session
    self.sources = sources
    self.range = range
    self.model = model
    self.diarization = diarization
    self.generated = generated
    self.durationSeconds = durationSeconds
    self.speechSeconds = speechSeconds
    self.wordCount = wordCount
    self.vocab = vocab
    self.derivedFrom = derivedFrom
  }
}
