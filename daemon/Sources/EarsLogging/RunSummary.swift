import EarsCore

/// Builds the final `run.summary` record `docs/logging.md` requires
/// one-shot tools (`transcribe`, `cleanup`, `summarize`) to emit before
/// exiting — counts, durations, and output paths as ``LogField``s.
public enum RunSummary {
  /// - Parameter level: defaults to `.info`; pass `.error` when summarizing
  ///   a run that failed, so log-level filters surface it alongside the
  ///   individual error records that led up to it.
  public static func record(
    ts: Instant,
    level: LogLevel = .info,
    tool: String,
    subsystem: String,
    category: String,
    pid: Int32,
    msg: String? = nil,
    fields: [LogField] = []
  ) -> LogRecord {
    LogRecord(
      ts: ts,
      level: level,
      tool: tool,
      subsystem: subsystem,
      category: category,
      pid: pid,
      event: "run.summary",
      msg: msg,
      fields: fields
    )
  }
}
