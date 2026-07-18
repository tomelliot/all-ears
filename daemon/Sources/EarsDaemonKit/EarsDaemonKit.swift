/// The `earsd` daemon's real orchestration (`CaptureActor`, `ControlServer`,
/// `SessionStore`, per `docs/architecture.md`), kept as a library -- not
/// inside the `earsd` executable target -- specifically so it is
/// `@testable import`-able without spawning a process, matching how
/// `EarsCLISupport` already keeps business logic out of the executable
/// targets.
///
/// Placeholder scaffold for Phase 1 -- no behavior yet. Later Phase 1 tasks
/// add the real orchestration here.
public enum EarsDaemonKit {
  /// Version of the `EarsDaemonKit` module.
  public static let version = "0.1.0"
}
