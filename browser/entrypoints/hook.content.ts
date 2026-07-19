import { defineContentScript } from "#imports";
import { claimEpoch } from "../lib/epoch";
import { installHook } from "../lib/rtc-hook";
import { initCapture, __devCaptureStream } from "../lib/audio-tap";
import { selectAdapter, type PlatformAdapter } from "../lib/identity/adapter";
import { MeetMeetingIdWatcher } from "../lib/identity/meet-meeting-id";
import { isControlEnvelope, isMainEnvelope, postToIsolated, type Platform } from "../lib/protocol";
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
    let stopMeetingWatch: (() => void) | null = null;
    window.addEventListener("message", (event: MessageEvent) => {
      if (event.source !== window) return; // only same-window
      if (!isControlEnvelope(event.data)) return;
      const msg = event.data.msg;
      if (msg.kind !== "capture-state" || msg.enabled === captureOn) return;
      captureOn = msg.enabled;
      if (captureOn) {
        startEpoch(platform, adapter);
        stopMeetingWatch?.();
        stopMeetingWatch = startMeetingWatch(platform);
      } else {
        stopCapture();
        stopMeetingWatch?.();
        stopMeetingWatch = null;
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

// How long the meeting-id watcher stays quiet before logging its one
// soft-fail warning. It keeps watching afterwards — the id can still resolve
// late (e.g. tiles mounting slowly) and capture is never gated on it.
const MEETING_ID_POLL_MS = 1000;
const MEETING_ID_SOFT_FAIL_MS = 15_000;

/**
 * Meeting start/end marking (Meet only today). Watches both external-id
 * surfaces — tile DOM polling, plus the participant-joined traffic audio-tap
 * already posts (which carries collections-upgraded device ids) — and fires
 * `meeting-started` once the spaces/<space> id resolves; the returned stop
 * function fires `meeting-ended` (capture toggled off, teardown). Soft-fails
 * by design: an unresolved id logs once and skips marking; capture is never
 * blocked or delayed (identity's standing contract, see meet.ts).
 */
function startMeetingWatch(platform: Platform): () => void {
  if (platform !== "meet") return () => {};

  const watcher = new MeetMeetingIdWatcher((spaceId) => {
    console.log(`[ears] Meet meeting id resolved: ${spaceId}`);
    postToIsolated({ kind: "meeting-started", platform, externalMeetingId: spaceId });
  });

  const onMessage = (event: MessageEvent): void => {
    if (event.source !== window || !isMainEnvelope(event.data)) return;
    const msg = event.data.msg;
    if (msg.kind === "participant-joined") watcher.observeCandidate(msg.participantId);
  };
  window.addEventListener("message", onMessage);

  const startedAt = Date.now();
  let warned = false;
  watcher.poll(document);
  const interval = setInterval(() => {
    watcher.poll(document);
    if (watcher.spaceId) {
      clearInterval(interval);
      return;
    }
    if (!warned && Date.now() - startedAt > MEETING_ID_SOFT_FAIL_MS) {
      warned = true;
      console.warn(
        "[ears] Meet meeting id has not resolved yet — the meeting can't be marked until it does; capture is unaffected",
      );
    }
  }, MEETING_ID_POLL_MS);

  return () => {
    clearInterval(interval);
    window.removeEventListener("message", onMessage);
    const spaceId = watcher.spaceId;
    if (spaceId) {
      postToIsolated({ kind: "meeting-ended", platform, externalMeetingId: spaceId });
    }
  };
}

function platformForHost(host: string, adapter: PlatformAdapter | null): Platform {
  if (adapter) return adapter.platform;
  if (host === "meet.google.com") return "meet";
  if (host.endsWith("zoom.us")) return "zoom";
  return "teams";
}
