import EarsCore

/// The result of a tool's real work, folded into the final `run.summary`
/// record by ``EarsCLI/run(tool:version:arguments:work:)``.
///
/// Splitting this out is what lets `run.summary` tell the truth (issue #25):
/// the record is emitted *after* the work returns, with `status` derived from
/// ``exitCode`` (`ok` on 0, `error` otherwise), the failing ``error`` message
/// that previously only reached stderr, and any headline ``fields`` (counts,
/// output paths) the work wants surfaced structurally — see `docs/logging.md`.
public struct RunOutcome: Sendable {
  /// The process exit code the run resolved to (0 on success).
  public var exitCode: Int32
  /// The failure message that led to a non-zero exit, carried into the
  /// summary's `error` field. `nil` on success, or when the failure produced
  /// no message worth surfacing.
  public var error: String?
  /// Headline counts / output paths to attach to the summary (e.g.
  /// `segments`, `words`, `output`), so operators reading `run.summary` see
  /// what a run produced, not just that it finished.
  public var fields: [LogField]

  public init(exitCode: Int32, error: String? = nil, fields: [LogField] = []) {
    self.exitCode = exitCode
    self.error = error
    self.fields = fields
  }

  /// A successful run with nothing extra to report.
  public static let ok = RunOutcome(exitCode: 0)
}
