import { defineContentScript } from "#imports";
import { claimEpoch } from "../lib/epoch";
import { installHook } from "../lib/rtc-hook";
import { initCapture, __devCaptureStream } from "../lib/audio-tap";
import { selectAdapter, type PlatformAdapter } from "../lib/identity/adapter";
import { isControlEnvelope, type Platform } from "../lib/protocol";
// Side-effect imports: each adapter registers itself with selectAdapter.
import "../lib/identity/meet";
import "../lib/identity/zoom";
import "../lib/identity/teams";

// MAIN-world hook. Registered as a content script so the browser runs it at
// document_start, in the page realm, BEFORE any page script — no fetch race.
// This is what wins the constructor race against Zoom's bootstrap caching
// (verified: injectScript's async <script src> lost that race; see journal).
// The isolated-world relay lives in content.ts.
//
// Capture on/off gate (Phase 7). The toggle lives in storage.local
// (capture-toggle.ts), which this MAIN-world script cannot read — so the hook
// installs unconditionally (passive: it only registers tracks, captures
// nothing) and capture WAITS for content.ts to post the persisted toggle
// state across the world boundary as a `capture-state` control message.
// Chosen over the alternatives because:
//   - The hook must install at document_start regardless of the toggle: if it
//     skipped installation while off, toggling ON mid-call could never work
//     (the page has long since cached the native constructor — Zoom-style).
//     With the hook always resident, enabling capture just starts an epoch,
//     which adopts the hook's live-track registry — mid-call ON is seamless.
//   - Waiting for the async storage read costs nothing: startEpoch() replays
//     liveTracks() on start, so tracks arriving before the state message are
//     picked up then, not lost.
// Toggling OFF claims a fresh epoch WITHOUT starting capture on it: every
// existing pipeline's isCurrentEpoch() check goes false (no new tracks) and
// the superseded epoch's teardown stops the live ones — the exact same
// supersede path a re-injection uses, no new machinery in audio-tap.ts.
export default defineContentScript({
  matches: [
    "https://meet.google.com/*",
    "https://*.zoom.us/*",
    "https://teams.microsoft.com/*",
    // Dev harness (dev/); stripped unless WXT_DEV_LOCALHOST is set at build.
    ...(import.meta.env.WXT_DEV_LOCALHOST ? ["http://localhost/*", "http://127.0.0.1/*"] : []),
  ],
  runAt: "document_start",
  world: "MAIN",
  main() {
    installHook();

    const host = location.host;
    const adapter = selectAdapter(host);
    const platform = platformForHost(host, adapter);
    if (!adapter) console.warn(`[ears] no identity adapter for ${host} — using speaker-<n>`);

    let captureOn = false;
    window.addEventListener("message", (event: MessageEvent) => {
      if (event.source !== window) return; // only same-window
      if (!isControlEnvelope(event.data)) return;
      const msg = event.data.msg;
      if (msg.kind !== "capture-state" || msg.enabled === captureOn) return;
      captureOn = msg.enabled;
      if (captureOn) {
        startEpoch(platform, adapter);
      } else {
        stopCapture();
      }
    });

    // Dev-only: simulate a re-injection (new epoch in the same realm) so the
    // harness can verify the capture-epoch handoff doesn't double streams.
    if (import.meta.env.WXT_DEV_LOCALHOST) {
      const dev = window as unknown as {
        __earsDevReinit?: () => void;
        __earsDevCapture?: (stream: MediaStream, id: string) => void;
      };
      dev.__earsDevReinit = () => {
        if (captureOn) startEpoch(platform, adapter);
      };
      dev.__earsDevCapture = (stream, id) => __devCaptureStream(stream, id);
    }
  },
});

function startEpoch(platform: Platform, adapter: PlatformAdapter | null): void {
  const epoch = claimEpoch();
  initCapture({ epoch, platform, adapter });
}

/** See the gate comment above: fresh unowned epoch + superseded teardown. */
function stopCapture(): void {
  claimEpoch();
  (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
  console.log("[ears] capture disabled — epoch released, pipelines torn down");
}

function platformForHost(host: string, adapter: PlatformAdapter | null): Platform {
  if (adapter) return adapter.platform;
  if (host === "meet.google.com") return "meet";
  if (host.endsWith("zoom.us")) return "zoom";
  return "teams";
}
