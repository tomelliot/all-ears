/// Cross-actor design notes for `earsd`'s three orchestration actors —
/// ``CaptureActor``, ``SessionRegistry``, and ``ControlServer`` — whose
/// interface stubs live alongside this file. These notes lock the contracts
/// three parallel implementation tasks fill in, so they don't re-negotiate the
/// API mid-flight. `docs/architecture.md`'s "Concurrency & runtime model" and
/// "Sessions" sections and `docs/specs/capture-daemon.md` are the source of
/// truth; the decisions recorded here resolve the ambiguities those leave open.
///
/// ## Actor decomposition (from `docs/architecture.md`)
///
/// - One ``CaptureActor`` **per source**: owns that source's capture backend,
///   `ChunkEncoder`, `IndexAppender`, and `VAD`. Sources are independent, so a
///   per-source actor isolates one source's failure/teardown from another's.
/// - One ``SessionRegistry`` owning session descriptors (the actor the
///   architecture doc calls the "`SessionStore` actor" — renamed here to avoid
///   colliding with `EarsDataStore.SessionStore`, the thin `session.toml`
///   file-I/O enum this actor *uses* for persistence).
/// - One ``ControlServer`` owning control-socket command dispatch: it plugs
///   into `EarsIPC.ControlSocketServer`'s request-handler seam and routes each
///   of the `ControlRequest` commands to the right actor method. It is
///   deliberately thin wiring — the real work lives in the other two actors.
///
/// ## Sessions are metadata, not a separate recording
///
/// `docs/architecture.md`'s "Sessions" section is explicit: opening a session
/// "records a session descriptor referencing the live time range; capture
/// itself is unchanged (sessions are metadata over the ring buffer, not a
/// separate recording)". Two consequences drive these contracts:
///
/// 1. ``SessionRegistry`` holds **no reference to any ``CaptureActor``**.
///    `session.open`/`session.close`/`mark` never start, stop, pause, or
///    otherwise touch capture — every enabled source is *already*
///    continuously capturing regardless of any session. The registry only
///    validates the named source ids exist (via an injected seam, not a
///    `CaptureActor` handle — see ``SessionRegistry``) and reads/writes
///    descriptors.
/// 2. `capture.pause`/`capture.resume` and session lifecycle are **fully
///    decoupled**. Pausing a source while a session is open on it needs no
///    cross-actor coordination: the pause simply lands a `gap` in that source's
///    `index.jsonl` (see ``CaptureActor``'s pause contract), and the session's
///    `end` is still set independently by a later `session.close`. A
///    paused-and-resumed source with an open session just has a gap in its
///    index for the paused interval — expected and fine. A reader
///    reconstructing the session's range (via `EarsCore`'s `RangeReconstructor`)
///    already models gaps as first-class, so nothing downstream breaks.
///
/// ## Domain / wire split
///
/// Following the split this codebase already draws between domain types and
/// their control-socket wire shapes (`SessionDescriptor` ↔ `SessionSummary`,
/// `IndexedChunk` ↔ `IndexEvent.chunk`), the two logic actors return **domain**
/// types and ``ControlServer`` converts to wire payloads at the socket boundary:
///
/// - ``CaptureActor/status()`` returns the domain ``CaptureSourceStatus``;
///   ``ControlServer`` maps it to the wire `SourceStatus`.
/// - ``SessionRegistry`` returns domain `SessionDescriptor`s; ``ControlServer``
///   maps them to `SessionSummary` / `SessionOpenData` for the wire.
public enum ActorContracts {
  /// The `session.toml` schema version new sessions are written with, per
  /// `docs/data-formats.md`'s `session.toml` example (`schema = 1`). Injected
  /// into ``SessionRegistry`` so the constant lives in one place.
  public static let sessionSchemaVersion = 1
}
