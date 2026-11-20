import Testing

@testable import EarsCore

@Suite("TranscriptFrontmatterEditor")
struct TranscriptFrontmatterEditorTests {
  private static let transcript = """
    ---
    schema: 1
    kind: transcript
    session: d6a76df1-ac69-44da-8043-a534868d780d
    title: meet 96DC3F7J7x0B
    started: 2026-08-12T07:01:13Z
    sources: [mic, "browser:meet:webaudio-track-1"]
    word_count: 11593
    ---

    **[07:01:53] Tom Elliot**
    Nice to meet you.

    """

  private static let link = "[[daily-notes/2026/08/33/2026-08-12/2026-08-12 - Alan Bradburne.md]]"

  @Test("note: is inserted after title:, quoted, with the body untouched")
  func insertsAfterTitle() throws {
    let updated = TranscriptFrontmatterEditor.settingNote(Self.link, in: Self.transcript)

    #expect(
      updated.contains(
        """
        title: meet 96DC3F7J7x0B
        note: "[[daily-notes/2026/08/33/2026-08-12/2026-08-12 - Alan Bradburne.md]]"
        started: 2026-08-12T07:01:13Z
        """))
    // Everything from the closing fence down is byte-identical.
    let body = "---\n\n**[07:01:53] Tom Elliot**\nNice to meet you.\n"
    #expect(updated.hasSuffix(body))
    #expect(updated.count == Self.transcript.count + 1 + "note: \"\(Self.link)\"".count)
  }

  @Test("a second stamp replaces the first rather than accumulating")
  func replacesExisting() throws {
    let once = TranscriptFrontmatterEditor.settingNote(Self.link, in: Self.transcript)
    let twice = TranscriptFrontmatterEditor.settingNote("[[other.md]]", in: once)

    #expect(twice.contains("note: \"[[other.md]]\""))
    #expect(!twice.contains("Alan Bradburne"))
    #expect(once.count - Self.link.count == twice.count - "[[other.md]]".count)
  }

  @Test("with no title:, note: falls back to after session:, then kind:")
  func insertionFallbacks() throws {
    let noTitle = """
      ---
      schema: 1
      kind: transcript
      session: abc
      word_count: 3
      ---
      body
      """
    #expect(
      TranscriptFrontmatterEditor.settingNote("[[n.md]]", in: noTitle)
        .contains("session: abc\nnote: \"[[n.md]]\"\nword_count: 3"))

    let kindOnly = """
      ---
      schema: 1
      kind: transcript
      word_count: 3
      ---
      body
      """
    #expect(
      TranscriptFrontmatterEditor.settingNote("[[n.md]]", in: kindOnly)
        .contains("kind: transcript\nnote: \"[[n.md]]\"\nword_count: 3"))
  }

  @Test("a document with no frontmatter block gets one holding just the link")
  func createsBlockWhereThereIsNone() {
    // A foreign transcript — a Granola-style export, say — opens straight
    // into its body. It is also the case that most needs the link: nothing
    // else in the file records where its summary went.
    let foreign = "**You**\n*00:07*\nSo that hardware in the loop…\n"
    #expect(
      TranscriptFrontmatterEditor.settingNote("[[n.md]]", in: foreign)
        == "---\nnote: \"[[n.md]]\"\n---\n\(foreign)")
    // An unterminated fence is not a block, and is left as body text rather
    // than being "closed" into something the author never wrote.
    #expect(
      TranscriptFrontmatterEditor.settingNote("[[n.md]]", in: "---\nschema: 1\nunclosed\n")
        .hasPrefix("---\nnote: \"[[n.md]]\"\n---\n---\nschema: 1"))
    #expect(!TranscriptFrontmatterEditor.hasFrontmatterBlock(foreign))
    #expect(TranscriptFrontmatterEditor.hasFrontmatterBlock(Self.transcript))
  }

  @Test("stamping a document with no block twice replaces, rather than stacking blocks")
  func createdBlockIsStampedInPlaceNextTime() {
    let foreign = "**You**\n*00:07*\nHello.\n"
    let once = TranscriptFrontmatterEditor.settingNote("[[a.md]]", in: foreign)
    let twice = TranscriptFrontmatterEditor.settingNote("[[b.md]]", in: once)

    #expect(twice == "---\nnote: \"[[b.md]]\"\n---\n\(foreign)")
  }

  @Test("a stamped transcript round-trips through the parser and renderer")
  func roundTripsThroughParseAndRender() throws {
    // A rendered document, not the abbreviated literal above: this asserts on
    // the real schema, which the parser holds to its required fields.
    let start = Instant(secondsSinceEpoch: 1_786_518_073)
    let rendered = TranscriptRenderer.renderMarkdown(
      TranscriptDocument(
        frontmatter: TranscriptFrontmatter(
          schema: 1,
          kind: .clean,
          session: "d6a76df1-ac69-44da-8043-a534868d780d",
          title: "meet 96DC3F7J7x0B",
          started: start,
          sources: ["mic"],
          range: TimeRange(start: start, end: start.advanced(by: 3347)),
          model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
          diarization: TranscriptDiarizationInfo(enabled: false),
          generated: start.advanced(by: 4000),
          durationSeconds: 3347,
          speechSeconds: 3000,
          wordCount: 5,
          vocab: []),
        segments: [
          TranscriptSegment(
            source: "mic", speaker: "Tom Elliot",
            segment: Segment(start: 40, end: 41, text: "Nice to meet you."))
        ]))
    let updated = TranscriptFrontmatterEditor.settingNote(Self.link, in: rendered)
    let parsed = try TranscriptParser.parse(markdown: updated, jsonSidecar: nil)

    #expect(parsed.frontmatter.note == Self.link)
    // A later `cleanup` pass re-renders from the parsed document — the link
    // has to survive that, not just the splice that wrote it.
    #expect(TranscriptRenderer.renderMarkdown(parsed).contains("note: \"\(Self.link)\""))
  }

  @Test("session: is inserted after transcript:, and a second stamp replaces the first")
  func stampsSessionIntoANote() throws {
    let note = """
      ---
      title: Jan Oberhauser
      type: note
      transcript: "[[Transcripts/2026/11/19/2026-11-19 - Jan Oberhauser.md]]"
      ---

      ### Background

      """
    let once = TranscriptFrontmatterEditor.settingSession(
      "d74b62b0-a704-4aac-bca8-840a153f4350", in: note)
    #expect(
      once.contains(
        """
        transcript: "[[Transcripts/2026/11/19/2026-11-19 - Jan Oberhauser.md]]"
        session: d74b62b0-a704-4aac-bca8-840a153f4350
        ---
        """))
    #expect(once.hasSuffix("---\n\n### Background\n"))

    let twice = TranscriptFrontmatterEditor.settingSession("other-id", in: once)
    #expect(twice.contains("session: other-id\n"))
    #expect(!twice.contains("d74b62b0"))
  }

  @Test("with no transcript:, session: falls back to after title:, then the end of the block")
  func sessionFallbackAnchors() throws {
    #expect(
      TranscriptFrontmatterEditor.settingSession(
        "abc", in: "---\ntitle: T\ntype: note\n---\nBody\n")
        == "---\ntitle: T\nsession: abc\ntype: note\n---\nBody\n")
    #expect(
      TranscriptFrontmatterEditor.settingSession("abc", in: "---\ntype: note\n---\nBody\n")
        == "---\ntype: note\nsession: abc\n---\nBody\n")
  }
}
