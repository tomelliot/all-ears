/// An empty success `data` payload — `{}` — for commands whose spec entry
/// describes an effect but no return value (`sources.add`/`remove`/
/// `enable`/`disable`, `capture.pause`/`resume`, `session.close`, `flush`).
/// The `{"ok":true,...}` envelope still needs a `data` value; this is it.
public struct EmptyData: Sendable, Hashable, Codable {
  public init() {}
}
