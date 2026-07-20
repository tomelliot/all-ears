/// Dual-rate chunk encoding, atomic writes, and index/session persistence
/// for captured audio, per `docs/architecture.md`.
///
/// The module's entry points: ``ChunkEncoder`` (per-source actor that rolls
/// incoming audio into dual-rate chunk files), ``IndexAppender``
/// (`index.jsonl` append-only writer), ``EvictionExecutor`` /
/// ``HardTotalCapEnforcement`` (ring-buffer time-cap eviction, plus the
/// documented Phase 1 no-op seam for the cross-source hard total-size
/// backstop), ``StartupGapDetector`` / ``StartupGapAppender`` (daemon-
/// restart gap recording), and ``SourceMetaStore`` / ``SessionStore``
/// (`meta.toml`/`session.toml` persistence).
public enum EarsDataStore {
  /// Version of the `EarsDataStore` module.
  public static let version = "0.1.0"
}
