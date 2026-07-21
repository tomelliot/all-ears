import EarsCore

/// The one seam every component logs a structured ``LogRecord`` through, so
/// the whole daemon — CLI startup, daemon lifecycle, and the capture path —
/// fans out to the *same* destinations (`docs/logging.md`'s JSON Lines file,
/// stderr, and the unified-logging mirror) in one consistent format, rather
/// than each subsystem inventing its own logging path.
///
/// ``LogSink`` is the production conformance; it already has exactly this
/// method (see the extension below), so injecting `any LogRecordSink` gives
/// callers the real fan-out in production and a recorder/no-op in tests
/// without depending on the concrete actor.
public protocol LogRecordSink: Sendable {
  /// Fans `record` out to every configured destination. `async` because the
  /// file write is actor-isolated; `throws` because that write can fail
  /// (disk full, permissions) and per `docs/engineering-practices.md` that
  /// failure is surfaced, not swallowed. Operational callers on hot paths
  /// typically `try?` it.
  func log(_ record: LogRecord) async throws
}

/// ``LogSink`` already fans a ``LogRecord`` out to all three destinations with
/// this exact signature, so it satisfies ``LogRecordSink`` with no extra code.
extension LogSink: LogRecordSink {}

/// A ``LogRecordSink`` that discards every record — the safe default for a
/// component constructed without a real sink (e.g. a unit test that doesn't
/// assert on logging), mirroring ``NoOpUnifiedLogging`` one layer up.
public struct NoOpLogRecordSink: LogRecordSink {
  public init() {}

  public func log(_ record: LogRecord) async throws {}
}
