import EarsCore
import EarsDataStore
import Foundation

/// Errors surfaced by ``MeetingRegistry``. `ControlServer` maps these to
/// `ControlError` messages on the wire.
public enum MeetingRegistryError: Error, Sendable, Hashable {
  /// `meeting.resolve` named an empty platform.
  case emptyPlatform
  /// `meeting.resolve` named an empty external id.
  case emptyExternalID
}

/// Owns meeting identity: the daemon-generated meeting UUID for every
/// `(platform, external_id)` pair a client has ever resolved, persisted as
/// `meetings/<uuid>/meeting.toml` via ``MeetingStore`` — the meeting-identity
/// sibling of ``SessionRegistry`` (in-memory map + `EarsDataStore`-backed
/// persistence, same split: registry = stateful owner, store = stateless
/// file I/O).
///
/// The daemon, not any client, owns meeting identity: internal ids have one
/// consistent format everywhere (`session.toml` slugs, filenames, CLI
/// output), never a raw platform-specific external id baked into a slug, and
/// rejoin correlation is a daemon-side persisted lookup rather than trusting
/// a client to re-derive an identical slug string every time.
public actor MeetingRegistry {
  /// The `meeting.toml` schema version new meetings are written with.
  public static let meetingSchemaVersion = 1

  private let dataRoot: URL
  private let clock: any NowProviding
  /// Mints a new meeting id — injected so tests get deterministic ids; the
  /// default is a lowercased UUID string.
  private let makeID: @Sendable () -> String
  private let log: @Sendable (String) -> Void

  /// `(platform, externalID)` → descriptor, loaded lazily from disk on first
  /// use (the same load-at-startup pattern `SessionRegistry`/`ControlServer`
  /// use for their own state, deferred to first touch so construction stays
  /// I/O-free).
  private var byExternalID: [MeetingKey: MeetingDescriptor] = [:]
  private var loaded = false

  private struct MeetingKey: Hashable {
    var platform: String
    var externalID: String
  }

  public init(
    dataRoot: URL,
    clock: any NowProviding = SystemClock(),
    makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.dataRoot = dataRoot
    self.clock = clock
    self.makeID = makeID
    self.log = log
  }

  /// The core operation, idempotent: if a persisted meeting already matches
  /// `(platform, externalID)`, return it; otherwise mint a new UUID, persist
  /// a new `meeting.toml`, and return that. Same pair in, same meeting id
  /// out — across calls, connections, and daemon restarts — which is what
  /// makes leaving and rejoining the same meeting resolve to the same id.
  ///
  /// - Throws: ``MeetingRegistryError`` on an empty platform/external id;
  ///   file-system errors from persisting a new descriptor.
  public func resolve(platform: String, externalID: String) throws -> MeetingDescriptor {
    guard !platform.isEmpty else { throw MeetingRegistryError.emptyPlatform }
    guard !externalID.isEmpty else { throw MeetingRegistryError.emptyExternalID }
    ensureLoaded()

    let key = MeetingKey(platform: platform, externalID: externalID)
    if let existing = byExternalID[key] {
      return existing
    }
    let descriptor = MeetingDescriptor(
      schema: Self.meetingSchemaVersion,
      id: makeID(),
      platform: platform,
      externalID: externalID,
      created: clock.now())
    try MeetingStore.write(descriptor, dataRoot: dataRoot)
    byExternalID[key] = descriptor
    return descriptor
  }

  /// Every known meeting, sorted by id — for tests and future listing.
  public func list() -> [MeetingDescriptor] {
    ensureLoaded()
    return byExternalID.values.sorted { $0.id < $1.id }
  }

  private func ensureLoaded() {
    guard !loaded else { return }
    loaded = true
    for descriptor in MeetingStore.readAll(
      dataRoot: dataRoot,
      onSkip: { [log] id, error in log("meeting registry: skipping meetings/\(id): \(error)") })
    {
      let key = MeetingKey(platform: descriptor.platform, externalID: descriptor.externalID)
      // First (id-sorted) wins on a duplicate pair — deterministic, and a
      // duplicate can only arise from hand-edited files.
      if byExternalID[key] == nil { byExternalID[key] = descriptor }
    }
  }
}
