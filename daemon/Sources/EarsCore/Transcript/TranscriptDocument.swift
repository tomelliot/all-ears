/// A full transcript document: frontmatter plus the ordered turns that make up
/// the Markdown body and the JSON sidecar. Both renderings come from this one
/// value, which is how `docs/data-formats.md` guarantees they never disagree.
public struct TranscriptDocument: Sendable, Hashable {
  public var frontmatter: TranscriptFrontmatter
  public var segments: [TranscriptSegment]

  public init(frontmatter: TranscriptFrontmatter, segments: [TranscriptSegment]) {
    self.frontmatter = frontmatter
    self.segments = segments
  }
}
