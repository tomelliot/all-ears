/// Renders a ``TranscriptFrontmatter`` to the YAML block shown in
/// `docs/data-formats.md`, in exactly the field order the doc shows (with
/// `derived_from` inserted right after `kind` when present, since that's the
/// only field the doc mentions without pinning a position — see
/// ``TranscriptFrontmatter/derivedFrom``). Does not include the surrounding
/// `---` fences; ``TranscriptRenderer`` owns document-level assembly.
enum FrontmatterRenderer {
  static func render(_ frontmatter: TranscriptFrontmatter) -> String {
    var lines: [String] = []

    lines.append(YAML.line("schema", .plain(String(frontmatter.schema))))
    lines.append(YAML.line("kind", .plain(frontmatter.kind.rawValue)))
    if let preset = frontmatter.preset {
      lines.append(YAML.line("preset", scalar(preset)))
    }
    if let derivedFrom = frontmatter.derivedFrom {
      lines.append(YAML.line("derived_from", scalar(derivedFrom)))
    }
    lines.append(YAML.line("session", .plain(frontmatter.session)))
    lines.append(YAML.line("sources", .flowArray(frontmatter.sources.map(sourceValue))))
    lines.append(
      YAML.line(
        "range",
        .flowMapping([
          ("start", .plain(UTCCalendar.iso8601(frontmatter.range.start))),
          ("end", .plain(UTCCalendar.iso8601(frontmatter.range.end))),
        ])
      )
    )
    lines.append(
      YAML.line(
        "model",
        .flowMapping([
          ("name", scalar(frontmatter.model.name)),
          ("backend", scalar(frontmatter.model.backend)),
          ("version", .quoted(frontmatter.model.version)),
        ])
      )
    )
    lines.append(
      YAML.line(
        "diarization",
        .flowMapping([
          ("enabled", .plain(frontmatter.diarization.enabled ? "true" : "false")),
          ("backend", frontmatter.diarization.backend.map(scalar)),
        ])
      )
    )
    lines.append(YAML.line("generated", .plain(UTCCalendar.iso8601(frontmatter.generated))))
    lines.append(
      YAML.line("duration_seconds", .plain(RenderNumber.string(frontmatter.durationSeconds))))
    lines.append(
      YAML.line("speech_seconds", .plain(RenderNumber.string(frontmatter.speechSeconds))))
    lines.append(YAML.line("word_count", .plain(String(frontmatter.wordCount))))
    lines.append(YAML.line("vocab", .flowArray(frontmatter.vocab.map(scalar))))

    return lines.joined(separator: "\n")
  }

  /// `SourceID`s are quoted only when they contain `:` (i.e. `app:`/
  /// `browser:`/`device:` sources) — matching `sources: [mic,
  /// "app:us.zoom.xos"]` in `docs/data-formats.md`, where the bare `mic`
  /// source needs no quoting.
  private static func sourceValue(_ id: SourceID) -> YAML.Value {
    id.rawValue.contains(":") ? .quoted(id.rawValue) : .plain(id.rawValue)
  }

  /// Quotes a free-form string scalar when leaving it bare could be
  /// ambiguous to a YAML parser: empty, flow/quote-significant characters,
  /// leading/trailing whitespace, a leading digit (numbers, dates, and
  /// version-like strings such as `"0.x"` all start with a digit), or a
  /// YAML reserved word. Fields with a known-safe shape (the session id,
  /// `kind`, numeric fields) bypass this and render `.plain` directly.
  private static func scalar(_ string: String) -> YAML.Value {
    needsQuoting(string) ? .quoted(string) : .plain(string)
  }

  private static let specialCharacters: Set<Character> = [
    ":", ",", "#", "[", "]", "{", "}", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
  ]
  private static let reservedWords: Set<String> = ["true", "false", "null", "~", "yes", "no"]

  private static func needsQuoting(_ string: String) -> Bool {
    guard let first = string.first else { return true }
    if string.contains(where: { specialCharacters.contains($0) }) { return true }
    if first == " " || string.last == " " { return true }
    if first.isNumber { return true }
    if reservedWords.contains(string.lowercased()) { return true }
    return false
  }
}
