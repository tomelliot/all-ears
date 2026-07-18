import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import EarsDaemonKit
import Foundation

/// The env var a test harness sets on a **spawned child process** to divert
/// every source's capture backend to a scripted synthetic one -- see
/// ``realCaptureBackendFactory()``'s doc comment for the full rationale.
///
/// **Test-only escape hatch, never a real user-facing config option --
/// deliberately *not* `EARS_`-prefixed.** `docs/configuration.md`'s env-var
/// layer (``configLayer(fromEnvironment:)`` in `EarsConfig`) sweeps up *every*
/// environment variable whose name starts with `EARS_` (except `EARS_CONFIG`)
/// and validates it as a real config key -- confirmed the hard way: naming
/// this `EARS_CAPTURE_BACKEND` made a real spawned `earsd` fail to start with
/// `error: invalid config: - capture_backend: unknown key`, since the loader
/// doesn't distinguish "an env var that happens to start with EARS_" from
/// "an env var meaning to set config." So this cannot use that prefix at all,
/// not even as a look-alike -- it uses `ALLEARS_` (this package's name,
/// `AllEars`) instead, which `configLayer(fromEnvironment:)`'s `EARS_` prefix
/// check does not match, so the loader ignores it entirely and it never
/// reaches schema validation. It has no entry in `docs/configuration.md`'s
/// reference and `--print-config` (which echoes only real layered config)
/// never reflects it either. Only a test harness ever sets this, on its own
/// spawned child process's environment -- never documented or advertised to
/// a real user.
let syntheticCaptureBackendEnvironmentKey = "ALLEARS_CAPTURE_BACKEND"

/// The real, mic-only ``CaptureBackendFactory`` `earsd`'s normal-run path
/// wires into ``EarsDaemon``.
///
/// Every descriptor ``DaemonConfigResolution`` hands ``EarsDaemon`` is
/// already filtered to `.mic`-class sources (see that type's non-mic
/// skipping), so this normally always builds a real
/// `EarsCaptureKit.MicCaptureBackend` tapping the live input device --
/// Phase 1's only supported capture class; per-app/system taps are out of
/// scope until a later phase.
///
/// Building the backend itself touches no TCC or live audio (see
/// `RealMicSourceProvider`'s doc comment: constructing it and even calling
/// `makeCaptureEngine()` prompts nothing) -- only `CaptureActor.start()`
/// later calling into it does, and only when `earsd` actually runs, never in
/// this task's own tests.
///
/// **Test-only escape hatch:** if the process environment sets
/// `\(syntheticCaptureBackendEnvironmentKey)=synthetic`, this instead returns
/// a factory that hands back a scripted, deterministic
/// `EarsCoreTestSupport.SyntheticCaptureBackend` for *every* source,
/// regardless of its configured `class` -- letting a test spawn a real,
/// built `earsd` binary and prove audio actually flows end-to-end (chunks
/// encoded, index entries appended, files landing on disk) without ever
/// touching Core Audio or prompting TCC. `earsd`'s own normal invocation
/// never sets this; only a test harness does, on its own spawned child
/// process's environment (see `CLISmokeTests`).
func realCaptureBackendFactory() -> CaptureBackendFactory {
  guard ProcessInfo.processInfo.environment[syntheticCaptureBackendEnvironmentKey] == "synthetic"
  else {
    return { descriptor in
      MicCaptureBackend(source: descriptor.id, provider: RealMicSourceProvider())
    }
  }
  return { descriptor in
    // Two seconds of above-VAD-threshold audio: enough for `CaptureActor`'s
    // shutdown flush (`stop()`) to always finalize and index at least one
    // real chunk, whatever `chunk_seconds` the test config carries.
    SyntheticCaptureBackend(
      source: descriptor.id,
      sampleCount: descriptor.nativeSampleRate * 2,
      value: 0.5,
      sampleRate: descriptor.nativeSampleRate)
  }
}
