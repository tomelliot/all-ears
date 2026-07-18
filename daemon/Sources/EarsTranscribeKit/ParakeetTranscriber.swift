import Dispatch
import EarsCore
import FluidAudio
import Foundation

/// Errors specific to ``ParakeetTranscriber`` itself (as opposed to errors
/// FluidAudio's `AsrManager` throws, which are propagated as-is).
public enum ParakeetTranscriberError: Error, Sendable, Equatable {
  /// `transcribe` was called before a successful `load`.
  case notLoaded
}

/// The native ASR backend (`docs/product/specs/model-interface.md`'s
/// "Backend 1 -- native"): NVIDIA Parakeet TDT via FluidAudio's Core ML/ANE
/// pipeline. This is a foundation-stage, best-effort proof of concept --
/// scoped deliberately narrow:
///
/// - Conforms to the base ``Transcriber`` protocol only. It does **not**
///   conform to ``StreamingTranscriber``, ``BiasingTranscriber``, or
///   ``WordTimingTranscriber`` yet, even though FluidAudio's `ASRResult`
///   already carries `TokenTiming`s a later pass can reconstruct word
///   timings from.
/// - Deliberately **not implemented** in this pass (tracked as separate
///   follow-up work per the roadmap's Phase 2): SentencePiece word-timing
///   reconstruction, trailing-silence padding before TDT decode (FluidAudio
///   issue #562), model-cache corruption auto-recovery/resume, ANE-aligned
///   `MLMultiArray` pooling, and setting `XDG_CACHE_HOME` into the sandboxed
///   app container.
/// - Every real Core ML/ANE call (model load, decode) is funneled through a
///   shared ``ANEInferenceGate`` per the spec's macOS 14 SIGBUS-avoidance
///   requirement.
///
/// ## The sync-protocol / async-SDK mismatch
///
/// `Transcriber.load`/`transcribe` are synchronous, throwing methods (fixed
/// by `docs/product/specs/model-interface.md` -- not redesigned here), but
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
      languages: ["en"]
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
      languages: ["en"]
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
