/// Renders a ``LogRecord`` as a single human-readable line for interactive
/// (TTY) use.
///
/// Per `docs/logging.md`, the pretty format is a rendering of the JSON
/// record, not a separate format — it carries the same fields, just laid out
/// for a terminal instead of `jq`. Layout: `ts [LEVEL] tool/category event
/// key=value key=value - msg`.
public enum LogRecordPrettyRenderer {
  public static func render(_ record: LogRecord) -> String {
    var line =
      "\(record.ts.iso8601Milliseconds) [\(record.level.rawValue.uppercased())] "
      + "\(record.tool)/\(record.category) \(record.event)"

    if !record.fields.isEmpty {
      let rendered = record.fields.map { "\($0.key)=\(renderValue($0.value))" }
        .joined(separator: " ")
      line += " \(rendered)"
    }

    if let msg = record.msg {
      line += " - \(msg)"
    }

    return line
  }

  private static func renderValue(_ value: LogValue) -> String {
    switch value {
    case .string(let string): string.contains(" ") ? "\"\(string)\"" : string
    case .int(let int): String(int)
    case .double(let double): String(double)
    case .bool(let bool): bool ? "true" : "false"
    }
  }
}
