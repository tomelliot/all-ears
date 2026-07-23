/// Pure, dependency-free logic shared across the All Ears suite: audio-index and
/// time-cap math, VAD-index reading, transcript rendering, config merge logic, log
/// record schema, and the protocol seams (`CaptureBackend`, `Transcriber`,
/// `Diarizer`, `VAD`, `PermissionProviding`).
///
/// This target must never depend on Foundation I/O (`FileManager`, sockets,
/// networking) — only pure, deterministic, unit-testable code belongs here.
public enum EarsCore {
  /// Version of the `EarsCore` module, bumped alongside the on-disk schema
  /// versions it defines.
  public static let version = "0.1.0"
}
