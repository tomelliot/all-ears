/// A meeting's on-disk descriptor, mirroring `meeting.toml`
/// (`<data-root>/meetings/<uuid>/meeting.toml`).
///
/// The daemon — not any client — owns meeting identity: every meeting gets a
/// daemon-generated UUID as its one consistent internal id, and this record
/// maps that UUID to the platform-specific *external* id it corresponds to
/// (Meet's `spaces/<space>` segment, a Zoom meeting number, ...). Given a
/// `(platform, externalID)` pair, the daemon can look up whether a meeting
/// already exists for it (rejoin correlation) instead of trusting a client to
/// re-derive an identical slug itself — see `MeetingRegistry.resolve`.
///
/// A meeting is identity only, deliberately not a session: rejoining the same
/// meeting produces a *new* session (audio genuinely stopped and restarted)
/// whose `slug` is this record's `id`, which is exactly what makes every
/// attendance of "the same meeting" identifiable later.
public struct MeetingDescriptor: Sendable, Hashable, Codable {
  /// Schema version of the `meeting.toml` format this descriptor was read from.
  public var schema: Int
  /// The daemon-generated meeting id (a UUID string) — the one internal id
  /// used everywhere (session slugs, filenames, CLI output).
  public var id: String
  /// The platform the external id belongs to, e.g. `meet`.
  public var platform: String
  /// The platform's own meeting identifier, e.g. Meet's `<space>` segment
  /// from `spaces/<space>/devices/<device>`. Never used directly as a slug or
  /// filename — that's what ``id`` is for.
  public var externalID: String
  /// When the daemon first resolved this meeting.
  public var created: Instant

  public init(schema: Int, id: String, platform: String, externalID: String, created: Instant) {
    self.schema = schema
    self.id = id
    self.platform = platform
    self.externalID = externalID
    self.created = created
  }
}
