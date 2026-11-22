// The effectful half of the attribution flight recorder: a per-call ring of
// encoded events shared across epochs, exportable on demand, and batched
// toward the daemon.
//
// State lives on `window` (same pattern as rtc-hook.ts's `__earsLiveTracks`
// and audio-tap.ts's `__earsAudioLog`): a re-injected epoch loads a fresh
// module instance, but the hook functions installed by the first injection
// keep closing over the first bundle's modules — a window-global is the one
// place both write to. Everything here is best-effort by contract: recording
// evidence must never throw into the capture or identity paths.
//
// Two rings, one type:
//   - the EXPORT ring keeps the last ATTRIBUTION_RING_CAPACITY events for
//     on-demand export (`window.__earsExportAttribution()`);
//   - the PENDING ring holds events awaiting shipment to the daemon. Flushes
//     ride audio-tap.ts's existing 3s reconcile sweep (no timer of their own)
//     plus a size threshold, posting an `attribution` MainMessage the relay
//     and background forward to earsd as `ingest.attribution`.

import { AttributionRing, encodeAttributionEvent, type AttributionEvent } from "./attribution-log";
import { postToIsolated, type Platform } from "./protocol";

/** Ship a pending batch as soon as it reaches this many events rather than
 * waiting for the next 3s sweep — a burst's evidence reaches disk promptly
 * without this module owning a timer. */
export const ATTRIBUTION_FLUSH_THRESHOLD = 25;

/** Much smaller than the export ring: it only covers the window between
 * flushes, and anything it ever drops is still in the export ring. */
const PENDING_CAPACITY = 200;

/** How long after `meeting-started` before the first flush. The declare rides
 * the control socket and a batch rides the ingest socket, so a batch sent at
 * once could still beat `session.start` to the daemon and be dropped. */
export const ATTRIBUTION_DECLARE_SETTLE_MS = 1000;

interface RecorderWindow extends Window {
  __earsAttributionExport?: AttributionRing;
  __earsAttributionPending?: AttributionRing;
  __earsAttributionPlatform?: Platform;
  /** When this page last declared a meeting; absent while none is live. */
  __earsAttributionLiveSince?: number;
}

/** node-test fallback (vitest runs without a `window`): module-level rings so
 * the recorder stays inert but callable. */
const fallbackExport = new AttributionRing();
const fallbackPending = new AttributionRing(PENDING_CAPACITY);

function rw(): RecorderWindow | null {
  return typeof window === "undefined" ? null : (window as unknown as RecorderWindow);
}

function exportRing(): AttributionRing {
  const g = rw();
  if (!g) return fallbackExport;
  if (!g.__earsAttributionExport) g.__earsAttributionExport = new AttributionRing();
  return g.__earsAttributionExport;
}

function pendingRing(): AttributionRing {
  const g = rw();
  if (!g) return fallbackPending;
  if (!g.__earsAttributionPending) g.__earsAttributionPending = new AttributionRing(PENDING_CAPACITY);
  return g.__earsAttributionPending;
}

/** Remember which platform this page's events belong to, so flushed batches
 * can be labelled for the daemon. Called once by hook.content.ts at load —
 * a page whose platform was never set holds its events in the bounded
 * pending ring instead of shipping them. */
export function setAttributionPlatform(platform: Platform): void {
  const g = rw();
  if (g) g.__earsAttributionPlatform = platform;
}

/**
 * Mark whether this page has a declared meeting. Until it does, flushes hold
 * events in the pending ring: the daemon drops any batch that arrives before
 * its session exists, and on Zoom, Daily and Jitsi the declare waits for the
 * first peer connection — after the admit and identity-link events that
 * matter most have already been recorded.
 */
export function setAttributionMeetingLive(live: boolean, now: number = Date.now()): void {
  const g = rw();
  if (!g) return;
  if (live) g.__earsAttributionLiveSince ??= now;
  else delete g.__earsAttributionLiveSince;
}

/**
 * Record one event: encode once, keep it in the per-call export ring, and
 * queue it for the daemon. Never throws — evidence is subordinate to capture.
 */
export function recordAttribution(event: AttributionEvent): void {
  try {
    const line = encodeAttributionEvent(event);
    exportRing().push(line);
    const pending = pendingRing();
    pending.push(line);
    if (pending.size >= ATTRIBUTION_FLUSH_THRESHOLD) flushAttribution();
  } catch {
    // best-effort — the flight recorder must never affect what it records
  }
}

/**
 * Ship the pending batch toward the daemon (MAIN → relay → background →
 * earsd). Called from audio-tap.ts's reconcile sweep and epoch teardown, and
 * from the size threshold above. Never throws.
 */
export function flushAttribution(now: number = Date.now()): void {
  try {
    const g = rw();
    const platform = g?.__earsAttributionPlatform;
    if (!platform) return;
    const liveSince = g?.__earsAttributionLiveSince;
    if (liveSince === undefined || now - liveSince < ATTRIBUTION_DECLARE_SETTLE_MS) return;
    const events = pendingRing().drain();
    if (events.length === 0) return;
    postToIsolated({ kind: "attribution", platform, events });
  } catch {
    // best-effort
  }
}

/** The whole per-call log as JSONL — the on-demand export surface
 * (`window.__earsExportAttribution()`, installed by hook.content.ts). */
export function exportAttributionLog(): string {
  return exportRing().snapshot().join("\n");
}

/** Ring counts for the popup's debug-state snapshot. */
export function attributionDebugState(): { events: number; dropped: number; pending: number } {
  return { events: exportRing().size, dropped: exportRing().dropped, pending: pendingRing().size };
}
