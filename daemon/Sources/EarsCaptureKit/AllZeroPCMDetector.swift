/// Pure detection of an all-zero (silent) PCM stream — the heuristic
/// `docs/specs/capture-daemon.md`'s "Permissions and TCC probing"
/// section calls for, since there is no query API for the system-audio tap's
/// TCC grant: a denied tap still "succeeds" at the API level but delivers a
/// stream of all-zero samples.
///
/// Shared by the TCC probe (``SystemAudioPermissionProvider``, a throwaway
/// create-and-destroy tap) and ``SystemAudioCaptureBackend``'s own start-time
/// denial check (the real, long-lived tap), so the heuristic lives in one
/// place.
///
/// **Documented limitation, inherited from the spec, not solved here:**
/// genuine silence (nothing currently playing) is indistinguishable from a
/// denied tap by this signal alone. The only mitigation is sampling a window
/// of real callbacks rather than a single buffer — still imperfect, but
/// least likely to misfire on a single quiet moment. Callers needing higher
/// confidence should widen the window they sample over, not add a different
/// heuristic here.
public enum AllZeroPCMDetector {
  /// `true` if every sample in `samples` is exactly `0`. An empty buffer is
  /// treated as all-zero (no evidence of real audio).
  public static func isAllZero(_ samples: [Float]) -> Bool {
    samples.allSatisfy { $0 == 0 }
  }

  /// `true` only if *every* buffer in `window` is all-zero — the "sample a
  /// window of callbacks" mitigation from the type doc: a single silent
  /// buffer proves nothing, but a whole window of them, backed by no
  /// non-zero buffer at all, is the strongest signal available without a
  /// real query API.
  public static func isAllZero(window: [[Float]]) -> Bool {
    !window.isEmpty && window.allSatisfy(isAllZero)
  }
}
