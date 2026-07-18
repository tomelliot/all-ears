import EarsCore

/// Resolves `transcribe`'s `--last <dur>` flag (per
/// `docs/specs/transcribe.md`'s CLI) into a wall-clock ``TimeRange`` ending
/// at `now`.
///
/// Pure and clock-injected -- no wall-clock read here -- per
/// `docs/engineering-practices.md`'s "no wall-clock time in tests" rule;
/// ``TranscribeRuntime`` supplies the real `now` via `NowProviding`, tests
/// supply a fixed ``Instant`` directly.
///
/// Only `--last` is implemented in this pass of `transcribe`'s wiring;
/// `--from`/`--to` and `--session` (both named in the spec's CLI) are a
/// deliberate follow-up, not silently dropped -- see the final report for
/// this scope call.
enum TranscribeRangeResolution {
  enum RangeError: Error, Equatable, CustomStringConvertible {
    /// Neither `--last` nor any other range flag was given.
    case noRangeSpecified
    /// `--last`'s value didn't parse as a duration.
    case invalidDuration(String)
    /// The resolved range has zero or negative length.
    case emptyRange

    var description: String {
      switch self {
      case .noRangeSpecified:
        return "no range specified: pass --last <duration> (e.g. --last 20m)"
      case .invalidDuration(let detail):
        return detail
      case .emptyRange:
        return "requested range is empty (--last must be greater than zero)"
      }
    }
  }

  static func resolve(last: String?, now: Instant) -> Result<TimeRange, RangeError> {
    guard let last else { return .failure(.noRangeSpecified) }

    switch DurationParsing.seconds(from: last) {
    case .failure(let parseError):
      return .failure(.invalidDuration(parseError.description))
    case .success(let seconds):
      guard seconds > 0 else { return .failure(.emptyRange) }
      return .success(TimeRange(start: now.advanced(by: -seconds), end: now))
    }
  }
}
