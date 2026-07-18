import Testing

@testable import EarsCore

/// Reproduces `docs/data-formats.md`'s "Transcript format" example verbatim
/// and asserts the renderer's output matches it byte-for-byte, plus the
/// `kind: clean`/`kind: summary` variants and the edge cases called out in
/// the doc (no diarization, single segment, empty vocab).
@Suite("TranscriptRenderer — Markdown")
struct TranscriptRenderingTests {
  /// The standup session from `docs/data-formats.md`, built from the same
  /// wall-clock instants the doc's frontmatter shows
  /// (`2026-07-17T10:30:00Z` / `...T11:02:00Z` / `...T11:02:14Z`).
  private static func standupFrontmatter(
    kind: TranscriptKind = .transcript,
    diarization: TranscriptDiarizationInfo = TranscriptDiarizationInfo(
      enabled: true, backend: "pyannote"),
    vocab: [String] = ["global", "standup"],
    derivedFrom: String? = nil
  ) -> TranscriptFrontmatter {
    TranscriptFrontmatter(
      schema: 1,
      kind: kind,
      session: "2026-07-17T10-30-00Z_standup",
      sources: ["mic", "app:us.zoom.xos"],
      range: TimeRange(
        start: Instant(secondsSinceEpoch: 1_784_284_200),
        end: Instant(secondsSinceEpoch: 1_784_286_120)
      ),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: diarization,
      generated: Instant(secondsSinceEpoch: 1_784_286_134),
      durationSeconds: 1920,
      speechSeconds: 1440,
      wordCount: 3120,
      vocab: vocab,
      derivedFrom: derivedFrom
    )
  }

  private static let standupSegments: [TranscriptSegment] = [
    TranscriptSegment(
      source: "mic",
      speaker: "You",
      segment: Segment(start: 4, end: 10, text: "Morning — let's keep this quick. Any blockers?")
    ),
    TranscriptSegment(
      source: "app:us.zoom.xos",
      speaker: "Speaker 2",
      segment: Segment(
        start: 11, end: 18, text: "Nothing from me, the deploy went out last night."),
      sourceProvenance: true
    ),
    TranscriptSegment(
      source: "app:us.zoom.xos",
      speaker: "Speaker 3",
      segment: Segment(start: 19, end: 25, text: "I'm blocked on the API key rotation."),
      sourceProvenance: true
    ),
  ]

  @Test("matches docs/data-formats.md's transcript example byte-for-byte")
  func matchesDocExample() {
    let document = TranscriptDocument(
      frontmatter: Self.standupFrontmatter(), segments: Self.standupSegments)

    let expected = [
      "---",
      "schema: 1",
      "kind: transcript",
      "session: 2026-07-17T10-30-00Z_standup",
      "sources: [mic, \"app:us.zoom.xos\"]",
      "range: { start: 2026-07-17T10:30:00Z, end: 2026-07-17T11:02:00Z }",
      "model: { name: parakeet, backend: fluidaudio, version: \"0.x\" }",
      "diarization: { enabled: true, backend: pyannote }",
      "generated: 2026-07-17T11:02:14Z",
      "duration_seconds: 1920",
      "speech_seconds: 1440",
      "word_count: 3120",
      "vocab: [global, standup]",
      "---",
      "",
      "## [10:30:04] You",
      "Morning — let's keep this quick. Any blockers?",
      "",
      "## [10:30:11] Speaker 2  <!-- source: app:us.zoom.xos -->",
      "Nothing from me, the deploy went out last night.",
      "",
      "## [10:30:19] Speaker 3  <!-- source: app:us.zoom.xos -->",
      "I'm blocked on the API key rotation.",
      "",
    ].joined(separator: "\n")

    #expect(TranscriptRenderer.renderMarkdown(document) == expected)
  }

  @Test("kind: clean renders derived_from after kind")
  func cleanKindWithDerivedFrom() {
    let frontmatter = Self.standupFrontmatter(
      kind: .clean,
      derivedFrom: "2026-07-17/10-30-00_standup.transcript.md"
    )
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])

    let rendered = TranscriptRenderer.renderMarkdown(document)
    let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    #expect(lines[1] == "schema: 1")
    #expect(lines[2] == "kind: clean")
    #expect(lines[3] == "derived_from: \"2026-07-17/10-30-00_standup.transcript.md\"")
    #expect(lines[4] == "session: 2026-07-17T10-30-00Z_standup")
  }

  @Test("kind: summary renders derived_from after kind")
  func summaryKindWithDerivedFrom() {
    let frontmatter = Self.standupFrontmatter(
      kind: .summary,
      derivedFrom: "2026-07-17/10-30-00_standup.clean.md"
    )
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])

    let rendered = TranscriptRenderer.renderMarkdown(document)
    #expect(
      rendered.contains("kind: summary\nderived_from: \"2026-07-17/10-30-00_standup.clean.md\"\n"))
  }

  @Test("kind: transcript omits derived_from entirely")
  func transcriptKindHasNoDerivedFrom() {
    let document = TranscriptDocument(frontmatter: Self.standupFrontmatter(), segments: [])
    #expect(!TranscriptRenderer.renderMarkdown(document).contains("derived_from"))
  }

  @Test("diarization disabled omits the backend key")
  func diarizationDisabledOmitsBackend() {
    let frontmatter = Self.standupFrontmatter(
      diarization: TranscriptDiarizationInfo(enabled: false)
    )
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])

    #expect(
      TranscriptRenderer.renderMarkdown(document).contains("diarization: { enabled: false }\n"))
  }

  @Test("single segment renders one heading block with no trailing blank turn")
  func singleSegment() {
    let document = TranscriptDocument(
      frontmatter: Self.standupFrontmatter(),
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 0, end: 3, text: "Hello."))
      ]
    )

    let rendered = TranscriptRenderer.renderMarkdown(document)
    #expect(rendered.hasSuffix("## [10:30:00] You\nHello.\n"))
    #expect(!rendered.contains("<!-- source:"))
  }

  @Test("no segments renders frontmatter only, no dangling blank body")
  func noSegments() {
    let document = TranscriptDocument(frontmatter: Self.standupFrontmatter(), segments: [])
    #expect(TranscriptRenderer.renderMarkdown(document).hasSuffix("---\n"))
  }

  @Test("empty vocab renders an empty flow array")
  func emptyVocab() {
    let frontmatter = Self.standupFrontmatter(vocab: [])
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])
    #expect(TranscriptRenderer.renderMarkdown(document).contains("vocab: []\n"))
  }

  @Test("a source id without a colon is not quoted in the sources array")
  func singleSourceNoQuoting() {
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      session: "2026-07-17T10-30-00Z_solo",
      sources: ["mic"],
      range: TimeRange(start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 60)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Instant(secondsSinceEpoch: 60),
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 10,
      vocab: []
    )
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])
    #expect(TranscriptRenderer.renderMarkdown(document).contains("sources: [mic]\n"))
  }
}
