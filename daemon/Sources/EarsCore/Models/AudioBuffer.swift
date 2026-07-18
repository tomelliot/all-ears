/// A block of mono PCM audio: the unit passed across every model boundary
/// (``Transcriber``, ``Diarizer``, ``VAD``) and delivered by a ``CaptureBackend``.
///
/// Samples are single-channel (mono) floating-point, normalised to `[-1, 1]`.
/// The suite keeps sources mono end to end; multi-channel handling, if ever
/// needed, is a shim concern that down-mixes before constructing a buffer.
///
/// This value-type buffer models the in-memory contract at the protocol seam.
/// The daemon's realtime jitter buffer and the transcriber's memory-mapped,
/// disk-backed reads (see `docs/data-formats.md`) are separate storage concerns
/// that ultimately hand pure logic an `AudioBuffer`.
public struct AudioBuffer: Sendable, Hashable {
  /// Mono PCM samples in `[-1, 1]`.
  public var samples: [Float]
  /// Sample rate in Hz (e.g. 16000 for the ASR feed, 48000 for the native feed).
  public var sampleRate: Int

  public init(samples: [Float], sampleRate: Int) {
    self.samples = samples
    self.sampleRate = sampleRate
  }

  /// Number of PCM frames (samples, since mono).
  public var frameCount: Int { samples.count }

  /// Duration in seconds, or `0` when the sample rate is non-positive.
  public var duration: Double {
    sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
  }
}
