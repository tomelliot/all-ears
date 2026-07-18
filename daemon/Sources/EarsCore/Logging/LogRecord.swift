/// One structured log event, matching the baseline schema in `docs/logging.md`.
///
/// `LogRecord` is a pure value: constructing one does no I/O and reads no
/// clock (`ts` is always supplied by the caller via ``NowProviding``, never
/// read internally). Encoding it to JSON Lines or a pretty rendering is a
/// separate, equally pure step (see `LogRecordJSONEncoder`,
/// `LogRecordPrettyRenderer`).
public struct LogRecord: Sendable, Hashable {
  /// ISO-8601 UTC timestamp, millisecond precision, once encoded.
  public var ts: Instant
  public var level: LogLevel
  /// Emitting binary, e.g. `earsd`, `transcribe`.
  public var tool: String
  /// Unified-logging subsystem, e.g. `net.tomelliot.ears`.
  public var subsystem: String
  /// Unified-logging category, e.g. `earsd`, `earsd.vad`, `transcribe`.
  public var category: String
  public var pid: Int32
  /// Stable, machine-readable event name (e.g. `chunk.written`, `stage.end`).
  public var event: String
  /// Optional short human string. Never the sole carrier of information —
  /// anything actionable belongs in ``fields`` instead.
  public var msg: String?
  /// Ordered context fields (`source`, `session`, `span_id`, `duration_ms`,
  /// `rtf`, and so on). Order is preserved through to encoded output.
  public var fields: [LogField]

  public init(
    ts: Instant,
    level: LogLevel,
    tool: String,
    subsystem: String,
    category: String,
    pid: Int32,
    event: String,
    msg: String? = nil,
    fields: [LogField] = []
  ) {
    self.ts = ts
    self.level = level
    self.tool = tool
    self.subsystem = subsystem
    self.category = category
    self.pid = pid
    self.event = event
    self.msg = msg
    self.fields = fields
  }
}
