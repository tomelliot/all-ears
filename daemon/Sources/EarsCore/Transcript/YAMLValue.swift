/// Minimal, hand-written YAML emitter scoped exactly to the transcript
/// frontmatter schema in `docs/data-formats.md` — a fixed set of top-level
/// keys in block style (one `key: value` per line), whose values are plain or
/// quoted scalars, flow arrays (`[a, b]`), or one level of flow mapping
/// (`{ k: v, k2: v2 }`). This is deliberately not a general YAML encoder: it
/// has no notion of block sequences/mappings, anchors, multi-line scalars, or
/// arbitrary nesting depth, because the frontmatter schema needs none of that.
enum YAML {
  /// A value restricted to what frontmatter needs. `.plain` is emitted
  /// verbatim — the caller vouches it is already YAML-safe (e.g. digits, or
  /// a known-safe identifier/timestamp) — while `.quoted` always
  /// double-quotes with minimal escaping.
  indirect enum Value {
    case plain(String)
    case quoted(String)
    case flowArray([Value])
    /// Key/value pairs for a one-level flow mapping. A `nil` value omits
    /// that key entirely (used for `diarization`'s optional `backend`).
    case flowMapping([(key: String, value: Value?)])
  }

  /// Renders `key: <value>`, the one shape a frontmatter line takes.
  static func line(_ key: String, _ value: Value) -> String {
    "\(key): \(render(value))"
  }

  static func render(_ value: Value) -> String {
    switch value {
    case .plain(let string):
      return string
    case .quoted(let string):
      return quote(string)
    case .flowArray(let items):
      return "[" + items.map(render).joined(separator: ", ") + "]"
    case .flowMapping(let pairs):
      let rendered = pairs.compactMap { pair -> String? in
        guard let value = pair.value else { return nil }
        return "\(pair.key): \(render(value))"
      }
      guard !rendered.isEmpty else { return "{}" }
      return "{ " + rendered.joined(separator: ", ") + " }"
    }
  }

  /// Double-quotes `string`, escaping backslashes and double quotes. The
  /// frontmatter schema's quoted fields (source ids, versions, free-form
  /// names) are plain text, not YAML documents in their own right, so this
  /// minimal escaping — not full YAML quoted-scalar folding — is sufficient.
  private static func quote(_ string: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(string.count + 2)
    for character in string {
      switch character {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      default: escaped.append(character)
      }
    }
    return "\"\(escaped)\""
  }
}
