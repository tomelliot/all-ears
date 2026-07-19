import EarsCore
import Synchronization

/// A ``StreamingTranscriber`` that returns pre-scripted text per `step` call,
/// so `transcribe --follow`'s pipeline wiring can be tested without a real
/// ASR backend — the streaming counterpart of ``ScriptedTranscriber``.
///
/// Each `step` consumes the next scripted string in order and returns it as
/// one ``Segment`` spanning the stepped buffer (an empty scripted string
/// returns no segments, modelling a silence decode); calls beyond the script
/// return no segments rather than trapping, since a follow pipeline's step
/// count depends on batching cadence rather than being exactly known by the
/// test. Recorded calls expose exactly what audio was stepped, in order.
/// Backed by a `Mutex` so the type is genuinely `Sendable` without
/// `@unchecked`, matching ``ScriptedTranscriber``.
public final class ScriptedStreamingTranscriber: StreamingTranscriber {
  public let info: ModelInfo

  private struct State {
    var remainingStepTexts: [String]
    var recordedSteps: [AudioBuffer] = []
  }
  private let state: Mutex<State>

  public init(
    info: ModelInfo = ModelInfo(
      name: "scripted-streaming", version: "0", languages: ["en"], supportsStreaming: true),
    stepTexts: [String]
  ) {
    self.info = info
    self.state = Mutex(State(remainingStepTexts: stepTexts))
  }

  public func load(_ options: LoadOptions) throws {}

  public func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] {
    []
  }

  public func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment] {
    let text = self.state.withLock { locked -> String in
      locked.recordedSteps.append(frames)
      guard !locked.remainingStepTexts.isEmpty else { return "" }
      return locked.remainingStepTexts.removeFirst()
    }
    state.framesConsumed += frames.frameCount
    guard !text.isEmpty else { return [] }
    state.priorText = state.priorText.isEmpty ? text : state.priorText + " " + text
    return [Segment(start: 0, end: frames.duration, text: text)]
  }

  /// Every buffer passed to ``step(_:state:)`` so far, in call order.
  public var recordedSteps: [AudioBuffer] {
    state.withLock { $0.recordedSteps }
  }
}
