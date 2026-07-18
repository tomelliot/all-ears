import EarsCore

/// Orchestrates the three destinations every log record fans out to, per
/// `docs/logging.md`: the JSON Lines file (always), the unified-logging
/// mirror (always), and stderr (pretty on a TTY, JSON otherwise).
///
/// The TTY check happens once, at construction — read here rather than
/// inline in ``log(_:)`` so it's a plain stored `Bool`, letting the actual
/// sink-writing logic be exercised in tests against a fixed
/// ``TTYDetecting`` fake instead of the real environment.
public actor LogSink {
  private let file: FileLogWriter
  private let stderr: any StderrWriting
  private let unified: any UnifiedLogging
  private let isStderrATTY: Bool

  public init(
    file: FileLogWriter,
    stderr: any StderrWriting,
    unified: any UnifiedLogging,
    tty: any TTYDetecting
  ) {
    self.file = file
    self.stderr = stderr
    self.unified = unified
    isStderrATTY = tty.isStderrATTY
  }

  /// Fans `record` out to all three destinations.
  ///
  /// The unified-logging mirror is best-effort and always attempted first;
  /// the file write can fail (disk full, permissions) and that failure
  /// propagates rather than being swallowed — per
  /// `docs/engineering-practices.md`'s "no silent catches".
  public func log(_ record: LogRecord) async throws {
    unified.log(record)
    try await file.append(record)
    if isStderrATTY {
      stderr.writeLine(LogRecordPrettyRenderer.render(record))
    } else {
      stderr.writeLine(LogRecordJSONEncoder.encode(record))
    }
  }
}
