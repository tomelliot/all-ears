import { defineContentScript } from "#imports";
import { claimEpoch } from "../lib/epoch";
import { installHook } from "../lib/rtc-hook";
import { initCapture, __devCaptureStream } from "../lib/audio-tap";
import { selectAdapter, type PlatformAdapter } from "../lib/identity/adapter";
import type { Platform } from "../lib/protocol";
// Side-effect imports: each adapter registers itself with selectAdapter.
import "../lib/identity/meet";
import "../lib/identity/zoom";
import "../lib/identity/teams";

// MAIN-world hook. Registered as a content script so the browser runs it at
// document_start, in the page realm, BEFORE any page script — no fetch race.
// This is what wins the constructor race against Zoom's bootstrap caching
// (verified: injectScript's async <script src> lost that race; see journal).
// The isolated-world relay lives in content.ts.
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

    startEpoch(platform, adapter);

    // Dev-only: simulate a re-injection (new epoch in the same realm) so the
    // harness can verify the capture-epoch handoff doesn't double streams.
    if (import.meta.env.WXT_DEV_LOCALHOST) {
      const dev = window as unknown as {
        __earsDevReinit?: () => void;
        __earsDevCapture?: (stream: MediaStream, id: string) => void;
      };
      dev.__earsDevReinit = () => startEpoch(platform, adapter);
      dev.__earsDevCapture = (stream, id) => __devCaptureStream(stream, id);
    }
  },
});

function startEpoch(platform: Platform, adapter: PlatformAdapter | null): void {
  const epoch = claimEpoch();
  initCapture({ epoch, platform, adapter });
}

function platformForHost(host: string, adapter: PlatformAdapter | null): Platform {
  if (adapter) return adapter.platform;
  if (host === "meet.google.com") return "meet";
  if (host.endsWith("zoom.us")) return "zoom";
  return "teams";
}
