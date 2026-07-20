import Dispatch
import EarsCore
import FluidAudio
import Foundation

/// Errors specific to ``ParakeetTranscriber`` itself (as opposed to errors
/// FluidAudio's `AsrManager` throws, which are propagated as-is).
public enum ParakeetTranscriberError: Error, Sendable, Equatable {
  /// `transcribe`/`step` was called before a successful `load`.
  case notLoaded
  /// `step` was handed more audio than one stateful decode call accepts
  /// (FluidAudio's Core ML encoder window, `ASRConstants.maxModelSamples`
  /// ≈ 15 s at 16 kHz). Beyond that FluidAudio silently falls back to its
  /// *stateless* chunked long-form path, which would break the threaded
  /// decoder-state continuity streaming depends on — so the shim refuses
  /// loudly instead. The caller's batcher/window sizing keeps steps under
  /// this bound by construction.
  case stepTooLong(frameCount: Int, maxFrameCount: Int)
}

/// The native ASR backend (`docs/specs/model-interface.md`'s
/// "Backend 1 -- native"): NVIDIA Parakeet TDT via FluidAudio's Core ML/ANE
/// pipeline. Scoped deliberately narrow:
///
/// - Conforms to ``Transcriber`` plus ``StreamingTranscriber`` (Phase 6:
///   ``step(_:state:)`` below, threading FluidAudio's real `TdtDecoderState`
///   through ``DecoderState/backend``). It does **not** conform to
///   ``BiasingTranscriber`` or ``WordTimingTranscriber`` yet, even though
///   FluidAudio's `ASRResult` already carries `TokenTiming`s a later pass
///   can reconstruct word timings from.
/// - Deliberately **not implemented** in this pass (tracked as separate
///   follow-up work per the roadmap's Phase 2): SentencePiece word-timing
///   reconstruction, trailing-silence padding before *batch* TDT decode
///   (FluidAudio issue #562; the streaming path covers it -- `step` pads a
///   short buffer up to FluidAudio's minimum, and `transcribe --follow`'s
///   finalization pass appends real trailing silence per window), model-cache
///   corruption auto-recovery/resume, ANE-aligned `MLMultiArray` pooling, and
///   setting `XDG_CACHE_HOME` into the sandboxed app container.
/// - Every real Core ML/ANE call (model load, decode) is funneled through a
///   shared ``ANEInferenceGate`` per the spec's macOS 14 SIGBUS-avoidance
///   requirement.
///
/// ## The sync-protocol / async-SDK mismatch
///
/// `Transcriber.load`/`transcribe` are synchronous, throwing methods (fixed
/// by `docs/specs/model-interface.md` -- not redesigned here), but
/// FluidAudio's real API is fully asynchronous: `AsrModels.downloadAndLoad`
/// awaits a network download, and `AsrManager` is an actor whose methods all
/// `await`. This shim bridges sync -> async with a blocking semaphore
/// (`blockingBridge(_:)` below). That bridge is only safe when `load`/
/// `transcribe` are called from an ordinary OS thread outside Swift's
/// cooperative executor pool (e.g. a synchronous CLI entry point before any
/// `Task` is running) -- calling it from inside a already-running `Task`
/// risks starving the limited cooperative thread pool. This is a genuine
/// open question the foundation-spike task called out explicitly rather
/// than silently working around: a real fix likely means evolving
/// `Transcriber` to an `async` protocol in a follow-up change, which is out
/// of scope here.
public final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
  public private(set) var info: ModelInfo

  private let gate: ANEInferenceGate
  private let modelVersion: AsrModelVersion
  private let modelDirectory: URL?
  private let state = LoadedModelState()

  /// - Parameters:
  ///   - modelVersion: Which FluidAudio Parakeet variant to load; overridden
  ///     by `LoadOptions.modelIdentifier` at `load(_:)` time if given.
  ///   - modelDirectory: Where FluidAudio should cache downloaded model
  ///     weights; `nil` uses FluidAudio's own default cache directory.
  ///   - gate: The shared ``ANEInferenceGate`` serializing ANE inference.
  ///     Pass the same instance to every ``ParakeetTranscriber`` (and any
  ///     other ANE-bound backend, e.g. a future VAD shim) sharing a process,
  ///     since the SIGBUS this guards against is a process-wide ANE
  ///     contention issue, not one scoped to a single model instance.
  public init(
    modelVersion: AsrModelVersion = .v3,
    modelDirectory: URL? = nil,
    gate: ANEInferenceGate = ANEInferenceGate()
  ) {
    self.modelVersion = modelVersion
    self.modelDirectory = modelDirectory
    self.gate = gate
    self.info = ModelInfo(
      name: "parakeet-tdt-fluidaudio",
      version: versionString(for: modelVersion),
      languages: ["en"],
      supportsStreaming: true
    )
  }

  /// Downloads (if needed) and loads the Parakeet Core ML models, then wires
  /// up the FluidAudio `AsrManager`. The download and Core ML load both run
  /// through ``ANEInferenceGate``.
  public func load(_ options: LoadOptions) throws {
    let resolvedVersion = resolveModelVersion(fromIdentifier: options.modelIdentifier)
    let computeUnits = resolveComputeUnits(for: options.compute)
    let directory = modelDirectory

    try blockingBridge {
      let models = try await self.gate.run {
        try await AsrModels.downloadAndLoad(
          to: directory,
          version: resolvedVersion,
          encoderComputeUnits: computeUnits
        )
      }
      let manager = AsrManager(config: .default, models: models)
      await self.state.set(manager: manager, version: resolvedVersion)
    }
    info = ModelInfo(
      name: "parakeet-tdt-fluidaudio",
      version: versionString(for: resolvedVersion),
      languages: ["en"],
      supportsStreaming: true
    )
  }

  /// Batch-decodes `audio` (expected mono, 16 kHz per FluidAudio's `AsrManager`)
  /// into a single ``Segment`` spanning the whole buffer. Multi-segment
  /// splitting (VAD-natural-pause segmentation) is `transcribe`-tool logic
  /// layered on top of this backend, not this shim's concern.
  public func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment] {
    try blockingBridge {
      guard let manager = await self.state.manager else {
        throw ParakeetTranscriberError.notLoaded
      }
      let samples = audio.samples
      let result = try await self.gate.run { () async throws -> ASRResult in
        var decoderState = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &decoderState)
      }
      return [
        Segment(
          start: 0,
          end: audio.duration,
          text: result.text,
          confidence: Double(result.confidence)
        )
      ]
    }
  }
}

extension ParakeetTranscriber: StreamingTranscriber {
  /// The largest audio buffer one `step` accepts: FluidAudio's Core ML
  /// encoder window (~15 s at 16 kHz). Staying at or under this keeps every
  /// call on FluidAudio's *stateful* single-window decode path — beyond it,
  /// `AsrManager.transcribe` silently switches to its stateless long-form
  /// `ChunkProcessor`, which would discard the threaded decoder continuity.
  static var maxStepFrameCount: Int { ASRConstants.maxModelSamples }

  /// Incrementally decode the next block of frames, threading continuity
  /// through `state` — the real TDT streaming decode `docs/specs/
  /// model-interface.md` promises for `--follow`.
  ///
  /// Continuity is FluidAudio's own chunk-streaming mechanism: a
  /// `TdtDecoderState` (LSTM hidden/cell state + last token + time-jump
  /// bookkeeping) carried across calls, so each step resumes mid-utterance
  /// instead of starting from SOS. That state rides in
  /// ``DecoderState/backend`` (see ``ParakeetDecoderState``): the *caller*
  /// owns continuity, so one transcriber instance serves any number of
  /// concurrent streams without cross-contamination — each stream simply
  /// threads its own `DecoderState`. A missing or foreign box (a state
  /// produced by a different backend) starts a fresh decode rather than
  /// misreading it.
  ///
  /// The returned segment's `start`/`end` are relative to `frames` (this
  /// step's buffer), matching ``Transcriber/transcribe(_:context:)``'s
  /// convention; text is only what *this* step decoded, so successive steps'
  /// texts concatenate into the stream's transcript. An empty decode (pure
  /// silence) returns `[]`.
  ///
  /// Expects mono 16 kHz input (FluidAudio's `AsrManager` contract, same as
  /// the batch path). Buffers shorter than FluidAudio's ~0.3 s minimum are
  /// padded with trailing silence before decode (the trailing-silence-pad
  /// requirement, FluidAudio issue #562) rather than rejected, so a short
  /// end-of-stream flush still decodes. Runs through the shared
  /// ``ANEInferenceGate`` — streaming inference is not exempt from the
  /// macOS 14 SIGBUS serialization — and uses the same `blockingBridge`
  /// (and the same calling-context caveats) as `transcribe`.
  public func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment] {
    guard frames.frameCount <= Self.maxStepFrameCount else {
      throw ParakeetTranscriberError.stepTooLong(
        frameCount: frames.frameCount, maxFrameCount: Self.maxStepFrameCount)
    }

    let minimumFrameCount = ASRConstants.minimumRequiredSamples(
      forSampleRate: frames.sampleRate)
    var samples = frames.samples
    if samples.count < minimumFrameCount {
      samples.append(contentsOf: [Float](repeating: 0, count: minimumFrameCount - samples.count))
    }
    let decodeSamples = samples
    let priorState = (state.backend as? ParakeetDecoderState)?.tdt

    let outcome = try blockingBridge { () async throws -> StepOutcome in
      guard let manager = await self.state.manager else {
        throw ParakeetTranscriberError.notLoaded
      }
      return try await self.gate.run {
        var tdtState: TdtDecoderState
        if let priorState {
          tdtState = priorState
        } else {
          tdtState = try TdtDecoderState()
        }
        let result = try await manager.transcribe(decodeSamples, decoderState: &tdtState)
        return StepOutcome(result: result, decoderState: tdtState)
      }
    }

    if let box = state.backend as? ParakeetDecoderState {
      box.tdt = outcome.decoderState
    } else {
      state.backend = ParakeetDecoderState(tdt: outcome.decoderState)
    }
    state.framesConsumed += frames.frameCount
    let text = outcome.result.text
    guard !text.isEmpty else { return [] }
    state.priorText = state.priorText.isEmpty ? text : state.priorText + " " + text
    return [
      Segment(
        start: 0,
        end: frames.duration,
        text: text,
        confidence: Double(outcome.result.confidence)
      )
    ]
  }
}

/// The pair a streaming step brings back across `blockingBridge`'s detached
/// task: the decode result plus the updated decoder state. A named struct
/// (rather than a tuple) so the bridge's `T: Sendable` constraint is
/// satisfied by ordinary conformance.
private struct StepOutcome: Sendable {
  var result: ASRResult
  var decoderState: TdtDecoderState
}

/// The FluidAudio-owned half of a streaming ``DecoderState``: boxes the real
/// `TdtDecoderState` behind `EarsCore`'s opaque ``BackendDecoderState`` seam.
///
/// `@unchecked Sendable`: the mutable `tdt` field is only ever read/written
/// inside ``ParakeetTranscriber/step(_:state:)`` for the `DecoderState` that
/// carries this box, and the caller-owns-continuity contract (see
/// ``StreamingTranscriber``) means one stream's `DecoderState` is threaded
/// through *sequential* step calls — concurrent steps on one box would be a
/// caller bug the contract already forbids.
final class ParakeetDecoderState: BackendDecoderState, @unchecked Sendable {
  var tdt: TdtDecoderState

  init(tdt: TdtDecoderState) {
    self.tdt = tdt
  }
}

/// Actor-isolated storage for the loaded `AsrManager`, so `load`/`transcribe`
/// (both synchronous per the protocol) can read/write it from inside
/// ``ParakeetTranscriber/blockingBridge(_:)``'s detached `Task`.
private actor LoadedModelState {
  private(set) var manager: AsrManager?
  private(set) var version: AsrModelVersion?

  func set(manager: AsrManager, version: AsrModelVersion) {
    self.manager = manager
    self.version = version
  }
}

/// Bridges a synchronous, throwing call to an `async throws` operation by
/// blocking the calling thread on a semaphore while the work runs on a
/// detached task. See ``ParakeetTranscriber``'s doc comment for why this
/// exists and when it is (and is not) safe to call.
func blockingBridge<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T
{
  let semaphore = DispatchSemaphore(value: 0)
  let box = BridgeResultBox<T>()

  Task.detached(priority: .userInitiated) {
    do {
      box.result = .success(try await operation())
    } catch {
      box.result = .failure(error)
    }
    semaphore.signal()
  }

  semaphore.wait()
  switch box.result {
  case .success(let value):
    return value
  case .failure(let error):
    throw error
  case .none:
    // Unreachable: `semaphore.signal()` only happens after `box.result` is
    // set, and `wait()` only returns after that `signal()`.
    fatalError("blockingBridge: semaphore released without a recorded result")
  }
}

/// Plain box carrying the detached task's result back across the semaphore.
/// `@unchecked Sendable` is sound here because the semaphore establishes a
/// happens-before edge: `result` is written before `signal()`, and read only
/// after `wait()` returns.
private final class BridgeResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
