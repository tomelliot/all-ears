/// Edits a single field in an already-written transcript's frontmatter block,
/// leaving the rest of the document byte-identical.
///
/// The alternative — parse the document, set the field, re-render — would put
/// every one of a long transcript's turns through a parse/render round trip to
/// change one line, and any imperfection in that round trip would rewrite the
/// body of a file the pipeline is otherwise finished with. `summarize` stamps
/// its back-link into a transcript it has already published and must not
/// disturb, so it edits the YAML block as text and never touches the body.
public enum TranscriptFrontmatterEditor {
  /// Returns `markdown` with `note:` set to `target`, replacing an existing
  /// `note:` line or inserting one if there is none.
  ///
  /// The insertion point mirrors ``FrontmatterRenderer``'s field order, so a
  /// stamped document and a freshly rendered one agree line for line: after
  /// `title:` where there is one, else after `session:`, else after `kind:`,
  /// else at the end of the block.
  ///
  /// A document with no frontmatter block gets one holding just this field.
  /// That is not the same act as inventing capture metadata: a link to a note
  /// derived from this file is a fact about the file, known for certain at the
  /// moment it is written, and a foreign transcript with no YAML header is the
  /// case that most needs it — nothing else records where its summary went.
  public static func settingNote(_ target: String, in markdown: String) -> String {
    let line = FrontmatterRenderer.line("note", target)
    return replacingOrInserting(
      line, key: "note", after: ["title", "session", "kind"], in: markdown)
  }

  /// Returns `markdown` with `session:` set to `id`, replacing an existing
  /// `session:` line or inserting one if there is none.
  ///
  /// For the note `summarize` writes, whose frontmatter the LLM composes: the
  /// session id is the one field that must be exact, and it is what leads
  /// from a note back to the session's audio and logs. Inserted after
  /// `transcript:` where there is one, else after `title:`, else at the end
  /// of the block. A note with no frontmatter block would get one holding
  /// just this field; `summarize` checks ``hasFrontmatterBlock(_:)`` first.
  public static func settingSession(_ id: String, in markdown: String) -> String {
    let line = FrontmatterRenderer.line("session", id)
    return replacingOrInserting(
      line, key: "session", after: ["transcript", "title"], in: markdown)
  }

  private static func replacingOrInserting(
    _ line: String, key: String, after anchors: [String], in markdown: String
  ) -> String {
    // Empties kept: the block's exact line structure is what gets rebuilt, and
    // a trailing newline must survive the round trip as the empty final
    // element it is — a document that ended without one must not gain one.
    var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first == "---", let closing = lines.dropFirst().firstIndex(of: "---") else {
      return "---\n\(line)\n---\n\(markdown)"
    }
    let block = 1..<closing

    if let existing = lines[block].firstIndex(where: { isField(key, $0) }) {
      lines[existing] = line
      return lines.joined(separator: "\n")
    }
    for anchor in anchors {
      if let index = lines[block].lastIndex(where: { isField(anchor, $0) }) {
        lines.insert(line, at: index + 1)
        return lines.joined(separator: "\n")
      }
    }
    lines.insert(line, at: closing)
    return lines.joined(separator: "\n")
  }

  /// Whether `markdown` opens with a frontmatter block at all — the one thing
  /// ``settingNote(_:in:)`` changes structurally rather than in place.
  public static func hasFrontmatterBlock(_ markdown: String) -> Bool {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.first == "---" && lines.dropFirst().contains("---")
  }

  /// Whether `line` is the top-level frontmatter field `key`. Top-level only:
  /// a nested `note:` inside a future block mapping is somebody else's field,
  /// and leading whitespace is what distinguishes the two.
  private static func isField(_ key: String, _ line: String) -> Bool {
    line.hasPrefix("\(key):")
  }
}
