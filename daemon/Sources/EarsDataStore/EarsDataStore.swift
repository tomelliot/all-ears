/// Dual-rate chunk encoding, atomic writes, and index/session persistence
/// for captured audio, per `docs/architecture.md`.
///
/// The module's entry points: ``ChunkEncoder`` (per-source actor that rolls
/// incoming audio into dual-rate chunk files), ``IndexAppender``
/// (`index.jsonl` append-only writer), ``SegmentedAudioReader`` (the read-side
/// composition root `transcribe` decodes through), and ``SourceMetaStore`` /
/// ``SessionStore`` / ``MeetingStore`` (`meta.toml`/`session.toml`/
/// `meeting.toml` persistence).
public enum EarsDataStore {
  /// Version of the `EarsDataStore` module.
  public static let version = "0.1.0"
}
