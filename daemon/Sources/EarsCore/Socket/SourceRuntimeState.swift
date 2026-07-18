/// Runtime state of a source, as reported by `status`/`sources.list`.
///
/// `docs/specs/capture-daemon.md`'s only literal example shows `"capturing"`;
/// `paused`/`disabled`/`error` round out the lifecycle implied by
/// `capture.pause`/`capture.resume` and `sources.enable`/`sources.disable` —
/// inferred, not given literally.
public enum SourceRuntimeState: String, Sendable, Hashable, Codable, CaseIterable {
  /// Actively capturing audio.
  case capturing
  /// Paused via `capture.pause` (or a suspension source — see the daemon
  /// spec's power/idle awareness); not capturing, but still configured.
  case paused
  /// Disabled via `sources.disable`, or never enabled.
  case disabled
  /// Not capturing due to an error (e.g. a denied permission — see the
  /// daemon spec's TCC-probing section, which disables just the affected
  /// source rather than the whole daemon).
  case error
}
