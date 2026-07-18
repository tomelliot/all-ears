/// Explicit failure modes for an ``LLMBackend`` call.
///
/// `docs/product/specs/llm-stages.md`: "Failures are loud and non-zero" --
/// a backend throws one of these rather than degrading to an empty
/// completion, so a caller can log and fall back to the original text
/// deliberately (via ``CleanupValidator``) instead of silently shipping
/// nothing.
public enum LLMBackendError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The subprocess exited non-zero. `stderr` is captured for logging (at
  /// `debug` and above only -- never the prompt).
  case nonZeroExit(code: Int32, stderr: String)
  /// The call exceeded its configured timeout.
  case timedOut
  /// The subprocess could not be launched at all (missing binary, etc.).
  case launchFailed(String)

  public var description: String {
    switch self {
    case .nonZeroExit(let code, let stderr):
      return "LLM backend exited with code \(code): \(stderr)"
    case .timedOut:
      return "LLM backend call timed out"
    case .launchFailed(let reason):
      return "LLM backend failed to launch: \(reason)"
    }
  }
}
