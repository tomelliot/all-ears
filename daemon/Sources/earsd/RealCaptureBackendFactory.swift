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

/// The real ``CaptureBackendFactory`` `earsd`'s normal-run path wires into
/// ``EarsDaemon``: dispatches on `descriptor.sourceClass` to a real
/// `EarsCaptureKit.MicCaptureBackend` (`.mic`) or
/// `EarsCaptureKit.SystemAudioCaptureBackend` (`.system`/`.app`, the Core
/// Audio process-tap backend, per `docs/specs/capture-daemon.md`).
/// `DaemonConfigResolution` never resolves any other class into a
/// config-declared `SourceDescriptor` (a `browser:*` source is instead built
/// dynamically by `EarsDaemon.openIngestSource(label:format:)`, and
/// `device:*` stays unsupported and is filtered out at config-resolution
/// time), so those two cases are this factory's whole real surface.
///
/// Building any backend here touches no TCC or live audio yet (see
/// `RealMicSourceProvider`'s and `RealProcessTapProvider`'s own doc
/// comments: constructing a backend prompts nothing) -- only
/// `CaptureActor.start()` later calling into it does, and only when `earsd`
/// actually runs, never in this task's own tests.
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
      switch descriptor.sourceClass {
      case .mic:
        // Pass the configured device UID through; with none set,
        // RealMicSourceProvider prefers the built-in mic over the system
        // default input, so a connected Bluetooth headset is never captured
        // (and so never forced off A2DP) unless explicitly named.
        return MicCaptureBackend(
          source: descriptor.id,
          provider: RealMicSourceProvider(deviceUID: descriptor.deviceUID))
      case .system:
        return SystemAudioCaptureBackend(source: descriptor.id, mode: .system)
      case .app:
        // Resolved fresh at build time, not cached: the target app may not
        // even be running yet when earsd starts (its source still captures
        // -- just silence -- until the app launches), and
        // SystemAudioCaptureBackend itself keeps this current afterward via
        // its own launch/terminate tracking.
        let bundleID = descriptor.id.detail ?? ""
        let pids = RealRunningApplicationTracker().livePIDs(forBundleID: bundleID)
        return SystemAudioCaptureBackend(
          source: descriptor.id, mode: .app(pids: pids), bundleID: bundleID)
      case .browser, .device:
        preconditionFailure(
          "unreachable: DaemonConfigResolution never resolves a '\(descriptor.sourceClass)' "
            + "config-declared source; browser:* sources are built dynamically via "
            + "openIngestSource, and device:* is filtered out at config-resolution time"
        )
      }
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
