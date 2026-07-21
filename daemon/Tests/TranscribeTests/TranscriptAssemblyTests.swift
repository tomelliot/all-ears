import EarsCore
import Testing

@testable import transcribe

@Suite("TranscriptAssembly")
struct TranscriptAssemblyTests {
  private let start = Instant(secondsSinceEpoch: 1_784_284_200)

  private var requested: TimeRange { TimeRange(start: start, end: start.advanced(by: 30)) }

  private var model: TranscriptModelInfo {
    TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x")
  }

  @Test("mic maps to the You speaker label")
  func micMapsToYou() {
    #expect(TranscriptAssembly.speakerLabel(for: SourceID("mic")) == "You")
  }

  @Test("a non-mic source is labelled with its own raw source id")
  func nonMicUsesRawSourceID() {
    #expect(
      TranscriptAssembly.speakerLabel(for: SourceID("app:us.zoom.xos")) == "app:us.zoom.xos")
  }

  @Test("segments from multiple sources are merged and ordered by start time")
  func mergesAndOrdersAcrossSources() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(start: 10, end: 12, text: "second"),
        Segment(start: 0, end: 2, text: "first"),
      ])
    let zoom = SourceTranscription(
      sourceID: "app:us.zoom.xos",
      segments: [
        Segment(start: 5, end: 7, text: "middle")
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic"), SourceID("app:us.zoom.xos")],
      transcriptions: [mic, zoom],
      requested: requested,
      sessionIdentifier: "2026-07-17T10-30-00Z_mic",
      model: model,
      generated: start.advanced(by: 40),
      speechSeconds: 6
    )

    #expect(document.segments.map(\.segment.text) == ["first", "middle", "second"])
    #expect(document.segments.map(\.speaker) == ["You", "app:us.zoom.xos", "You"])
  }

  @Test("a mid-turn reply interleaves inside a longer overlapping segment")
  func interleavesOverlappingWordTimedSegments() {
    // The guest speaks one long, continuous, word-timed turn; the mic
    // interjects twice *during* it. Ordering by segment.start alone would
    // emit the whole guest turn first and bury both replies after it.
    let guest = SourceTranscription(
      sourceID: "app:us.zoom.xos",
      segments: [
        Segment(
          start: 0, end: 12, text: "so as I was saying the plan is basically",
          words: [
            WordTiming(text: "so", start: 0, end: 1),
            WordTiming(text: "as", start: 1, end: 2),
            WordTiming(text: "I", start: 2, end: 3),
            WordTiming(text: "was", start: 3, end: 4),
            WordTiming(text: "saying", start: 4, end: 5),
            WordTiming(text: "the", start: 6, end: 7),
            WordTiming(text: "plan", start: 7, end: 8),
            WordTiming(text: "is", start: 9, end: 10),
            WordTiming(text: "basically", start: 10, end: 12),
          ])
      ])
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(
          start: 5, end: 6, text: "right",
          words: [WordTiming(text: "right", start: 5, end: 6)]),
        Segment(
          start: 8, end: 9, text: "makes sense",
          words: [
            WordTiming(text: "makes", start: 8, end: 8.5),
            WordTiming(text: "sense", start: 8.5, end: 9),
          ]),
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("app:us.zoom.xos"), SourceID("mic")],
      transcriptions: [guest, mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 12
    )

    // The guest turn is split around each reply, and the replies land at their
    // own timestamps — a woven conversation, not two monolithic blocks.
    #expect(
      document.segments.map(\.speaker) == [
        "app:us.zoom.xos", "You", "app:us.zoom.xos", "You", "app:us.zoom.xos",
      ])
    #expect(
      document.segments.map(\.segment.text) == [
        "so as I was saying", "right", "the plan", "makes sense", "is basically",
      ])
    // Displayed segments are non-decreasing by start across the whole file.
    let starts = document.segments.map(\.segment.start)
    #expect(starts == starts.sorted())
    #expect(starts == [0, 5, 6, 8, 9])
    // No words are lost or duplicated by the split.
    #expect(document.frontmatter.wordCount == 12)
  }

  @Test("a single word-timed source is not fragmented (byte-identical turns)")
  func singleSourceIsNotSplit() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(
          start: 0, end: 2, text: "hello there",
          words: [
            WordTiming(text: "hello", start: 0, end: 1),
            WordTiming(text: "there", start: 1, end: 2),
          ]),
        Segment(
          start: 3, end: 5, text: "how are you",
          words: [
            WordTiming(text: "how", start: 3, end: 3.5),
            WordTiming(text: "are", start: 3.5, end: 4),
            WordTiming(text: "you", start: 4, end: 5),
          ]),
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 4
    )

    // One turn per original segment, original text preserved verbatim.
    #expect(document.segments.map(\.segment.text) == ["hello there", "how are you"])
    #expect(document.segments.map(\.speaker) == ["You", "You"])
  }

  @Test("two source labels for one upgraded participant coalesce to one speaker")
  func coalescesUpgradedParticipantLabels() {
    // Same person, two source ids across a Meet identity upgrade. The roster's
    // [speakers] map points both at the same display name, so they render as
    // one speaker and never split each other.
    let speakers = [
      "browser:meet:speaker-1": "Priya",
      "browser:meet:spaces-x769r-devices-261": "Priya",
    ]
    let early = SourceTranscription(
      sourceID: "browser:meet:speaker-1",
      segments: [
        Segment(
          start: 0, end: 2, text: "before the upgrade",
          words: [
            WordTiming(text: "before", start: 0, end: 1),
            WordTiming(text: "the", start: 1, end: 1.5),
            WordTiming(text: "upgrade", start: 1.5, end: 2),
          ])
      ])
    let late = SourceTranscription(
      sourceID: "browser:meet:spaces-x769r-devices-261",
      segments: [
        Segment(
          start: 3, end: 5, text: "after the upgrade",
          words: [
            WordTiming(text: "after", start: 3, end: 4),
            WordTiming(text: "the", start: 4, end: 4.5),
            WordTiming(text: "upgrade", start: 4.5, end: 5),
          ])
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [
        SourceID("browser:meet:speaker-1"),
        SourceID("browser:meet:spaces-x769r-devices-261"),
      ],
      transcriptions: [early, late],
      requested: requested,
      sessionIdentifier: "id",
      speakers: speakers,
      model: model,
      generated: start,
      speechSeconds: 4
    )

    #expect(document.segments.map(\.speaker) == ["Priya", "Priya"])
    #expect(document.segments.map(\.segment.text) == ["before the upgrade", "after the upgrade"])
  }

  @Test("word count sums split text words when a segment has no word timings")
  func wordCountFromTextWhenNoWordTimings() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [Segment(start: 0, end: 2, text: "hello there world")])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 2
    )

    #expect(document.frontmatter.wordCount == 3)
  }

  @Test("word count uses word timings when a segment has them, not the text split")
  func wordCountFromWordTimingsWhenPresent() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(
          start: 0, end: 2, text: "hello there",
          words: [
            WordTiming(text: "hello", start: 0, end: 1),
            WordTiming(text: "there", start: 1, end: 2),
          ])
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 2
    )

    #expect(document.frontmatter.wordCount == 2)
  }

  @Test("frontmatter fields carry through unchanged from the given parameters")
  func frontmatterFieldsCarryThrough() {
    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [],
      requested: requested,
      sessionIdentifier: "2026-07-17T10-30-00Z_mic",
      model: model,
      generated: start.advanced(by: 40),
      speechSeconds: 12
    )

    #expect(document.frontmatter.schema == 1)
    #expect(document.frontmatter.kind == .transcript)
    #expect(document.frontmatter.session == "2026-07-17T10-30-00Z_mic")
    #expect(document.frontmatter.sources == [SourceID("mic")])
    #expect(document.frontmatter.range == requested)
    #expect(document.frontmatter.model == model)
    #expect(document.frontmatter.diarization == TranscriptDiarizationInfo(enabled: false))
    #expect(document.frontmatter.generated == start.advanced(by: 40))
    #expect(document.frontmatter.durationSeconds == 30)
    #expect(document.frontmatter.speechSeconds == 12)
    #expect(document.frontmatter.vocab.isEmpty)
  }
}
