/// The permission seam: query and request the macOS privacy grants a source
/// needs, so a denial can disable just that source rather than the daemon.
///
/// - Design rationale (no Swift signature exists in the docs; shaped from
///   `docs/specs/capture-daemon.md`'s "Permissions and TCC probing"): the daemon
///   must poll *real* permission state (never fake it with timers), and for the
///   system-audio tap there is no query API — the grant is probed by creating and
///   destroying a throwaway tap and detecting an all-zero PCM stream. Both
///   `status` and `request` are therefore `async` (probing does real work) and
///   keyed by a ``Permission`` case, keeping the platform TCC machinery behind a
///   mockable seam. Returning a ``PermissionStatus`` (rather than a bare `Bool`)
///   preserves the not-determined vs denied vs restricted distinction the daemon
///   needs to choose between prompting and emitting an actionable settings-pane
///   message.
///
/// - Phase 1 (`EarsCaptureKit.MicrophonePermissionProvider`, wired into a
///   real running `earsd`) proved this shape unchanged for the queryable
///   half: ``status(for:)``/``request(_:)`` are still the whole protocol,
///   with no new members. That conformance only covers `.microphone`, though
///   -- `.systemAudio` still resolves to `.notDetermined` there, deferred to
///   the later system-audio tap probe task. So the concerns this doc comment
///   originally raised about *that* probe -- its side-effecting cost,
///   coordination among sources, or an `AsyncStream` of status changes for a
///   mid-run revocation -- remain genuinely open, not yet built or exercised,
///   rather than resolved. The ``Permission`` case set likewise hasn't grown
///   yet, for the same reason: no source class beyond mic has landed since
///   Phase 0.
public protocol PermissionProviding: Sendable {
  /// The current status of `permission`, resolved by real probing (no cached
  /// guess).
  func status(for permission: Permission) async -> PermissionStatus

  /// Request `permission` (prompting where the platform allows) and return the
  /// resulting status.
  func request(_ permission: Permission) async -> PermissionStatus
}
