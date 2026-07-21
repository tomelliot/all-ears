# Distribution & packaging

## Today

There are no packaged (signed, notarized) builds yet, but there is a supported source install: clone the repo and run `make install` from the root (see the [README](../README.md)). It builds `swift build -c release`, signs the binaries, installs the five tools to `$PREFIX/bin` (default `~/.local/bin`), and registers `earsd` as a per-user launchd `LaunchAgent`. `make uninstall` reverses it, leaving user data in place. CI (`.github/workflows/ci.yml`) lint-checks formatting, builds, and runs the test suite on every commit; there is no release or notarization job yet.

The install is a plain [`Makefile`](../Makefile) plus a small plist template ([`packaging/net.tomelliot.ears.earsd.plist.in`](../packaging/net.tomelliot.ears.earsd.plist.in), `@PREFIX@`/`@HOME@` substituted at install time) and an entitlements file ([`packaging/earsd.entitlements`](../packaging/earsd.entitlements)) — no external tooling beyond `swift`, `codesign`, and `launchctl`:

- **LaunchAgent.** `~/Library/LaunchAgents/net.tomelliot.ears.earsd.plist`, `RunAtLoad` + `KeepAlive` (`SuccessfulExit = false`, so a clean stop stays stopped). Its `EnvironmentVariables.PATH` includes the install `bin` dir so the meeting `on_end` hook — which shells out via `/usr/bin/env transcribe` — resolves the CLI instead of failing with exit 127. Loaded with `launchctl bootstrap gui/$UID`; a reinstall does `bootout` then `bootstrap` so the new binary is picked up. The template file is the authoritative installed plist; `LaunchAgentPlist`/`LaunchAgentInstallLocation` in `EarsCore` generate a close in-process equivalent (label, `RunAtLoad`, `KeepAlive`, crash-log paths) kept for a future `SMAppService`-based registration — note that path would still need to add the `EnvironmentVariables.PATH` the template carries.
- **Signing.** `codesign --force --options runtime` with the audio-input entitlement on `earsd` (and Hardened Runtime on the CLIs). Pass `SIGN_IDENTITY="Developer ID Application: …"` for a stable identity so the mic/system-audio TCC grant survives reinstalls; otherwise it falls back to ad-hoc (`--sign -`) with a printed warning that macOS may re-prompt. `earsd` embeds an `Info.plist` (`NSMicrophoneUsageDescription`) into its `__TEXT,__info_plist` section so the mic prompt has a usage string.
- Run `earsd` directly instead (no agent) if you prefer — see the [soak runbook](./operations/capture-soak-runbook.md).

Permissions are requested on first use: microphone, and for `system`/`app:` sources the system-audio-recording grant. There is no query API for the tap grant, so the daemon probes real state (create-and-destroy a throwaway tap, detect the all-zero PCM a denied tap returns) and names the exact Settings pane — macOS 15's "System Audio Recording Only" — on denial.

## The bar for distributed builds

When builds ship, they ship properly — no ad-hoc signing, no telling users to strip quarantine attributes:

- **Developer ID signing + notarization** for every distributed binary, Hardened Runtime enabled, minimal entitlements, ticket stapled in CI so first launch never stalls on a Gatekeeper check.
- **Launch-agent registration via `SMAppService`**, with the configured launch-at-login state reconciled against `SMAppService.status` rather than trusted. Uninstall unregisters the agent and stops capture.
- **Model assets** (FluidAudio/Parakeet Core ML weights) downloaded with resume-on-interruption and auto-recovery of a corrupt compiled model by re-download.
- Release artifacts reproducible from a tagged commit; tool and model versions recorded in startup logs and transcript frontmatter.
