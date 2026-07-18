import EarsCore
import Synchronization

/// A ``Transcriber`` that returns pre-scripted ``Segment``s per call, so a
/// caller (`transcribe`'s wiring tests) can assert exactly how those segments
/// get merged/rendered without needing a real ASR backend.
///
/// Unlike ``NullTranscriber`` (always empty, proving the base seam is
/// satisfiable) and ``CapableTranscriber`` (proving the capability-protocol
/// casts compose), this fake exists to control *what* comes back: tests
/// configure one `[Segment]` array per expected `transcribe(_:context:)` call,
/// consumed in call order. Backed by a `Mutex` (not a plain `var`) so the type
/// is genuinely `Sendable` without `@unchecked`, matching ``ManualClock``'s
/// approach to the same problem.
public final class ScriptedTranscriber: Transcriber {
  public let info: ModelInfo

  private struct State {
    var remainingResults: [[Segment]]
    var recordedCalls: [(audio: AudioBuffer, context: TranscribeContext)] = []
  }
  private let state: Mutex<State>

  public init(
    info: ModelInfo = ModelInfo(name: "scripted", version: "0", languages: ["en"]),
    results: [[Segment]]
  ) {
    self.info = info
    self.state = Mutex(State(remainingResults: results))
  }

  public func load(_ options: LoadOptions) throws {}

  /// Returns the next scripted `[Segment]` array, in the order this instance
  /// was constructed with. Traps if called more times than there are
  /// scripted results -- a test bug (an unexpected extra call), not a
  /// runtime condition to handle gracefully.
  public func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] {
    state.withLock { state in
      state.recordedCalls.append((audio, context))
      precondition(
        !state.remainingResults.isEmpty,
        "ScriptedTranscriber.transcribe called more times than results were scripted")
      return state.remainingResults.removeFirst()
    }
  }

  /// Every `(audio, context)` pair passed to ``transcribe(_:context:)`` so
  /// far, in call order -- lets a test assert which audio a caller actually
  /// fed the backend (e.g. which source's slices, in which order).
  public var recordedCalls: [(audio: AudioBuffer, context: TranscribeContext)] {
    state.withLock { $0.recordedCalls }
  }
}
