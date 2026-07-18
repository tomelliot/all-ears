import EarsCore

/// A ``UnifiedLogging`` conformance that discards every record, for
/// `[log].oslog = false` (`docs/logging.md`: "the unified-logging mirror is
/// always emitted unless `[log].oslog = false`"). Keeps callers that
/// construct a ``LogSink`` from resolved config free of an `Optional`
/// unified-logging seam.
public struct NoOpUnifiedLogging: UnifiedLogging {
  public init() {}

  public func log(_ record: LogRecord) {}
}
