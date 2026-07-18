import { registerAdapter, type PlatformAdapter } from "./adapter";
import type { ParticipantId } from "../protocol";

// Meet identity — Phase 4: tile-DOM correlation.
//
// Approach (specs/extension.md §Platform adapter): Meet renders a per-
// participant tile; identify() correlates the captured remote track to the
// tile's media element (srcObject match) and reads the participant id + display
// name off the tile's DOM. Everything is synchronous and best-effort by
// contract: any miss — tile not mounted yet, DOM shape changed, track not
// attached to any media element — returns null and audio-tap.ts's speaker-<n>
// fallback carries the audio. Identity never blocks, throws into, or delays
// capture.
//
// ── VERIFICATION STATUS ──────────────────────────────────────────────────
// Implemented against the spec's documented DOM shape (confidence: medium).
// The live-call verification pass required by prompts/meet-identity.md §1 has
// NOT run yet — record its findings as journal evidence entries when it does.
// Checklist for that pass (≥2 other participants, DevTools on meet.google.com):
//
//   1. `document.querySelectorAll("[data-participant-id],[data-requested-participant-id],[data-initial-participant-id]")`
//      — confirm which attribute the current build carries (update
//      PARTICIPANT_ID_ATTRIBUTES if it changed) and where the display-name
//      text lives relative to it (update extractDisplayName's probes).
//   2. For each <audio>/<video> with a `.srcObject`, compare
//      `srcObject.getTracks().map(t => t.id)` and `srcObject.id` against the
//      "[ears] +track" console lines. Known risk: Meet decodes remote audio in
//      its own WASM pipeline (journal #28–#31), so per-tile media elements may
//      hold Meet-generated streams whose track ids do NOT match the RTC
//      tracks; if so, the shared-MediaStream (msid) match on the tile's
//      <video> is the only viable DOM channel — and if that fails too, the
//      CSRC fallback below becomes the primary mechanism.
//   3. Confirm tiles are mounted by the time "+track" fires — identify() is
//      called exactly once per track, synchronously, so a tile that mounts
//      later means that track stays speaker-<n> (accepted by Phase 4's exit
//      bar; not a bug).
//
// ── CSRC fallback (documented, deliberately NOT implemented) ─────────────
// If the verification pass shows tile-DOM doesn't hold, rebuild identify() on
// `RTCRtpReceiver.getContributingSources()` (reading the already-known
// receiver behind the passed transceiver is fine — it's not track discovery),
// correlating CSRC + audioLevel against a separately available roster. Per
// specs/extension.md MUST-NOT #8: never per-frame single-winner attribution
// that silently drops simultaneous speakers, and never present attribution as
// verified per-participant identity — label it the way teams.ts labels its
// dominant-speaker approach. It is not half-implemented here on purpose:
// prompts/meet-identity.md §1 makes the choice of primary mechanism an
// empirical one, and building both blind would leave dead unverified code.
//
// The returned ParticipantId is the raw tile attribute value (historically
// "spaces/<space>/devices/<device>"-shaped); protocol.ts's sanitizeLabel maps
// it into the earsd source label downstream.

/** Tile attributes probed for a stable participant id, strongest first. */
export const PARTICIPANT_ID_ATTRIBUTES = [
  "data-participant-id",
  "data-requested-participant-id",
  "data-initial-participant-id",
] as const;

const TILE_SELECTOR = PARTICIPANT_ID_ATTRIBUTES.map((a) => `[${a}]`).join(",");
const MEDIA_SELECTOR = "audio, video";

// Structural slices of the DOM/WebRTC surfaces the helpers touch — real
// Element/Document/MediaStream objects satisfy these, and meet.test.ts feeds
// hand-rolled fakes (this repo's preference over jsdom; vitest runs in the
// node environment).

export interface ElementLike {
  getAttribute(name: string): string | null;
  parentElement: ElementLike | null;
  querySelector?(selectors: string): ElementLike | null;
  textContent?: string | null;
}

export interface MediaElementLike extends ElementLike {
  srcObject?: unknown;
}

export interface DocumentLike {
  querySelectorAll(selectors: string): Iterable<ElementLike>;
  querySelector(selectors: string): ElementLike | null;
}

interface TrackRef {
  readonly id: string;
}

interface StreamRef {
  readonly id: string;
  getTracks(): TrackRef[];
}

/** Read the tile's participant id, or null if it carries none. */
export function extractParticipantId(tile: ElementLike): string | null {
  for (const attr of PARTICIPANT_ID_ATTRIBUTES) {
    const value = tile.getAttribute(attr)?.trim();
    if (value) return value;
  }
  return null;
}

/** Climb from a media element to the nearest ancestor carrying a participant id. */
export function findParticipantTile(el: ElementLike): ElementLike | null {
  for (let node: ElementLike | null = el; node; node = node.parentElement) {
    if (extractParticipantId(node)) return node;
  }
  return null;
}

/**
 * Read the tile's display name: its own data-self-name, a descendant's
 * data-self-name (attribute value, else that element's text), then the tile's
 * aria-label. undefined when none — name is optional, id is what matters.
 */
export function extractDisplayName(tile: ElementLike): string | undefined {
  const own = clean(tile.getAttribute("data-self-name"));
  if (own) return own;
  const nameEl = tile.querySelector?.("[data-self-name]");
  if (nameEl) {
    const fromAttr = clean(nameEl.getAttribute("data-self-name"));
    if (fromAttr) return fromAttr;
    const fromText = clean(nameEl.textContent);
    if (fromText) return fromText;
  }
  return clean(tile.getAttribute("aria-label"));
}

function clean(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

/**
 * Find the media element rendering `track`. Strongest signal first: an element
 * whose srcObject contains the track itself (by identity, then id). Falls back
 * to an element rendering the same MediaStream — Meet bundles a participant's
 * audio+video under one msid, so the tile's <video> can share the audio
 * track's stream even when no per-tile <audio> exists (and even when Meet's
 * WASM decode path means the audio track itself never reaches an element).
 */
export function findMediaElementForTrack(
  doc: DocumentLike,
  track: TrackRef,
  stream: StreamRef | null,
): MediaElementLike | null {
  const els: MediaElementLike[] = [];
  for (const el of doc.querySelectorAll(MEDIA_SELECTOR)) els.push(el as MediaElementLike);

  for (const el of els) {
    const so = mediaStreamOf(el);
    if (so?.getTracks().some((t) => t === track || t.id === track.id)) return el;
  }
  if (stream) {
    for (const el of els) {
      const so = mediaStreamOf(el);
      if (so && (so === stream || (stream.id !== "" && so.id === stream.id))) return el;
    }
  }
  return null;
}

function mediaStreamOf(el: MediaElementLike): StreamRef | null {
  const so = el.srcObject as StreamRef | null | undefined;
  if (!so || typeof so.getTracks !== "function" || typeof so.id !== "string") return null;
  return so;
}

class MeetAdapter implements PlatformAdapter {
  readonly platform = "meet" as const;

  /** id → last-known display name. Kept after a tile unmounts (leave/rejoin
   * gets a fresh identify() anyway); cleared only by dispose(). */
  private readonly names = new Map<ParticipantId, string>();
  private observer: MutationObserver | null = null;
  private tilesDirty = true;
  private warnedMissingIds = false;
  private disposed = false;

  identify(track: MediaStreamTrack, stream: MediaStream): ParticipantId | null {
    // Best-effort by contract: a broken or changed Meet DOM must degrade to
    // speaker-<n>, never throw into the capture path.
    try {
      return this.correlate(track, stream);
    } catch {
      return null;
    }
  }

  displayName(id: ParticipantId): string | undefined {
    try {
      this.refreshNamesIfDirty();
    } catch {
      // stale cache is fine
    }
    return this.names.get(id);
  }

  /**
   * Disconnect the observer and drop caches. Idempotent. Nothing calls
   * adapter.dispose() yet — epoch teardown in audio-tap.ts only stops
   * pipelines (pre-existing gap, outside Phase 4's scope) — but this is ready
   * for when it does.
   */
  dispose(): void {
    this.disposed = true;
    this.observer?.disconnect();
    this.observer = null;
    this.names.clear();
  }

  private correlate(track: MediaStreamTrack, stream: MediaStream): ParticipantId | null {
    if (this.disposed || typeof document === "undefined") return null;
    this.ensureObserver();
    this.refreshNamesIfDirty();

    const media = findMediaElementForTrack(document, track, stream);
    const tile = media ? findParticipantTile(media) : null;
    if (!tile) {
      // Normal not-(yet-)correlated case — quiet null, speaker-<n> carries it.
      // But distinguish it from a structural total failure, which warns once.
      this.maybeWarnStructure();
      return null;
    }
    const id = extractParticipantId(tile)!;
    const name = extractDisplayName(tile);
    if (name) this.names.set(id, name);
    return id;
  }

  private ensureObserver(): void {
    if (this.observer || this.disposed || typeof MutationObserver === "undefined") return;
    // Constructed at document_start, so the observer can't start until a real
    // identify() call, by which point the document exists. No stable Meet grid
    // container is verified yet, so observe body (documentElement as belt and
    // braces) — cheap, because the callback only marks the tile cache dirty;
    // rescans happen lazily inside identify()/displayName(). Meet's grid
    // mutates constantly (audio-level animations), so doing real work per
    // mutation would burn main-thread time for nothing.
    const root = document.body ?? document.documentElement;
    if (!root) return;
    this.observer = new MutationObserver(() => {
      this.tilesDirty = true;
    });
    this.observer.observe(root, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: [...PARTICIPANT_ID_ATTRIBUTES, "data-self-name"],
    });
  }

  private refreshNamesIfDirty(): void {
    if (!this.tilesDirty || this.disposed || typeof document === "undefined") return;
    this.tilesDirty = false;
    for (const tile of document.querySelectorAll(TILE_SELECTOR)) {
      const id = extractParticipantId(tile);
      if (!id) continue;
      const name = extractDisplayName(tile);
      if (name) this.names.set(id, name);
    }
  }

  // MUST-NOT #13 (no swallowing structural failures): a Meet build whose tiles
  // carry none of the expected attributes would otherwise look like working
  // code that happens to produce zero real names. Warn once — only once media
  // is demonstrably rendering (early in a call, zero tiles is normal).
  private maybeWarnStructure(): void {
    if (this.warnedMissingIds) return;
    if (document.querySelector(TILE_SELECTOR)) return; // expected shape present; this track just isn't placed (yet)
    let anyStream = false;
    for (const el of document.querySelectorAll(MEDIA_SELECTOR)) {
      if (mediaStreamOf(el as MediaElementLike)) {
        anyStream = true;
        break;
      }
    }
    if (!anyStream) return;
    this.warnedMissingIds = true;
    console.warn(
      `[ears] Meet DOM carries none of the expected participant-id attributes (${PARTICIPANT_ID_ATTRIBUTES.join(", ")}) on any tile — identity degrades to speaker-<n>. The Meet build's tile DOM has likely changed; see lib/identity/meet.ts for the verification checklist and CSRC fallback notes.`,
    );
  }
}

registerAdapter((host) => host === "meet.google.com", () => new MeetAdapter());
