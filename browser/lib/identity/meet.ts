import { registerAdapter, type PlatformAdapter } from "./adapter";
import type { ParticipantId, RosterEntry } from "../protocol";
import { setCollectionsListener } from "../rtc-hook";
import type { CollectionsSpeakingEvent } from "./meet-collections";
import { SpeakingCorrelator, type CorrelatorMatch } from "./meet-correlator";

// Meet identity — Phase 4: tile-DOM correlation (identify(), synchronous),
// plus Phase 4 collections-datachannel upgrade (onIdentify(), asynchronous).
//
// identify() approach (specs/extension.md §Platform adapter): Meet renders a
// per-participant tile; identify() correlates the captured remote track to
// the tile's media element (srcObject match) and reads the participant id +
// display name off the tile's DOM. Everything is synchronous and best-effort
// by contract: any miss — tile not mounted yet, DOM shape changed, track not
// attached to any media element — returns null and audio-tap.ts's speaker-<n>
// fallback carries the audio. Identity never blocks, throws into, or delays
// capture. Per the VERIFICATION STATUS section below, this path is confirmed
// dead on the current build and identify() is expected to keep returning null.
//
// ── COLLECTIONS-DATACHANNEL UPGRADE (journal #49-#58) ───────────────────────
//
// identify()'s one-shot, synchronous contract can't express a correlation
// that only becomes confident after observing speaking activity (the
// collections datachannel gives a device id tied to "someone is speaking now",
// not to a specific MediaStreamTrack — see
// docs/specs/browser/extension.md (the collections exception)'s Task 2/3).
// So this doesn't change identify()'s behavior at all. Instead:
//
//   1. rtc-hook.ts's installMeetCollectionsTracer parses the "collections"
//      RTCDataChannel (meet-collections.ts) and forwards events here via
//      setCollectionsListener.
//   2. audio-tap.ts calls onTrackSpeaking(track, speaking) on every track's
//      audio-domain speaking edge (unconditionally, not debug-gated).
//   3. Both onset streams feed a SpeakingCorrelator (meet-correlator.ts, pure
//      logic, independently unit-tested): a device onset and exactly one
//      live track's audio onset within ~200ms of each other is a candidate
//      pairing. Requires CONFIRM_THRESHOLD (1, see its own comment below)
//      consecutive confirming turns before it's trusted.
//   4. Once confirmed, the upgraded id is pushed via the onIdentify(cb)
//      callback registered by audio-tap.ts, which restarts that track's
//      pipeline as a new segment under the real id (see audio-tap.ts's
//      handleIdentityUpgrade for why "new segment" was chosen over
//      renaming a running segment in place).
//
// Degrades silently if the channel never appears or stops parsing (Meet
// changed the format) — the correlator just never confirms a match, and
// identify()/onIdentify fall back to speaker-<n> exactly as they already do.
// rtc-hook.ts warns once (not per-message) if messages arrive but stop
// parsing; see maybeWarnCollectionsSchema there.
//
// Investigated and rejected: bootstrapping identity at call start from the
// larger multi-device "roster" message collections also sends (containing
// each device id plus SSRC-shaped numbers, e.g. one entry per device with a
// paired-SSRC "FID" group) by matching those numbers against our own
// RTCPeerConnection's getStats() SSRCs, to skip waiting for anyone to speak.
// Live-tested (2026-07-19): none of the roster message's numeric fields
// appear anywhere in our own receivers' stats, across every report type
// (inbound-rtp, remote-outbound-rtp, transport, candidate-pair, etc) — Meet's
// SFU remaps SSRCs to small local sequential values (6666, 6667, ...) with no
// numeric relationship to whatever it reports internally, matching journal
// #43's original SSRC-correlation finding. There is no bootstrap shortcut;
// speaking-onset correlation is the only signal available.
//
// ── LIVE VERIFICATION STATUS (collections upgrade) ──────────────────────────
// Live-verified end to end (2026-07-19, journal #55-#58, real 3-participant
// Meet call): the production tracer parsed real traffic, the correlator
// accumulated and reported a correct match, and MeetAdapter pushed an
// onIdentify upgrade that audio-tap.ts's handleIdentityUpgrade restarted
// cleanly as a new segment — confirmed correct for one participant
// end-to-end. That same session caught and fixed a real schema bug (the
// speaking-flag path was missing a nesting level; see meet-collections.ts's
// header comment). The second non-self participant's track died mid-test to
// the pre-existing, unrelated AudioDecoder bug (journal #45) before its
// upgrade could be observed — likely fine (its wire data looked identical in
// shape) but not itself confirmed. CONFIRM_THRESHOLD was 3 for this run and
// is now 1 (see that constant's comment) based on zero ambiguous matches
// observed across every turn in this session.
//
// ── VERIFICATION STATUS ──────────────────────────────────────────────────
// Live-verified 2026-07-18 (Chrome, meet.google.com, 3-account real call —
// journal #41–#46). Conclusion: identify() is expected to return null in
// practice on this Meet build. Every correlation mechanism investigated was
// confirmed dead, not just theoretically risky:
//
//   - Tile attributes/name: data-participant-id + data-requested-participant-id
//     both hold (spaces/<space>/devices/<device>-shaped, confirmed live —
//     PARTICIPANT_ID_ATTRIBUTES is correct as written). Display name does NOT
//     live in data-self-name or aria-label on this build (both empty/null on
//     every tile) — the real name text is a descendant `span.notranslate`
//     (journal #41), which extractDisplayName now also probes.
//   - Tile-media correlation (this file's primary path): zero <audio>/<video>
//     elements exist anywhere in the document, including shadow DOM (journal
//     #42) — findMediaElementForTrack() is structurally guaranteed to return
//     null, not just occasionally mismatched. Matches rtc-hook.ts's own note
//     that Meet decodes audio via createEncodedStreams() (journal #28–#31)
//     and never touches an HTMLMediaElement.
//   - CSRC fallback: getContributingSources() returns [] for every live
//     receiver (journal #43) — our own encoded-audio tee diverts frames
//     before the native stats pipeline that populates CSRC ever runs.
//   - SSRC correlation (tried live, not in the original spec): tile
//     data-ssrc and the audio receiver's inbound-rtp SSRC (via getStats())
//     are in disjoint numeric namespaces — no bridge there either (#43).
//   - Track/tile ordering heuristic (tried live at explicit request after the
//     above three failed): fails its own precondition. A fresh join fires
//     +track before tiles mount (identify()'s one-shot structural warning
//     fired at the literal instant of join, confirming zero tiles existed
//     yet), and a 3-person call produces 3 remote audio tracks against only 2
//     non-self tiles, reproduced on two separate meetings — there is no
//     stable 1:1 track↔tile correspondence to order against (journal #44).
//
// identify() keeps returning null by design; audio-tap.ts's speaker-<n>
// fallback already handles this correctly and needs no change. Re-verify if
// a future Meet build changes any of the above (e.g. media elements return,
// or track/tile counts start matching) — see journal #41–#46 for full detail
// and #45 for an unrelated capture-pipeline bug (AudioDecoder errors) noticed
// during this pass.
//
// The returned ParticipantId is the raw tile attribute value (historically
// "spaces/<space>/devices/<device>"-shaped); protocol.ts's sanitizeLabel maps
// it into the earsd source label downstream. This code is left in place
// (rather than short-circuited to `return null`) because it's still correct
// against the DOM shape that does exist, and costs nothing to keep for
// re-verification against a future build.

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
  querySelectorAll?(selectors: string): Iterable<ElementLike>;
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
 * data-self-name (attribute value, else that element's text), a descendant
 * `span.notranslate` (the name-overlay element observed live — journal #41),
 * then the tile's aria-label. undefined when none — name is optional, id is
 * what matters.
 *
 * The `notranslate` class is not unique to the name overlay: Meet also renders
 * material icon ligatures under it. On the current build (confirmed live) the
 * same participant id is carried by several tiles, and a non-name tile's
 * `span.notranslate` *wraps* a material `<i>` whose ligature text bubbles up as
 * the icon name — e.g. "devices", "mic". The real name overlay is instead a
 * text-only leaf `<span class="notranslate">`. Tag-qualifying isn't enough, so
 * we walk every match and skip any icon-ligature span (see
 * ``isIconLigatureSpan``), taking the first real name.
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
  const spans = tile.querySelectorAll?.("span.notranslate") ?? [];
  for (const span of spans) {
    if (isIconLigatureSpan(span)) continue;
    const text = clean(span.textContent);
    if (text) return text;
  }
  return clean(tile.getAttribute("aria-label"));
}

/**
 * Whether a `span.notranslate` is a material icon ligature rather than a name
 * overlay. The name overlay is a text-only leaf; an icon overlay contains a
 * material `<i>` element whose ligature text (e.g. "devices") bubbles up as the
 * span's textContent — so the presence of a descendant `<i>` is the reliable
 * signal (confirmed live: the icon span's own class is `notranslate <obfusc>`,
 * carrying no material marker). The icon-font class check is a secondary guard
 * for builds that put the ligature directly on the span.
 */
function isIconLigatureSpan(el: ElementLike): boolean {
  if (el.querySelector?.("i")) return true;
  const cls = el.getAttribute("class") ?? "";
  return /material-(?:icons|symbols)|google-symbols|google-material-icons/i.test(cls);
}

function clean(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

/**
 * The newly-resolved or changed (id → name) pairs in `names` that `emitted`
 * hasn't seen yet, as roster entries — and mutates `emitted` to record them.
 * Pure and side-effect-scoped to `emitted` so it unit-tests without a DOM: the
 * adapter calls it on every tile re-scan and forwards only the delta, so a
 * participant's name reaches the daemon once (not once per 3s poll) and a
 * corrected name (Meet swaps a placeholder for the real one) re-emits. Empty
 * names are already excluded upstream (only truthy names enter `names`).
 */
export function rosterDelta(
  names: ReadonlyMap<ParticipantId, string>,
  emitted: Map<ParticipantId, string>,
): RosterEntry[] {
  const fresh: RosterEntry[] = [];
  for (const [id, name] of names) {
    if (emitted.get(id) === name) continue;
    emitted.set(id, name);
    fresh.push({ participantId: id, displayName: name });
  }
  return fresh;
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

// Consecutive confirming turns (SpeakingCorrelator) required before an
// onIdentify upgrade fires. Shipped at 3 (conservative per Task 4), then
// loosened to 1 after live verification (2026-07-19, journal): a live
// 3-participant call produced zero ambiguous matches across every turn
// observed — the correlator's own "exactly one live track's audio onset
// within the window" requirement (meet-correlator.ts) is already the primary
// false-positive guard per event; requiring the *same* pairing to repeat 3
// times on top of that mostly just adds latency (each unmute/first-turn wait)
// without having caught a real false positive in testing. Revisit if live
// use ever shows a single-turn upgrade landing on the wrong participant.
const CONFIRM_THRESHOLD = 1;
const CORRELATION_WINDOW_MS = 200; // journal #50: onset pairs landed within tens of ms

class MeetAdapter implements PlatformAdapter {
  readonly platform = "meet" as const;

  /** id → last-known display name. Kept after a tile unmounts (leave/rejoin
   * gets a fresh identify() anyway); cleared only by dispose(). */
  private readonly names = new Map<ParticipantId, string>();
  private observer: MutationObserver | null = null;
  private tilesDirty = true;
  private warnedMissingIds = false;
  private disposed = false;

  // ── Collections-datachannel upgrade state (see file-header doc comment) ──
  private readonly correlator = new SpeakingCorrelator(CORRELATION_WINDOW_MS);
  /** deviceId → last-known speaking state, for future use (e.g. debugging);
   * not read for the correlation decision itself, which lives in correlator. */
  private readonly deviceState = new Map<string, { speaking: boolean; lastSeen: number }>();
  /** track.id → live track, so a later match can hand the real track object
   * back to onIdentify. Populated from both identify() and onTrackSpeaking(),
   * whichever sees a track first; never explicitly pruned (bounded by the
   * small number of tracks live in a call, and dispose() clears it). */
  private readonly liveTracksById = new Map<string, MediaStreamTrack>();
  /** track.id → deviceId already pushed via onIdentify, so a repeat match
   * doesn't re-fire the callback. */
  private readonly upgradedTracks = new Map<string, ParticipantId>();
  private identifyCb: ((track: MediaStreamTrack, id: ParticipantId) => void) | null = null;
  private renameCb: ((trackId: string, id: ParticipantId) => void) | null = null;
  private rosterCb: ((entries: RosterEntry[]) => void) | null = null;
  /** id → name already emitted via onRoster, so each tile re-scan pushes only
   * the delta (see rosterDelta). */
  private readonly emittedNames = new Map<ParticipantId, string>();

  constructor() {
    // Latest-registration-wins, same handoff pattern as rtc-hook.ts's own
    // setTrackSink — each epoch's fresh MeetAdapter re-registers itself.
    setCollectionsListener((event) => this.onCollectionsEvent(event));
  }

  identify(track: MediaStreamTrack, stream: MediaStream): ParticipantId | null {
    // Best-effort by contract: a broken or changed Meet DOM must degrade to
    // speaker-<n>, never throw into the capture path.
    this.liveTracksById.set(track.id, track);
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

  onIdentify(cb: (track: MediaStreamTrack, id: ParticipantId) => void): void {
    this.identifyCb = cb;
  }

  onRename(cb: (trackId: string, id: ParticipantId) => void): void {
    this.renameCb = cb;
  }

  onRoster(cb: (entries: RosterEntry[]) => void): void {
    this.rosterCb = cb;
  }

  /**
   * Re-scan the participant tiles and emit any newly-resolved names via
   * onRoster. Called periodically by the capture reconciler so the roster is
   * harvested even for participants who never speak (the collections-datachannel
   * correlation only fires on speaking onsets, so a silent participant's name
   * would otherwise never reach the daemon — issue #23). Best-effort: a broken
   * DOM degrades to no roster, never throws into the capture path.
   */
  pollIdentities(): void {
    if (this.disposed) return;
    try {
      this.tilesDirty = true; // force a re-scan even when no mutation fired since last poll
      this.refreshNamesIfDirty();
    } catch {
      // best-effort — identity harvesting must never affect capture
    }
  }

  /** audio-tap.ts calls this unconditionally on every track's audio-domain
   * speaking edge. Best-effort: never throws into the capture path. */
  onTrackSpeaking(track: MediaStreamTrack, speaking: boolean): void {
    if (this.disposed) return;
    try {
      this.liveTracksById.set(track.id, track);
      if (!speaking) return; // only onsets feed the correlator (see meet-correlator.ts)
      this.applyMatch(this.correlator.recordAudioOnset(track.id, Date.now()));
    } catch {
      // best-effort — a broken correlation must never affect capture
    }
  }

  private onCollectionsEvent(event: CollectionsSpeakingEvent): void {
    if (this.disposed) return;
    try {
      this.deviceState.set(event.deviceId, { speaking: event.speaking, lastSeen: Date.now() });
      if (!event.speaking) return; // only turn-start (flag 0) feeds the correlator
      this.applyMatch(this.correlator.recordDeviceOnset(event.deviceId, Date.now()));
    } catch {
      // best-effort — same contract as onTrackSpeaking
    }
  }

  private applyMatch(match: CorrelatorMatch | null): void {
    if (!match || match.confirmations < CONFIRM_THRESHOLD) return;
    if (this.upgradedTracks.get(match.trackKey) === match.deviceId) return; // already pushed
    const track = this.liveTracksById.get(match.trackKey);
    if (!track) {
      // The correlation confirmed, but the track it points at is already gone —
      // too late for onIdentify's pipeline restart. Push the join as a rename
      // instead: the audio already recorded under the fallback id keeps its
      // source, and the daemon attaches that source to the named attendee (the
      // Etel case — a track that died to the AudioDecoder bug before its
      // upgrade could land, journal #45).
      this.upgradedTracks.set(match.trackKey, match.deviceId);
      console.debug(
        `[ears][identity] Meet late join: no live track for device ${match.deviceId} ` +
          `(track ${match.trackKey} ended before ${match.confirmations}-turn confirmation landed)` +
          ` — pushing as a rename`,
      );
      this.renameCb?.(match.trackKey, match.deviceId);
      return;
    }
    this.upgradedTracks.set(match.trackKey, match.deviceId);
    const name = this.names.get(match.deviceId);
    console.debug(
      `[ears][identity] Meet identity join: track ${match.trackKey} → ${match.deviceId}` +
        `${name ? ` "${name}"` : " (name not yet resolved from tiles)"} ` +
        `via collections datachannel (${match.confirmations} confirming turns)`,
    );
    this.identifyCb?.(track, match.deviceId);
  }

  /**
   * Disconnect the observer and drop caches. Idempotent. Nothing calls
   * adapter.dispose() yet — epoch teardown in audio-tap.ts only stops
   * pipelines (pre-existing gap, outside Phase 4's scope) — but this is ready
   * for when it does. Deliberately does NOT call setCollectionsListener(null):
   * a newer epoch's MeetAdapter may already have re-registered itself by the
   * time an older one disposes, and clearing unconditionally would clobber
   * that registration — the disposed-guard in onCollectionsEvent/
   * onTrackSpeaking is what actually stops a disposed adapter from acting.
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
    this.emitRoster();
  }

  /** Forward newly-resolved (id → name) pairs to the roster callback, once
   * each. Logs every resolution (device id → display name) per issue #23's
   * debug-logging requirement. */
  private emitRoster(): void {
    const fresh = rosterDelta(this.names, this.emittedNames);
    if (fresh.length === 0) return;
    for (const entry of fresh) {
      console.debug(
        `[ears][identity] Meet roster resolved: ${entry.participantId} → "${entry.displayName}"`,
      );
    }
    this.rosterCb?.(fresh);
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
      `[ears][identity] Meet DOM carries none of the expected participant-id attributes (${PARTICIPANT_ID_ATTRIBUTES.join(", ")}) on any tile — identity degrades to speaker-<n>. The Meet build's tile DOM has likely changed; see lib/identity/meet.ts for the verification checklist and CSRC fallback notes.`,
    );
  }
}

registerAdapter((host) => host === "meet.google.com", () => new MeetAdapter());
