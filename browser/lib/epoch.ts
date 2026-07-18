// Idempotent-install guard + capture epoch.
//
// Re-injection (SPA navigation, extension reload) runs injected.js again in the
// same realm. Two guards keep that from doubling audio:
//
//   1. __earsHookInstalled — the RTCPeerConnection wrapper is installed exactly
//      once per realm. A second install no-ops so we never wrap the wrapper.
//   2. __earsEpoch — a monotonic counter. Each injected.ts instance claims a
//      higher epoch on load; only the newest epoch emits PCM. Superseded
//      instances observe a higher epoch and tear down. This is what makes a
//      re-inject supersede rather than duplicate the live capture.
//
// The two are separate on purpose: the constructor wrapper must survive across
// epochs (the page keeps the same patched constructor), while capture ownership
// moves to the newest epoch.

const INSTALLED_KEY = "__earsHookInstalled";
const EPOCH_KEY = "__earsEpoch";

interface EpochWindow {
  [INSTALLED_KEY]?: boolean;
  [EPOCH_KEY]?: number;
}

function w(): EpochWindow {
  return window as unknown as EpochWindow;
}

/** True on the first call in a realm; false (already installed) thereafter. */
export function claimInstall(): boolean {
  if (w()[INSTALLED_KEY]) return false;
  w()[INSTALLED_KEY] = true;
  return true;
}

/** Claim a fresh, strictly-higher epoch. The newest claimant owns capture. */
export function claimEpoch(): number {
  const next = (w()[EPOCH_KEY] ?? 0) + 1;
  w()[EPOCH_KEY] = next;
  return next;
}

/** True while `epoch` is still the newest claimed — i.e. this instance owns capture. */
export function isCurrentEpoch(epoch: number): boolean {
  return w()[EPOCH_KEY] === epoch;
}
