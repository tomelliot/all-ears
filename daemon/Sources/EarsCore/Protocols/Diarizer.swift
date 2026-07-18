/// The diarization backend seam: a separate, optional stage that assigns stable
/// speaker labels within a stream over a time range.
///
/// Channel-of-origin (the source) is the *primary* label; the diarizer only
/// *refines* a multi-speaker source into `Speaker N` and never overrides source
/// attribution. Transcribed from `docs/specs/model-interface.md`.
///
/// Refines `Sendable` for the same actor-boundary reasons as ``Transcriber``.
public protocol Diarizer: Sendable {
  var info: DiarizerInfo { get }

  /// Assign stable speaker labels to a stream's audio over its range.
  func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]
}
