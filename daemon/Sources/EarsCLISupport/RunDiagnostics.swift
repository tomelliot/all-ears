import EarsCore
import Synchronization

/// Thread-safe collector a tool threads through its pipeline so the deep
/// error message and headline counts — produced far from the `run.summary`
/// emitter — can be folded into the final ``RunOutcome`` without changing
/// every pipeline's `Int32` return type (issue #25).
///
/// A pipeline still writes its `error: …` line to stderr exactly as before; a
/// runtime wires the pipeline's `onError`/`onSummary` hooks to ``recordError``
/// / ``recordSummary`` so that same line, and the run's counts, also reach the
/// structured summary. The human-readable `run.summary:` stderr line is
/// unchanged.
///
/// Backed by a `Mutex` (not a plain `var`) so it is genuinely `Sendable`
/// without `@unchecked`, matching the codebase's `ScriptedTranscriber` /
/// `ManualClock` approach to the same problem.
public final class RunDiagnostics: Sendable {
  private struct State {
    var lastError: String? = nil
    var summaryFields: [LogField] = []
  }
  private let state: Mutex<State>

  public init() {
    state = Mutex(State())
  }

  /// Records one `error: …` line. The last one recorded wins — it is the
  /// failure that ended the run.
  public func recordError(_ line: String) {
    state.withLock { $0.lastError = line }
  }

  /// Records the headline summary fields (counts, output paths) for a run.
  public func recordSummary(_ fields: [LogField]) {
    state.withLock { $0.summaryFields = fields }
  }

  public var lastError: String? { state.withLock { $0.lastError } }
  public var summaryFields: [LogField] { state.withLock { $0.summaryFields } }

  /// Builds the outcome for a finished run: the recorded error message is
  /// attached only on a non-zero exit, the recorded counts always.
  public func outcome(exitCode: Int32) -> RunOutcome {
    state.withLock { state in
      RunOutcome(
        exitCode: exitCode,
        error: exitCode == 0 ? nil : state.lastError,
        fields: state.summaryFields)
    }
  }
}
