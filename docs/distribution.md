# Distribution & packaging

## Today

There are no packaged builds: clone the repo and `swift build -c release` in `daemon/` (see the [README](../README.md)). CI (`.github/workflows/ci.yml`) lint-checks formatting, builds, and runs the test suite on every commit; there is no release or notarization job yet.

`earsd` is designed to run as a per-user launchd `LaunchAgent` (`RunAtLoad` + `KeepAlive`). The daemon can generate the agent plist content (`LaunchAgentPlist` in `EarsCore`), but writing it to disk and registering it — via `SMAppService` or `launchctl` — is still a manual step. Until then, run `earsd` directly (see the [soak runbook](./operations/capture-soak-runbook.md) for a working setup).

Permissions are requested on first use: microphone, and for `system`/`app:` sources the system-audio-recording grant. There is no query API for the tap grant, so the daemon probes real state (create-and-destroy a throwaway tap, detect the all-zero PCM a denied tap returns) and names the exact Settings pane — macOS 15's "System Audio Recording Only" — on denial.

## The bar for distributed builds

When builds ship, they ship properly — no ad-hoc signing, no telling users to strip quarantine attributes:

- **Developer ID signing + notarization** for every distributed binary, Hardened Runtime enabled, minimal entitlements, ticket stapled in CI so first launch never stalls on a Gatekeeper check.
- **Launch-agent registration via `SMAppService`**, with the configured launch-at-login state reconciled against `SMAppService.status` rather than trusted. Uninstall unregisters the agent and stops capture.
- **Model assets** (FluidAudio/Parakeet Core ML weights) downloaded with resume-on-interruption and auto-recovery of a corrupt compiled model by re-download.
- Release artifacts reproducible from a tagged commit; tool and model versions recorded in startup logs and transcript frontmatter.
