import type { SilentDiagnosis } from "./silent-diagnosis";
// The attribution flight recorder's vocabulary: every input the attribution
// decision consumes, and every decision taken, as one typed, timestamped,
// versioned event stream (docs/plans/attribution-refactor.md R1). Recorded
// per-call in the browser, exportable on demand, and — when a daemon session
// exists — appended by earsd to `sessions/<id>/attribution.jsonl` beside
// `events.jsonl`.
//
// This module is the pure half (tier-0 per docs/engineering-practices.md):
// event types, the line encoder/decoder, and a bounded ring. No DOM, no
// postMessage, and no clock reads — `t` is always supplied by the caller. The
// effectful half (the shared per-call ring on `window`, batching to the
// daemon) lives in attribution-recorder.ts.

import type { SeamId } from "./capture-seams";
import type { ParticipantOrigin } from "./protocol";

/** Bump when an event's shape changes incompatibly. Carried on every encoded
 * line so a log sliced out of context still identifies itself. */
export const ATTRIBUTION_SCHEMA = 1;

/** Which SpeakingCorrelator produced a match (see lib/identity/meet.ts):
 * `collections` pairs the datachannel mic-open edge with decoded-audio onsets,
 * `unmute` pairs it with track-level unmute events, `dom` pairs the tile
 * speaking-ring burst with decoded-audio onsets. */
export type CorrelatorId = "collections" | "unmute" | "dom";

/** What the Meet identity engine (meet-identity-engine.ts) decided about a
 * confirmed correlator match. `bound` pushed an identity link;
 * `bound-late-rename` did the same for a track already gone when the match
 * confirmed (kept as its own outcome so the evidence stays honest);
 * the `refused-*` outcomes are the journal-#158 guards declining a match. */
export type BindingOutcome =
  | "bound"
  | "bound-late-rename"
  | "refused-local-device"
  | "refused-rebind"
  | "refused-device-claimed";

/** One roster observation. `isLocal` carries the "(You)"-marker evidence —
 * present only when the platform established it beyond doubt (see
 * protocol.ts RosterEntry). */
export interface RosterObservation {
  participantId: string;
  displayName: string;
  isLocal?: boolean;
}

/**
 * The event vocabulary — one discriminated union covering track lifecycle,
 * admission decisions, identity evidence, roster observations, and binding
 * events. Every event carries `t`, epoch ms stamped by the caller at the
 * moment the fact was observed.
 */
export type AttributionEvent =
  // ── Track lifecycle ────────────────────────────────────────────────────────
  // A track reached the capture layer for the first time. `muted` is its state
  // at dispatch (the pre-allocated-transceiver discriminator, journal #142);
  // origin/rootId are the provenance verdict when one exists (rtc-hook.ts).
  | {
      type: "track-appeared";
      t: number;
      trackId: string;
      seam: SeamId;
      muted: boolean;
      origin?: "local" | "remote";
      rootId?: string;
    }
  | { type: "track-unmuted"; t: number; trackId: string }
  | { type: "track-muted"; t: number; trackId: string }
  | { type: "track-ended"; t: number; trackId: string }
  // ── Admission decisions ────────────────────────────────────────────────────
  // A pipeline started for the track under `participantId` (generation is the
  // per-participant segment counter — an identity-upgrade restart re-admits).
  // `participantOrigin` says whether that id is the platform's own or a
  // synthetic stand-in (protocol.ts ParticipantRef); optional because schema-1
  // lines recorded before R4 predate it.
  | {
      type: "admitted";
      t: number;
      trackId: string;
      seam: SeamId;
      participantId: string;
      participantOrigin?: ParticipantOrigin;
      generation: number;
    }
  // Admission waited (muted receiver track — journal #165's phantom guard).
  | { type: "deferred"; t: number; trackId: string; seam: SeamId; reason: string }
  // A non-receiver seam adopted the track (a clone captures it).
  | { type: "adopted"; t: number; trackId: string; seam: SeamId; reason: string }
  // An adopted track was retired (classified the user's own audio).
  | { type: "retired"; t: number; trackId: string; reason: string }
  // The seam arbiter moved off a seam that produced no audio.
  | { type: "escalated"; t: number; from: string; to: string; reason: string }
  // ── Identity evidence ──────────────────────────────────────────────────────
  // A parsed Meet collections-datachannel mute edge, with the raw payload
  // bytes (base64, still gzip-compressed) so a wire-format drift can be
  // re-parsed offline against a fixed decoder.
  | { type: "collections-edge"; t: number; deviceId: string; micOpen: boolean; rawB64: string }
  // A tile speaking-ring burst onset for a device (meet-speaking-dom.ts).
  | { type: "dom-burst"; t: number; deviceId: string }
  // A decoded-audio speaking edge per track — the `__earsAudioLog` shape
  // (audio-tap.ts), always recorded rather than debug-gated.
  | {
      type: "audio-onset";
      t: number;
      participantId: string;
      trackId: string;
      state: "start" | "stop";
      framePeak: number;
    }
  // ── Roster observations ────────────────────────────────────────────────────
  | { type: "roster-delta"; t: number; entries: RosterObservation[] }
  // ── Binding events ─────────────────────────────────────────────────────────
  // A confirmed correlator match and what was decided about it, with its
  // cause: which correlator fired and how many confirming turns it counted.
  | {
      type: "provisional-binding";
      t: number;
      trackId: string;
      deviceId: string;
      correlator: CorrelatorId;
      confirmations: number;
      outcome: BindingOutcome;
    }
  // The capture layer forwarded a confirmed identity to the daemon: an
  // attendee upsert linking `captureId`'s source (`browser:<platform>:<slug>`)
  // to the platform `participantId` (R3 — identity never rides the source
  // id). `trackId` joins this to the `provisional-binding` event that caused
  // it, when one did; an admission-time identify (Zoom MSID, a Meet tile hit)
  // has no binding event and the link is its own record.
  | {
      type: "identity-link";
      t: number;
      trackId: string;
      captureId: string;
      participantId: string;
    }
  // ── Silent capture ─────────────────────────────────────────────────────────
  // The silent watchdog fired with nothing decoded on the call: the receiver's
  // stats at that moment, and the cause they point to (silent-diagnosis.ts).
  | {
      type: "silent-diagnosis";
      t: number;
      trackId: string;
      participantId: string;
      diagnosis: SilentDiagnosis;
    };

const EVENT_TYPES: ReadonlySet<string> = new Set([
  "track-appeared",
  "track-unmuted",
  "track-muted",
  "track-ended",
  "admitted",
  "deferred",
  "adopted",
  "retired",
  "escalated",
  "collections-edge",
  "dom-burst",
  "audio-onset",
  "roster-delta",
  "provisional-binding",
  "identity-link",
  "silent-diagnosis",
]);

/** One event → one JSONL line, `schema` first so a human tailing the file can
 * see the version without parsing. */
export function encodeAttributionEvent(event: AttributionEvent): string {
  return JSON.stringify({ schema: ATTRIBUTION_SCHEMA, ...event });
}

/**
 * Inverse of {@link encodeAttributionEvent} — for tests and for offline
 * consumers replaying a recorded log. Returns null for anything that is not a
 * schema-1 attribution event: replay must skip foreign lines, never guess.
 */
export function decodeAttributionLine(line: string): AttributionEvent | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const record = parsed as Record<string, unknown>;
  if (record.schema !== ATTRIBUTION_SCHEMA) return null;
  if (typeof record.type !== "string" || !EVENT_TYPES.has(record.type)) return null;
  if (typeof record.t !== "number") return null;
  const { schema: _schema, ...event } = record;
  return event as AttributionEvent;
}

/** Raw bytes → base64, chunked so a large payload never overflows the
 * argument list `String.fromCharCode` spreads into. */
export function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

/** How many encoded events the per-call ring keeps. Sized for a long call's
 * evidence (edges and onsets arrive per speaking turn, not per frame) while
 * bounding memory — the drop-oldest counter says when it was exceeded. */
export const ATTRIBUTION_RING_CAPACITY = 2000;

/**
 * Bounded drop-oldest buffer of encoded event lines. Serves both recorder
 * roles: the per-call export ring (snapshot) and the pending daemon batch
 * (drain). Never grows unbounded — the direct fix for the `__earsAudioLog`
 * precedent (B20 in the refactor proposal).
 */
export class AttributionRing {
  private q: string[] = [];
  private droppedCount = 0;

  constructor(private readonly capacity: number = ATTRIBUTION_RING_CAPACITY) {}

  get size(): number {
    return this.q.length;
  }

  /** Lines dropped to stay within capacity, for the debug report. */
  get dropped(): number {
    return this.droppedCount;
  }

  push(line: string): void {
    if (this.q.length >= this.capacity) {
      this.q.shift();
      this.droppedCount++;
    }
    this.q.push(line);
  }

  /** Oldest-first copy; the ring keeps its contents. */
  snapshot(): string[] {
    return [...this.q];
  }

  /** Remove and return everything, oldest first. */
  drain(): string[] {
    const out = this.q;
    this.q = [];
    return out;
  }
}
