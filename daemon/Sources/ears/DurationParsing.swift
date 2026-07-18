/// Parses a duration string like `"30m"` or `"2h"` (the shape
/// `docs/specs/capture-daemon.md`'s `ears mark --last 30m` uses) into
/// seconds, for `mark`'s `MarkRange.lastSeconds` wire field.
///
/// Pure and dependency-free, so it's unit-tested directly rather than only
/// through a spawned `ears` process.
enum DurationParsing {
  /// Recognised unit suffixes, in the order tried: `s` (seconds), `m`
  /// (minutes), `h` (hours). A bare integer with no suffix is treated as
  /// seconds, matching the least-surprising reading of a plain number.
  enum ParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case malformed(String)

    var description: String {
      switch self {
      case .empty:
        return "duration is empty"
      case .malformed(let value):
        return "'\(value)' is not a valid duration (expected e.g. '30s', '20m', '2h')"
      }
    }
  }

  static func seconds(from duration: String) -> Result<Double, ParseError> {
    guard !duration.isEmpty else { return .failure(.empty) }

    let unit = duration.last!
    let (numberPart, multiplier): (Substring, Double)
    switch unit {
    case "s": (numberPart, multiplier) = (duration.dropLast(), 1)
    case "m": (numberPart, multiplier) = (duration.dropLast(), 60)
    case "h": (numberPart, multiplier) = (duration.dropLast(), 3_600)
    default:
      if let value = Double(duration) { return .success(value) }
      return .failure(.malformed(duration))
    }

    guard let value = Double(numberPart), value >= 0 else {
      return .failure(.malformed(duration))
    }
    return .success(value * multiplier)
  }
}
