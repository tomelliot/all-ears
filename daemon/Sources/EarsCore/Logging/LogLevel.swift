/// The four log levels defined by `docs/logging.md`.
///
/// The unified-logging mirror (owned by `EarsLogging`, not this pure module)
/// maps each case to the matching `OSLogType`; `notice` corresponds to
/// `OSLogType.default` (labelled "Notice" in Console.app).
public enum LogLevel: String, Sendable, Hashable, Codable, CaseIterable {
  /// Verbose developer detail, off in normal runs.
  case debug
  /// Normal operational events.
  case info
  /// Noteworthy but expected (eviction, coarse VAD state, config loaded).
  case notice
  /// Failures, always paired with actionable context.
  case error
}

extension LogLevel: Comparable {
  /// Severity rank, low to high, matching `docs/logging.md`'s table order.
  /// Used to decide whether a record at a given level clears the
  /// configured `[log].level` threshold (`--log-level`/`EARS_LOG__LEVEL`).
  private var severity: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .notice: 2
    case .error: 3
    }
  }

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.severity < rhs.severity
  }
}
