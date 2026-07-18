/// Public entry point for transcript rendering: pure `TranscriptDocument` →
/// `String`, matching `docs/data-formats.md`'s "Transcript format" section.
/// Consumed by `transcribe` (kind `.transcript`), `cleanup` (kind `.clean`),
/// and `summarize` (kind `.summary`) — the same renderer for all three, since
/// they differ only in `kind` and the optional `derived_from` field (see
/// ``TranscriptFrontmatter``).
public enum TranscriptRenderer {
  /// Renders the human-first Markdown-with-YAML-frontmatter document.
  public static func renderMarkdown(_ document: TranscriptDocument) -> String {
    let frontmatter = FrontmatterRenderer.render(document.frontmatter)
    var result = "---\n\(frontmatter)\n---\n"

    if !document.segments.isEmpty {
      let body = MarkdownBodyRenderer.render(
        document.segments, rangeStart: document.frontmatter.range.start)
      result += "\n\(body)\n"
    }

    return result
  }

  /// Renders the canonical `.transcript.json` sidecar.
  public static func renderJSON(_ document: TranscriptDocument) -> String {
    SidecarJSONRenderer.render(document.segments)
  }
}
