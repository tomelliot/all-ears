// The user-facing capture on/off toggle (popup ⇄ storage ⇄ content scripts).
//
// Persistence area choice — `storage.local`, not `storage.session`, on purpose:
// turning OFF an audio-capture extension is explicit privacy intent, and least
// surprise says it must survive a browser restart rather than silently
// re-arming. (`storage.session` is still used for *worker-respawn* recovery
// state — see session-state.ts — which is a different concern: that state
// SHOULD die with the browsing session.)
//
// How the toggle actually gates capture: the MAIN-world hook has no extension
// APIs, so it can't read this key itself. content.ts (isolated world) reads it,
// posts a `capture-state` control message across the world boundary
// (protocol.ts), and re-posts on every storage change. hook.content.ts defers
// startEpoch() until that message arrives and tears capture down when it flips
// to off. The constructor hook itself always installs regardless — it's
// passive, and it must win the document_start race so that toggling ON
// mid-call can still adopt the already-live track registry.

export const CAPTURE_ENABLED_KEY = "captureEnabled";

/**
 * Storage key the popup's "Report state" button nudges to trigger a MAIN-world
 * debug dump. Written with a fresh timestamp each click so `storage.onChanged`
 * always fires; content.ts forwards a `report-state` control message to the
 * MAIN world, which logs `[ears][debug][state]` in that tab's console. Reuses
 * the same popup ⇄ storage ⇄ content path as the capture toggle — every open
 * meeting tab reports, and no permission beyond `storage` is needed.
 */
export const DEBUG_REPORT_KEY = "debugReportNonce";

/**
 * Boolean flag (storage.local) gating debug logging. When true, every context
 * tees its `console.*` output into a persisted IndexedDB ring (log-store.ts)
 * the popup can export as a file; the MAIN-world hook learns the flag over the
 * same control channel as the capture toggle. Off by default — a missing key,
 * a failed read, or any non-`true` value means no logs are captured, so debug
 * capture is never silently left running.
 */
export const DEBUG_LOG_KEY = "debugLogging";

/**
 * Resolve the raw stored value to the effective toggle state. Capture defaults
 * to ON: only an explicit stored `false` disables it, so a missing key (fresh
 * install), a failed read, or a corrupt value never silently kills capture.
 */
export function resolveCaptureToggleState(raw: unknown): boolean {
  return raw !== false;
}
