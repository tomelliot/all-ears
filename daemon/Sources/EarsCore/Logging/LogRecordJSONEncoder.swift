import Foundation

/// Encodes a ``LogRecord`` to one line of JSON, matching the record examples
/// in `docs/logging.md` field-for-field.
///
/// This is a hand-rolled encoder rather than `Codable`/`JSONEncoder` because
/// field order must be deterministic and caller-controlled (baseline fields,
/// then context fields in the order they were attached, then `msg` last) —
/// `JSONSerialization`/`Codable` dictionary encoding gives no such guarantee,
/// and stable order is what makes output diffable and `jq`-friendly.
public enum LogRecordJSONEncoder {
  /// Encodes `record` as a single-line JSON object with no trailing newline.
  public static func encode(_ record: LogRecord) -> String {
    var pairs: [String] = [
      pair("ts", jsonString(record.ts.iso8601Milliseconds)),
      pair("level", jsonString(record.level.rawValue)),
      pair("tool", jsonString(record.tool)),
      pair("subsystem", jsonString(record.subsystem)),
      pair("category", jsonString(record.category)),
      pair("pid", String(record.pid)),
      pair("event", jsonString(record.event)),
    ]
    for field in record.fields {
      pairs.append(pair(field.key, jsonValue(field.value)))
    }
    if let msg = record.msg {
      pairs.append(pair("msg", jsonString(msg)))
    }
    return "{" + pairs.joined(separator: ",") + "}"
  }

  /// A `"key":value` pair; `value` must already be valid JSON (a quoted
  /// string, bare number, or `true`/`false`).
  private static func pair(_ key: String, _ jsonEncodedValue: String) -> String {
    "\(jsonString(key)):\(jsonEncodedValue)"
  }

  private static func jsonValue(_ value: LogValue) -> String {
    switch value {
    case .string(let string): jsonString(string)
    case .int(let int): String(int)
    case .double(let double): jsonNumber(double)
    case .bool(let bool): bool ? "true" : "false"
    }
  }

  private static func jsonNumber(_ value: Double) -> String {
    value.isFinite ? String(value) : "null"
  }

  private static func jsonString(_ value: String) -> String {
    var result = "\""
    result.reserveCapacity(value.count + 2)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default:
        if scalar.value < 0x20 {
          result += String(format: "\\u%04x", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    result += "\""
    return result
  }
}
