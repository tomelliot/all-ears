import EarsCore
import EarsDataStore
import Foundation

/// Errors surfaced by ``SessionRegistry``. `ControlServer` maps these to
/// `ControlError` messages on the wire.
public enum SessionRegistryError: Error, Sendable, Hashable {
  /// `session.open`/`mark` named a source id this daemon doesn't know.
  case unknownSource(SourceID)
  /// `session.open`/`mark` named no sources.
  case noSources
  /// `session.close` named an id with no open session.
  case sessionNotFound(String)
  /// `session.close` named a session that is already closed.
  case sessionAlreadyClosed(String)
}

/// Owns session lifecycle: the in-memory map of session id → `SessionDescriptor`
/// plus their `session.toml` persistence. This is the actor `docs/architecture.md`
/// calls the "`SessionStore` actor".
///
/// ## Naming-collision resolution
///
/// `EarsDataStore` already has a type named `SessionStore` — a thin *enum* of
/// static `session.toml` read/write helpers. This lifecycle actor is therefore
/// named **`SessionRegistry`** to avoid the collision, and it *uses*
/// `EarsDataStore.SessionStore.write(_:dataRoot:)` / `.read(sessionID:dataRoot:)`
/// internally for the actual file I/O. Registry = the stateful lifecycle owner;
/// `SessionStore` = the stateless byte-level persistence it delegates to.
///
/// ## No `CaptureActor` coupling
///
/// A session is metadata over the recorded audio, not a separate recording (see
/// ``ActorContracts``), so opening/closing a session never starts, stops, or
/// pauses capture. This actor holds **no `CaptureActor` reference**. It still
/// has to validate that requested source ids are real, but does so through an
/// injected value seam (``init(dataRoot:schema:knownSourceIDs:clock:)``'s
/// `knownSourceIDs` closure) — deliberately *not* a `CaptureActor` handle — so
/// the coupling the spec doesn't require never creeps in.
public actor SessionRegistry {
  private let dataRoot: URL
  private let schema: Int
  private let clock: any NowProviding
  /// The validation seam: returns the ids of every currently-known source, so
  /// `open`/`mark` can reject unknown ones without referencing `CaptureActor`.
  private let knownSourceIDs: @Sendable () async -> Set<SourceID>
  /// Where live-feed `session` state events are published (the v2
  /// `{"event":"session","params":{"session":{…}},"rev":…}` feed — the full
  /// summary, so subscribers can sync their session set from events alone);
  /// `nil` publishes nothing.
  private let eventSink: EventSink?

  /// Open and recently-closed sessions, keyed by id.
  private var sessions: [String: SessionDescriptor] = [:]

  /// - Parameters:
  ///   - dataRoot: The suite's data root; descriptors persist under
  ///     `<data-root>/sessions/<id>/session.toml` via `DataStoreLayout`.
  ///   - schema: The `session.toml` schema version new sessions are written
  ///     with (defaults to ``ActorContracts/sessionSchemaVersion``).
  ///   - knownSourceIDs: The source-validation seam (see the type doc).
  ///   - clock: Wall-clock seam; supplies `start` when a request omits it and
  ///     `end` on close. Injected so tests never touch real time.
  ///   - eventSink: Where live-feed `session` events are published
  ///     (``EarsDaemon`` supplies its ``EventBus``'s `publish`); `nil` (the
  ///     default) publishes nothing — persistence is unaffected either way.
  public init(
    dataRoot: URL,
    schema: Int = ActorContracts.sessionSchemaVersion,
    knownSourceIDs: @escaping @Sendable () async -> Set<SourceID>,
    clock: any NowProviding = SystemClock(),
    eventSink: EventSink? = nil
  ) {
    self.dataRoot = dataRoot
    self.schema = schema
    self.knownSourceIDs = knownSourceIDs
    self.clock = clock
    self.eventSink = eventSink
  }

  /// Open a session over `sources`, named `slug`.
  ///
  /// Validates every id in `sources` against ``knownSourceIDs`` (and that
  /// `sources` is non-empty), allocates the id `<start-timestamp>_<slug>` per
  /// `docs/data-formats.md` (the timestamp via `FilenameTimestampCodec`),
  /// records an open descriptor (`end = nil`, `state = .open`), persists it via
  /// `EarsDataStore.SessionStore.write`, and returns it.
  ///
  /// - Parameters:
  ///   - start: The session's start; defaults to `clock.now()` when `nil`.
  ///   - vocab: Optional per-session vocabulary path, relative to the data root.
  ///   - trigger: What opened the session (`.manual` for `ears session open`;
  ///     `.appSignal` for an auto-trigger).
  ///   - preRollSeconds: Recorded on the descriptor for a later
  ///     `transcribe --session` to widen its read range by (see
  ///     ``SessionDescriptor/preRollSeconds``'s doc comment) -- never
  ///     applied to `start` itself. `0` (the default) means no widening.
  /// - Returns: The new open `SessionDescriptor` (domain type; `ControlServer`
  ///   maps it to `SessionOpenData`).
  /// - Throws: ``SessionRegistryError/noSources`` /
  ///   ``SessionRegistryError/unknownSource(_:)`` on validation failure.
  public func open(
    sources: [SourceID],
    slug: String,
    start: Instant?,
    vocab: String?,
    trigger: TriggerKind = .manual,
    preRollSeconds: Int = 0
  ) async throws -> SessionDescriptor {
    try await validate(sources: sources)
    let startInstant = start ?? clock.now()
    let descriptor = SessionDescriptor(
      schema: schema,
      id: sessionID(start: startInstant, slug: slug),
      slug: slug,
      sources: sources,
      start: startInstant,
      end: nil,
      state: .open,
      trigger: trigger,
      vocab: vocab,
      preRollSeconds: preRollSeconds
    )
    try SessionStore.write(descriptor, dataRoot: dataRoot)
    sessions[descriptor.id] = descriptor
    await eventSink?(.session(SessionSummary(descriptor)))
    return descriptor
  }

  /// Close an open session by id: set `end = clock.now()`, `state = .closed`,
  /// persist, and return the closed descriptor.
  ///
  /// - Throws: ``SessionRegistryError/sessionNotFound(_:)`` if no session has
  ///   that id; ``SessionRegistryError/sessionAlreadyClosed(_:)`` if it's
  ///   already closed.
  /// - Returns: The now-closed `SessionDescriptor`.
  public func close(id: String) async throws -> SessionDescriptor {
    guard var descriptor = sessions[id] else {
      throw SessionRegistryError.sessionNotFound(id)
    }
    guard descriptor.state == .open else {
      throw SessionRegistryError.sessionAlreadyClosed(id)
    }
    descriptor.end = clock.now()
    descriptor.state = .closed
    try SessionStore.write(descriptor, dataRoot: dataRoot)
    sessions[id] = descriptor
    await eventSink?(.session(SessionSummary(descriptor)))
    return descriptor
  }

  /// Append `source` to an open session's source list and persist — the
  /// `session.add_source` command. For sources that didn't exist yet at
  /// `session.open` time (a meeting participant's dynamic `browser:*` source
  /// opening mid-call) and would otherwise be silently excluded from the
  /// session's transcription (`TranscribeRangeResolution` reads
  /// `descriptor.sources` as written).
  ///
  /// Idempotent for an already-listed source (returns the unchanged
  /// descriptor without rewriting `session.toml`).
  ///
  /// - Throws: ``SessionRegistryError/sessionNotFound(_:)`` /
  ///   ``SessionRegistryError/sessionAlreadyClosed(_:)`` /
  ///   ``SessionRegistryError/unknownSource(_:)``.
  public func addSource(id: String, source: SourceID) async throws -> SessionDescriptor {
    guard var descriptor = sessions[id] else {
      throw SessionRegistryError.sessionNotFound(id)
    }
    guard descriptor.state == .open else {
      throw SessionRegistryError.sessionAlreadyClosed(id)
    }
    guard !descriptor.sources.contains(source) else { return descriptor }
    let known = await knownSourceIDs()
    guard known.contains(source) else {
      throw SessionRegistryError.unknownSource(source)
    }
    descriptor.sources.append(source)
    try SessionStore.write(descriptor, dataRoot: dataRoot)
    sessions[id] = descriptor
    // The descriptor changed, so subscribers get the refreshed summary —
    // session events are v2 state events carrying the full object.
    await eventSink?(.session(SessionSummary(descriptor)))
    return descriptor
  }

  /// Open and recently-closed sessions, for the `session.list` reply.
  /// `ControlServer` maps each to a `SessionSummary`. Sorted by `start` so
  /// the reply order is deterministic rather than dictionary-iteration order.
  public func list() -> [SessionDescriptor] {
    sessions.values.sorted { $0.start < $1.start }
  }

  /// Retroactively define an already-elapsed range as a session — the `mark`
  /// convenience.
  ///
  /// Resolves `range` to a concrete `[start, end)`: ``MarkRange/lastSeconds(_:)``
  /// becomes `[now - seconds, now)`, ``MarkRange/absolute(start:end:)`` is used
  /// as-is. Because the range is already in the past, this behaves like an
  /// ``open(sources:slug:start:vocab:trigger:)`` immediately followed by a
  /// ``close(id:)``: it writes a single **closed** descriptor (`state =
  /// .closed`, `end` set) in one step. Same source validation as `open`.
  ///
  /// - Returns: The closed `SessionDescriptor`. `ControlServer` maps it to
  ///   `SessionOpenData` (the same "returns a session id" shape as `open`).
  public func mark(
    sources: [SourceID],
    slug: String,
    range: MarkRange,
    trigger: TriggerKind = .manual
  ) async throws -> SessionDescriptor {
    try await validate(sources: sources)
    let (startInstant, endInstant) = resolve(range)
    let descriptor = SessionDescriptor(
      schema: schema,
      id: sessionID(start: startInstant, slug: slug),
      slug: slug,
      sources: sources,
      start: startInstant,
      end: endInstant,
      state: .closed,
      trigger: trigger,
      vocab: nil
    )
    try SessionStore.write(descriptor, dataRoot: dataRoot)
    sessions[descriptor.id] = descriptor
    // A mark comes into existence already closed, so a single `closed` event
    // announces it — there was never an open interval to announce.
    await eventSink?(.session(SessionSummary(descriptor)))
    return descriptor
  }

  /// Validates `sources` per `open`/`mark`'s shared rule: non-empty, and
  /// every id known to ``knownSourceIDs``.
  ///
  /// - Throws: ``SessionRegistryError/noSources`` if `sources` is empty;
  ///   ``SessionRegistryError/unknownSource(_:)`` for the first id
  ///   ``knownSourceIDs`` doesn't recognize.
  private func validate(sources: [SourceID]) async throws {
    guard !sources.isEmpty else { throw SessionRegistryError.noSources }
    let known = await knownSourceIDs()
    for source in sources where !known.contains(source) {
      throw SessionRegistryError.unknownSource(source)
    }
  }

  /// Resolves a `mark` request's ``MarkRange`` to a concrete `[start, end)`
  /// pair using ``clock``.
  private func resolve(_ range: MarkRange) -> (start: Instant, end: Instant) {
    switch range {
    case .lastSeconds(let seconds):
      let now = clock.now()
      return (now.advanced(by: -seconds), now)
    case .absolute(let start, let end):
      return (start, end)
    }
  }

  /// Allocates a session id per `docs/data-formats.md`'s
  /// `<start-timestamp>_<slug>` convention.
  private func sessionID(start: Instant, slug: String) -> String {
    "\(FilenameTimestampCodec.string(for: start))_\(slug)"
  }
}
