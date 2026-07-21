import EarsCore
import EarsLogging
import Synchronization

/// A fake ``LogRecordSink`` that captures every record, so tests can assert on
/// the structured log output the daemon and capture path emit — the same sink
/// seam production wires to the real `LogSink`. Shared across this target's
/// test files.
final class RecordingLogRecordSink: LogRecordSink, @unchecked Sendable {
  private let records = Mutex<[LogRecord]>([])

  func log(_ record: LogRecord) async throws {
    records.withLock { $0.append(record) }
  }

  var recorded: [LogRecord] { records.withLock { $0 } }
}
