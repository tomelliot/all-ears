/// Minimal, hand-written JSON pretty-printer used to render the canonical
/// transcript sidecar (`docs/data-formats.md`). `EarsCore` stays
/// `Foundation`-free, so this does not use `JSONEncoder`/`JSONSerialization`;
/// it also gives full control over key order and number formatting, which
/// `JSONEncoder`'s dictionary-backed encoding does not guarantee.
indirect enum JSONValue {
  case string(String)
  case number(Double)
  case int(Int)
  case bool(Bool)
  case array([JSONValue])
  /// Ordered key/value pairs — a `[String: JSONValue]` would lose the field
  /// order the sidecar schema is documented with.
  case object([(key: String, value: JSONValue)])
}

enum JSON {
  static func render(_ value: JSONValue, indentLevel: Int = 0) -> String {
    switch value {
    case .string(let string):
      return encode(string)
    case .number(let double):
      return RenderNumber.string(double)
    case .int(let int):
      return String(int)
    case .bool(let bool):
      return bool ? "true" : "false"
    case .array(let items):
      guard !items.isEmpty else { return "[]" }
      let inner =
        items
        .map { pad(indentLevel + 1) + render($0, indentLevel: indentLevel + 1) }
        .joined(separator: ",\n")
      return "[\n\(inner)\n\(pad(indentLevel))]"
    case .object(let pairs):
      guard !pairs.isEmpty else { return "{}" }
      let inner =
        pairs
        .map {
          pad(indentLevel + 1) + encode($0.key) + ": "
            + render($0.value, indentLevel: indentLevel + 1)
        }
        .joined(separator: ",\n")
      return "{\n\(inner)\n\(pad(indentLevel))}"
    }
  }

  private static func pad(_ level: Int) -> String {
    String(repeating: "  ", count: level)
  }

  private static func encode(_ string: String) -> String {
    var out = "\""
    out.reserveCapacity(string.count + 2)
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += "\\u" + hex4(scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
    return out
  }

  private static func hex4(_ value: UInt32) -> String {
    let hex = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
  }
}
