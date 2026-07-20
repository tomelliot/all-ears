/// `subscribe`'s result: a snapshot of live state tagged with the monotonic
/// state revision — what closes v1's list-then-subscribe race. Every
/// subsequent state ``EventFrame`` carries `rev`; a client applies a state
/// notification iff `rev == last_rev + 1` (ignoring stale ones below the
/// snapshot) and resubscribes on a gap.
///
/// The snapshot's `rev` is read *before* the state lists are gathered, so a
/// mutation racing the snapshot can only appear as both snapshot content and
/// a rev-above-snapshot event (a harmless re-apply), never as a silently
/// missed update.
public struct SnapshotData: Sendable, Hashable, Codable {
  public var rev: Int
  /// Active/paused (and recently ended) meetings.
  public var meetings: [Meeting]
  public var sources: [SourceStatus]
  /// Open sessions.
  public var sessions: [SessionSummary]

  public init(rev: Int, meetings: [Meeting], sources: [SourceStatus], sessions: [SessionSummary]) {
    self.rev = rev
    self.meetings = meetings
    self.sources = sources
    self.sessions = sessions
  }
}
