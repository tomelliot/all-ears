/// The base ASR backend seam: every transcriber does at least this much.
///
/// Capability-by-protocol, **not** a god-object switch on engine type: this small
/// base protocol is layered with the optional capability protocols
/// (``StreamingTranscriber``, ``BiasingTranscriber``, ``WordTimingTranscriber``)
/// that a backend opts into by conforming. The pipeline checks ``ModelInfo``'s
/// capability flags and `as?`-casts to a capability protocol rather than
/// switching on the model name. Signatures are transcribed from
/// `docs/specs/model-interface.md`.
///
/// Refines `Sendable`: transcribers cross actor boundaries in `earsd` and the
/// pipeline tools (Swift 6 strict concurrency), so a conformer that loads and
/// caches weights must provide its own internal synchronisation (an actor or a
/// lock-guarded class).
public protocol Transcriber: Sendable {
  /// Name, version, languages, and capability flags.
  var info: ModelInfo { get }

  /// Load weights and pick the compute unit (ANE/GPU/CPU).
  func load(_ options: LoadOptions) throws

  /// Batch-decode a mono PCM buffer into timed segments.
  func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment]
}
