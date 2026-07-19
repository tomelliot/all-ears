import { PARTICIPANT_ID_ATTRIBUTES } from "./meet";

// Meet's *external* meeting id — the <space> segment of the
// "spaces/<space>/devices/<device>" identifiers already flowing through two
// independent, live-verified surfaces (see meet.ts's verification notes):
//
//   1. Tile DOM attributes (PARTICIPANT_ID_ATTRIBUTES) — available as soon as
//      any tile mounts, not gated on anyone speaking.
//   2. Collections-datachannel device ids — which reach this watcher as
//      upgraded participant ids on the same participant-joined messages
//      audio-tap already posts (hook.content.ts feeds them in).
//
// The <space> segment is never used directly as a daemon-facing slug: it is
// only ever handed to `meeting.resolve` as `external_id`, and the daemon
// mints/looks up its own meeting UUID (see daemon MeetingRegistry). Same
// contract as every other identity path here: best-effort, never blocks,
// throws into, or delays capture — an unresolved id just means the meeting
// can't be marked (yet); audio keeps flowing regardless.

const SPACES_ID_RE = /^spaces\/([^/]+)/;

/** "spaces/<space>[/devices/<device>]" → "<space>"; null for anything else
 * (e.g. the speaker-<n> fallback ids). */
export function extractMeetSpaceId(value: string | null | undefined): string | null {
  if (!value) return null;
  const match = SPACES_ID_RE.exec(value.trim());
  return match ? match[1]! : null;
}

/** The one DOM slice the tile scan needs — hand-rolled fakes in tests, the
 * real document in production (same pattern as meet.ts's DocumentLike). */
export interface TileDocumentLike {
  querySelectorAll(selectors: string): Iterable<{ getAttribute(name: string): string | null }>;
}

/** Scan currently-mounted tiles for the first spaces/<space>-shaped id. */
export function scanTilesForSpaceId(doc: TileDocumentLike): string | null {
  for (const attr of PARTICIPANT_ID_ATTRIBUTES) {
    for (const el of doc.querySelectorAll(`[${attr}]`)) {
      const spaceId = extractMeetSpaceId(el.getAttribute(attr));
      if (spaceId) return spaceId;
    }
  }
  return null;
}

/**
 * Takes the first spaces/<space> value observed from either surface and
 * reports it exactly once. The timer/listener wiring stays in hook.content.ts;
 * this class is the pure, unit-testable part.
 */
export class MeetMeetingIdWatcher {
  private resolved: string | null = null;

  constructor(private readonly onResolved: (spaceId: string) => void) {}

  /** The resolved space id, or null while still unknown. */
  get spaceId(): string | null {
    return this.resolved;
  }

  /** Feed a candidate participant/device id (participant-joined traffic). */
  observeCandidate(value: string | null | undefined): void {
    if (this.resolved) return;
    const spaceId = extractMeetSpaceId(value);
    if (spaceId) this.resolve(spaceId);
  }

  /** Scan the tile DOM (cheap; call on a short interval while unresolved). */
  poll(doc: TileDocumentLike): void {
    if (this.resolved) return;
    const spaceId = scanTilesForSpaceId(doc);
    if (spaceId) this.resolve(spaceId);
  }

  private resolve(spaceId: string): void {
    this.resolved = spaceId;
    this.onResolved(spaceId);
  }
}
