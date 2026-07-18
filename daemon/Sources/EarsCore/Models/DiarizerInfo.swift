/// Descriptive metadata for a ``Diarizer`` backend.
///
/// `supportsStreaming` reflects the fast live pass used during `--follow`; the
/// durable transcript reflects the stabilised offline pass (Detto's two-pass
/// pattern), so a backend may support both or offline-only.
public struct DiarizerInfo: Sendable, Hashable, Codable {
  public var name: String
  public var version: String
  /// Backend can attribute speakers live (fast streaming pass), not only offline.
  public var supportsStreaming: Bool

  public init(name: String, version: String, supportsStreaming: Bool = false) {
    self.name = name
    self.version = version
    self.supportsStreaming = supportsStreaming
  }
}
