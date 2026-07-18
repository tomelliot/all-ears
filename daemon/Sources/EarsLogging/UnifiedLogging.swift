import EarsCore
import os

/// The unified-logging mirror seam (`docs/logging.md`): the same events the
/// JSON stream carries are also mirrored into `os.Logger`/`OSLog` as a
/// convenience for Console.app, `log stream`/`log show`, and Instruments.
///
/// A protocol rather than a direct `os.Logger` call site so it can be
/// swapped for a recorder in tests — `os.Logger` has no readback API, so
/// "the unified-logging mirror received this call" can only be asserted
/// through a fake conformance, never against the real one.
public protocol UnifiedLogging: Sendable {
  func log(_ record: LogRecord)
}

/// The production ``UnifiedLogging`` conformance: forwards every record to
/// `os.Logger`, mapping ``LogLevel`` to the matching `OSLogType`.
///
/// Kept as thin as possible — per `docs/engineering-practices.md`'s tier-2
/// guidance, this is the one boundary that can't be meaningfully
/// unit-tested (there's no API to read back what `os.Logger` received), so
/// all real logic (encoding, rotation, sink selection) lives elsewhere,
/// fully covered, and this type does nothing but format and forward.
public struct OSLogUnifiedLogging: UnifiedLogging {
  private let logger: Logger

  public init(subsystem: String, category: String) {
    logger = Logger(subsystem: subsystem, category: category)
  }

  public func log(_ record: LogRecord) {
    logger.log(level: osLogType(for: record.level), "\(LogRecordPrettyRenderer.render(record))")
  }

  private func osLogType(for level: LogLevel) -> OSLogType {
    switch level {
    case .debug: .debug
    case .info: .info
    case .notice: .default
    case .error: .error
    }
  }
}
