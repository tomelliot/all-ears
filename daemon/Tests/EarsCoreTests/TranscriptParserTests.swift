import Testing

@testable import EarsCore

/// Round-trips ``TranscriptParser`` against ``TranscriptRenderer``'s own
/// output — the write direction is already pinned byte-for-byte in
/// `TranscriptRenderingTests`, so this suite proves the read direction
/// recovers the same document, plus the parser's own edge cases.
@Suite("TranscriptParser")
struct TranscriptParserTests {
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
      segment: Segment(
        start: 4, end: 10, text: "Morning — let's keep this quick. Any blockers?",
        words: [WordTiming(text: "Morning", start: 4, end: 4.5, confidence: 0.9)])
    ),
    TranscriptSegment(
      source: "app:us.zoom.xos",
      speaker: "Speaker 2",
      segment: Segment(
        start: 11, end: 18, text: "Nothing from me, the deploy went out last night."),
      sourceProvenance: true
    ),
  ]

  @Test("round-trips frontmatter + full-fidelity segments via the JSON sidecar")
  func roundTripsViaJSONSidecar() throws {
    let document = TranscriptDocument(
      frontmatter: Self.standupFrontmatter(), segments: Self.standupSegments)
    let markdown = TranscriptRenderer.renderMarkdown(document)
    let json = TranscriptRenderer.renderJSON(document)

    let parsed = try TranscriptParser.parse(markdown: markdown, jsonSidecar: json)

    #expect(parsed.frontmatter == document.frontmatter)
    // sourceProvenance is recovered from the Markdown body's `<!-- source:
    // ... -->` comments (the JSON sidecar itself never carries it — see the
    // parser's "Known lossy fields" doc), so a full round trip needs both.
    #expect(parsed.segments == document.segments)
  }

  @Test("parseJSONSidecar alone (no Markdown) always reports sourceProvenance == false")
  func jsonSidecarAloneLosesSourceProvenance() throws {
    let document = TranscriptDocument(
      frontmatter: Self.standupFrontmatter(), segments: Self.standupSegments)
    let json = TranscriptRenderer.renderJSON(document)

    let parsed = try TranscriptParser.parseJSONSidecar(json)
    #expect(parsed.allSatisfy { !$0.sourceProvenance })
  }

  @Test("Markdown-only fallback recovers source/speaker/text/start, zero-duration, no words")
  func markdownOnlyFallbackIsLossy() throws {
    let document = TranscriptDocument(
      frontmatter: Self.standupFrontmatter(), segments: Self.standupSegments)
    let markdown = TranscriptRenderer.renderMarkdown(document)

    let parsed = try TranscriptParser.parse(markdown: markdown, jsonSidecar: nil)

    #expect(parsed.frontmatter == document.frontmatter)
    #expect(parsed.segments.count == document.segments.count)
    for (parsedSegment, original) in zip(parsed.segments, document.segments) {
      #expect(parsedSegment.source == original.source)
      #expect(parsedSegment.speaker == original.speaker)
      #expect(parsedSegment.segment.text == original.segment.text)
      #expect(parsedSegment.segment.start == original.segment.start)
      #expect(parsedSegment.segment.end == parsedSegment.segment.start)
      #expect(parsedSegment.segment.words.isEmpty)
      #expect(parsedSegment.sourceProvenance == original.sourceProvenance)
    }
  }

  @Test("parsed segment confidence is always nil, even when the original had one")
  func confidenceIsAlwaysLostOnReRead() throws {
    let confidentSegments = [
      TranscriptSegment(
        source: "mic", speaker: "You",
        segment: Segment(start: 0, end: 3, text: "Hello.", confidence: 0.99))
    ]
    let document = TranscriptDocument(
      frontmatter: Self.standupFrontmatter(), segments: confidentSegments)
    let markdown = TranscriptRenderer.renderMarkdown(document)
    let json = TranscriptRenderer.renderJSON(document)

    let parsed = try TranscriptParser.parse(markdown: markdown, jsonSidecar: json)
    #expect(parsed.segments[0].segment.confidence == nil)
  }

  @Test("round-trips preset + derived_from for kind: summary")
  func roundTripsPresetAndDerivedFrom() throws {
    let frontmatter = Self.standupFrontmatter(
      kind: .summary, derivedFrom: "2026-07-17/10-30-00_standup.clean.md")
    var withPreset = frontmatter
    withPreset.preset = "brief"
    let document = TranscriptDocument(frontmatter: withPreset, segments: [])
    let markdown = TranscriptRenderer.renderMarkdown(document)

    #expect(markdown.contains("kind: summary\npreset: brief\nderived_from:"))
    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.preset == "brief")
    #expect(parsed.derivedFrom == "2026-07-17/10-30-00_standup.clean.md")
  }

  @Test("round-trips derived_from for kind: clean")
  func roundTripsDerivedFrom() throws {
    let frontmatter = Self.standupFrontmatter(
      kind: .clean, derivedFrom: "2026-07-17/10-30-00_standup.transcript.md")
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])
    let markdown = TranscriptRenderer.renderMarkdown(document)

    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.kind == .clean)
    #expect(parsed.derivedFrom == "2026-07-17/10-30-00_standup.transcript.md")
  }

  @Test("round-trips diarization disabled (no backend key)")
  func roundTripsDiarizationDisabled() throws {
    let frontmatter = Self.standupFrontmatter(
      diarization: TranscriptDiarizationInfo(enabled: false))
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])
    let markdown = TranscriptRenderer.renderMarkdown(document)

    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.diarization == TranscriptDiarizationInfo(enabled: false))
  }

  @Test("round-trips the per-source audio_stores record for a --meeting transcript")
  func roundTripsAudioStores() throws {
    var frontmatter = Self.standupFrontmatter()
    frontmatter.meeting = "0d5e-meeting"
    frontmatter.audioStores = [
      TranscriptAudioStore(source: "mic", store: "ring"),
      TranscriptAudioStore(source: "browser:meet:speaker-1", store: "meeting"),
      TranscriptAudioStore(source: "system", store: "none"),
    ]
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])
    let markdown = TranscriptRenderer.renderMarkdown(document)

    #expect(
      markdown.contains(
        "audio_stores: [\"mic=ring\", \"browser:meet:speaker-1=meeting\", \"system=none\"]"))
    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.audioStores == frontmatter.audioStores)
  }

  @Test("a transcript with no audio_stores line parses to an empty record")
  func absentAudioStoresParsesEmpty() throws {
    let document = TranscriptDocument(frontmatter: Self.standupFrontmatter(), segments: [])
    let markdown = TranscriptRenderer.renderMarkdown(document)

    #expect(!markdown.contains("audio_stores"))
    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.audioStores.isEmpty)
  }

  @Test("round-trips empty vocab")
  func roundTripsEmptyVocab() throws {
    let frontmatter = Self.standupFrontmatter(vocab: [])
    let document = TranscriptDocument(frontmatter: frontmatter, segments: [])
    let markdown = TranscriptRenderer.renderMarkdown(document)

    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.vocab == [])
  }

  @Test("round-trips a single unquoted (no-colon) source id")
  func roundTripsUnquotedSource() throws {
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
    let markdown = TranscriptRenderer.renderMarkdown(document)

    let parsed = try TranscriptParser.parseFrontmatter(markdown)
    #expect(parsed.sources == ["mic"])
  }

  @Test("throws missingFrontmatterFences for a document with no frontmatter")
  func missingFences() {
    #expect(throws: TranscriptParsingError.missingFrontmatterFences) {
      _ = try TranscriptParser.parseFrontmatter("no frontmatter here")
    }
  }

  @Test("throws missingField for a frontmatter missing a required field")
  func missingRequiredField() {
    let markdown = "---\nschema: 1\nkind: transcript\n---\n"
    #expect(throws: TranscriptParsingError.self) {
      _ = try TranscriptParser.parseFrontmatter(markdown)
    }
  }

  @Test("throws malformedJSON for a sidecar missing the segments array")
  func malformedSidecar() {
    #expect(throws: TranscriptParsingError.self) {
      _ = try TranscriptParser.parseJSONSidecar("{\"schema\": 1}")
    }
  }
}
