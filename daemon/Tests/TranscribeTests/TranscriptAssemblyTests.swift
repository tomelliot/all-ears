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
