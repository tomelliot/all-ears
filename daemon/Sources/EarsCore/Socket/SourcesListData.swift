/// `sources.list`'s response `data` payload: every configured source and
/// its state, using the same ``SourceStatus`` shape `status` reports per
/// source.
public struct SourcesListData: Sendable, Hashable, Codable {
  public var sources: [SourceStatus]

  public init(sources: [SourceStatus]) {
    self.sources = sources
  }
}
