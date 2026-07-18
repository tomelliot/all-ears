/// A pub/sub event kind a client can `subscribe` to, per
/// `docs/specs/capture-daemon.md`'s literal subscribe example
/// (`"events":["vad","session","segment"]`).
public enum EventKind: String, Sendable, Hashable, Codable, CaseIterable {
  case vad
  case session
  case segment
}
