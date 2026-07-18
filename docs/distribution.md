# Distribution & packaging

Signing and notarization are planned from day one, not bolted on before release. Ad-hoc signing without notarization is a repeated dead end in the survey — every tool that shipped it also shipped Gatekeeper workarounds (`xattr -cr` instructions to users) and macOS-26 first-launch stalls. We avoid that debt by building the pipeline early, even while the binaries are pre-release.

## Signing & notarization

- **Developer ID Application signing + notarization** for every distributed binary (`earsd`, `ears`, `transcribe`, `cleanup`, `summarize`) and any bundled model/helper.
- **Hardened Runtime** enabled, with the minimal entitlements each tool needs (microphone; audio capture for the tap; no more).
- Notarize and **staple** the ticket in CI as part of the release job, so first launch never stalls on a Gatekeeper network check.
- No instructions that ask users to strip quarantine attributes — if that would be needed, the build is wrong.

## The daemon as a launch agent

- `earsd` ships as a launchd **`LaunchAgent`** (per-user, not a system daemon): `RunAtLoad` + `KeepAlive`.
- Installation registers the agent via **`SMAppService`**, and the tool **reconciles the configured launch-at-login state against `SMAppService.status`**, surfacing mismatches rather than trusting the preference (a documented failure mode in the survey).
- Uninstall cleanly unregisters the agent and stops capture; it does not silently leave a running background process.

## Permissions at install/first-run

- Microphone and system-audio-capture (tap) grants are requested on first use, with actionable messaging that names the exact Settings pane — including macOS 15's **"System Audio Recording Only"** sub-pane — per the [capture-daemon spec](./specs/capture-daemon.md#permissions-and-tcc-probing).
- Because there is no query API for the tap TCC grant, the installer/first-run flow uses the create-and-destroy-a-tap probe to determine real state rather than assuming.

## Model assets

- FluidAudio/Parakeet Core ML weights are downloaded to the app container (`XDG_CACHE_HOME` set into the sandbox), with **resume on interruption** and **auto-recovery** of a corrupt compiled model by re-download.
- Subprocess-backend weights are **pinned to exact Hugging Face commits**, with include-pattern lists kept in sync with the loader.

## Build & release hygiene

- `.swift-format` + a pre-commit hook enforce style; CI runs the full test suite and the model-accuracy benchmarks (WER/DER/RTFx) on every commit — see [engineering practices](./engineering-practices.md).
- Release artifacts are reproducible from a tagged commit; version and model versions are recorded in each tool's startup log and in transcript frontmatter.
