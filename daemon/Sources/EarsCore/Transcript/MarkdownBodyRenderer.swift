/// Renders the Markdown body — the sequence of speaker-turn headings and text
/// below the frontmatter — from an ordered list of ``TranscriptSegment``.
///
/// Each `TranscriptSegment` is already one turn (see its doc comment); this
/// renderer's only job is formatting: a `## [HH:MM:SS] <speaker>` heading
/// (optionally with a `<!-- source: ... -->` provenance comment), a newline,
/// then the segment text, with turns separated by a blank line — matching
/// `docs/data-formats.md`'s example byte-for-byte.
enum MarkdownBodyRenderer {
  static func render(_ segments: [TranscriptSegment], rangeStart: Instant) -> String {
    segments.map { renderTurn($0, rangeStart: rangeStart) }.joined(separator: "\n\n")
  }

  private static func renderTurn(_ turn: TranscriptSegment, rangeStart: Instant) -> String {
    let headingInstant = rangeStart.advanced(by: turn.segment.start)
    let time = UTCCalendar.timeOfDay(headingInstant)

    var heading = "## [\(time)] \(turn.speaker)"
    if turn.sourceProvenance {
      heading += "  <!-- source: \(turn.source.rawValue) -->"
    }

    return heading + "\n" + turn.segment.text
  }
}
