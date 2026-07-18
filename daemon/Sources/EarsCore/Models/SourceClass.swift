/// The kind of an audio source, mirroring `meta.toml`'s `class` field and the
/// source taxonomy in `docs/architecture.md`.
public enum SourceClass: String, Sendable, Hashable, Codable, CaseIterable {
  /// The default (or a named) input device.
  case mic
  /// Aggregate system output audio, via a Core Audio process tap.
  case system
  /// System audio filtered to a single application (`app:<bundle-id>`).
  case app
  /// Audio pushed in over the control socket (`browser:<label>`).
  case browser
  /// A specific external input device (`device:<uid>`).
  case device
}
