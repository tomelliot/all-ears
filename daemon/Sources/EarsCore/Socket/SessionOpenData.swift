/// `session.open`'s response `data` payload: `docs/specs/capture-daemon.md`
/// describes the effect as "`{sources, slug, start?, vocab?}` → session id",
/// so the response is just the new session's id. Also reused for `mark`'s
/// response, which is the same "returns a session id" convenience.
public struct SessionOpenData: Sendable, Hashable, Codable {
  public var id: String

  public init(id: String) {
    self.id = id
  }
}
