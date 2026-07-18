/// A structured log context value: a small closed set of the JSON scalar types
/// context fields need (`docs/logging.md`'s "anything actionable lives in a
/// field"), so call sites attach typed data without stringly-typed hacks.
///
/// Deliberately excludes arrays/objects/null — every record example in the doc
/// is flat key → scalar, and keeping this closed is what makes the JSON Lines
/// encoder a total, trivial function.
public enum LogValue: Sendable, Hashable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
}

extension LogValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension LogValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    self = .int(value)
  }
}

extension LogValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self = .double(value)
  }
}

extension LogValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}
