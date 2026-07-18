import Foundation
import Testing

@testable import EarsCore

/// Covers the canonical JSON sidecar schema from `docs/data-formats.md`'s
/// "Transcript format" section: `{"schema":1,"segments":[{"start":...,
/// "end":...,"source":...,"speaker":...,"text":...,"words":[{"w":...,
/// "start":...,"end":...,"conf":...}]}]}`.
@Suite("TranscriptRenderer — JSON sidecar")
struct TranscriptSidecarJSONTests {
  private static func document(segments: [TranscriptSegment]) -> TranscriptDocument {
    TranscriptDocument(
      frontmatter: TranscriptFrontmatter(
        schema: 1,
        kind: .transcript,
        session: "2026-07-17T10-30-00Z_standup",
        sources: ["mic", "app:us.zoom.xos"],
        range: TimeRange(
          start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 1920)),
        model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
        diarization: TranscriptDiarizationInfo(enabled: true, backend: "pyannote"),
        generated: Instant(secondsSinceEpoch: 1920),
        durationSeconds: 1920,
        speechSeconds: 1440,
        wordCount: 3120,
        vocab: ["global", "standup"]
      ),
      segments: segments
    )
  }

  @Test("renders the doc's example segment with a word timing and confidence")
  func docExampleSegment() {
    let segment = TranscriptSegment(
      source: "app:us.zoom.xos",
      speaker: "Speaker 2",
      segment: Segment(
        start: 604.14,
        end: 611.88,
        text: "Nothing from me, the deploy went out last night.",
        words: [
          WordTiming(text: "Nothing", start: 604.14, end: 604.51, confidence: 0.98)
        ]
      ),
      sourceProvenance: true
    )

    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: [segment]))

    let expected = """
      {
        "schema": 1,
        "segments": [
          {
            "start": 604.14,
            "end": 611.88,
            "source": "app:us.zoom.xos",
            "speaker": "Speaker 2",
            "text": "Nothing from me, the deploy went out last night.",
            "words": [
              {
                "w": "Nothing",
                "start": 604.14,
                "end": 604.51,
                "conf": 0.98
              }
            ]
          }
        ]
      }

      """
    #expect(rendered == expected)
  }

  @Test("a word with no confidence omits the conf key")
  func wordWithoutConfidence() {
    let segment = TranscriptSegment(
      source: "mic",
      speaker: "You",
      segment: Segment(
        start: 0,
        end: 1,
        text: "Hi.",
        words: [WordTiming(text: "Hi.", start: 0, end: 1)]
      )
    )

    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: [segment]))
    #expect(rendered.contains("\"w\": \"Hi.\""))
    #expect(!rendered.contains("conf"))
  }

  @Test("a segment with no word timings renders an empty words array")
  func emptyWords() {
    let segment = TranscriptSegment(
      source: "mic",
      speaker: "You",
      segment: Segment(start: 0, end: 1, text: "Hi.")
    )

    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: [segment]))
    #expect(rendered.contains("\"words\": []"))
  }

  @Test("no segments renders an empty segments array")
  func noSegments() {
    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: []))
    #expect(rendered.contains("\"segments\": []"))
  }

  @Test("multiple segments render in order as separate array entries")
  func multipleSegments() throws {
    let segments = [
      TranscriptSegment(
        source: "mic", speaker: "You", segment: Segment(start: 0, end: 1, text: "One.")),
      TranscriptSegment(
        source: "app:us.zoom.xos",
        speaker: "Speaker 2",
        segment: Segment(start: 1, end: 2, text: "Two."),
        sourceProvenance: true
      ),
    ]

    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: segments))
    let firstRange = rendered.range(of: "\"text\": \"One.\"")
    let secondRange = rendered.range(of: "\"text\": \"Two.\"")
    let first = try #require(firstRange)
    let second = try #require(secondRange)
    #expect(first.lowerBound < second.lowerBound)
  }

  @Test("segment-level confidence is not part of the sidecar schema")
  func segmentConfidenceDropped() {
    let segment = TranscriptSegment(
      source: "mic",
      speaker: "You",
      segment: Segment(start: 0, end: 1, text: "Hi.", confidence: 0.5)
    )
    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: [segment]))
    #expect(!rendered.contains("0.5"))
  }

  @Test("special characters in text are escaped")
  func escapesSpecialCharacters() {
    let segment = TranscriptSegment(
      source: "mic",
      speaker: "You",
      segment: Segment(start: 0, end: 1, text: "She said \"hi\" \\ ok")
    )
    let rendered = TranscriptRenderer.renderJSON(Self.document(segments: [segment]))
    #expect(rendered.contains("She said \\\"hi\\\" \\\\ ok"))
  }
}
