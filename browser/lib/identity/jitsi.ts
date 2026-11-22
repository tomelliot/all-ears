import { registerAdapter, type PlatformAdapter, type PlatformParticipantId } from "./adapter";
import type { RosterEntry } from "../protocol";
import { livePeerConnections } from "../rtc-hook";
import { colibriAudioOwner, colibriLocalEndpointId, setBridgeListener } from "./jitsi-colibri";

// Jitsi Meet (meet.jit.si, 8x8.vc / JaaS). Read from lib-jitsi-meet and
// jitsi-meet sources, and checked on a live three-person meet.jit.si call
// (2026-11-22, current lib-jitsi-meet production build).
//
// Media. A call opens a peer connection to the videobridge (JVB). With exactly
// two people it also opens a direct P2P connection and moves media onto it,
// moving back to the bridge when a third joins. The bridge is an SFU and does
// not mix: every remote participant arrives as an ordinary RTP receiver track,
// which Jitsi plays through one `<audio id="remoteAudio_<streamId>">` per
// track. The receiver-track seam therefore captures each person separately, as
// on Zoom. After a P2P↔bridge switch one person can own a track on each
// connection; both identify to the same endpoint id, so they share a name.
//
// Two kinds of remote audio track, told apart by the stream id:
//
//   - `<endpointId>-audio-<index>[-<pcId>]`: the sender's own MSID, rewritten
//     by its LocalSdpMunger and signalled unchanged. The endpoint id is the MUC
//     resource every other surface (the tile DOM, the participant list) keys
//     participants by, so the track names its sender. The P2P connection
//     always looks like this, and so does the bridge when SSRC rewriting is
//     off.
//   - `remote-audio-<n>`: an SSRC-rewriting slot. meet.jit.si has rewriting
//     on (live call: three people gave `remote-audio-1..3`, with matching
//     `remoteAudio_remote-audio-<n>` elements). The bridge forwards audio over
//     a pool of reused slots, and the slot's owner is in no id. It is resolved
//     in two steps: slot → SSRC from the bridge connection's remote SDP
//     (`a=ssrc:<ssrc> msid:remote-audio-<n> …`; getSynchronizationSources()
//     returned nothing for these), then SSRC → endpoint id from the bridge
//     channel's `AudioSourcesMap` (jitsi-colibri.ts). The bridge reuses slots,
//     so an owner can change: an unresolved slot is named when its owner
//     arrives (`onIdentity`), and a slot whose owner changes is reported with
//     `onTrackReassigned`, so the capture layer starts a new source for the
//     new owner and each source stays one person.
//
// `mixedmslabel` is the bridge's own RTCP-only stream. It sends no audio, so
// the capture layer's wait-for-unmute keeps it from becoming a source.
//
// Names come from the filmstrip tiles (`#participant_<endpointId>_name`), the
// same DOM the user sees. Jitsi's Redux store (`APP.store`) holds them too, but
// reading a private store is ruled out by the extension spec (MUST-NOT #6).
//
// You. The munged MSID is only in the SDP lib-jitsi-meet signals, never on our
// own peer connection, and no DOM attribute carries the local endpoint id
// (live call). It comes from the bridge channel instead (jitsi-colibri.ts): a
// `SenderSourceConstraints` message for our video source, or the colibri-ws
// URL where the channel is a socket. With the camera off on a data-channel
// deployment there may be no local id, and then nothing is flagged local. The
// local tile's name label is `#localDisplayName`, shown as `<name> (me)`. A
// slot or a remote track never binds to the local id.

/** Hosted Jitsi deployments handled out of the box. Self-hosted instances go
 * through the popup's "Enable hooks on this site" and report as `web`. */
export function isJitsiHost(host: string): boolean {
  return host === "meet.jit.si" || host === "8x8.vc";
}

/** First path segments that are Jitsi's own routes, never a room. */
const RESERVED_SEGMENTS = new Set([
  "static",
  "libs",
  "css",
  "images",
  "sounds",
  "fonts",
  "lang",
  "http-bind",
  "xmpp-websocket",
  "colibri-ws",
  "_unlock",
  "conference-request",
  "v1",
]);

const SEGMENT_RE = /^[^\s/?#.]{1,256}$/;

/**
 * The meeting's external id from a Jitsi page URL: `<host>/<room>`, or
 * `<host>/<tenant>/<room>` for multi-tenant deployments (8x8.vc's
 * `vpaas-magic-cookie-…` tenants). Room names are case-insensitive in Jitsi,
 * so the id is lower-cased; the host is kept because room names are only
 * unique per deployment. Query and hash — where Jitsi puts the JWT and config
 * overrides — are never read. Null for anything that isn't a room page: the
 * welcome page, static assets, and Jitsi's service routes.
 */
export function parseJitsiRoom(url: string | null | undefined): string | null {
  if (!url) return null;
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  const segments = u.pathname.split("/").filter(Boolean);
  if (segments.length === 0 || segments.length > 2) return null;
  let decoded: string[];
  try {
    decoded = segments.map((s) => decodeURIComponent(s).toLowerCase());
  } catch {
    return null;
  }
  if (RESERVED_SEGMENTS.has(decoded[0] ?? "")) return null;
  if (!decoded.every((s) => SEGMENT_RE.test(s))) return null;
  return `${u.hostname.toLowerCase()}/${decoded.join("/")}`;
}

// `<endpointId>-audio-<index>` with an optional `-<pcId>`. The endpoint id is
// 8 hex digits on stock deployments, but is any MUC resource in principle
// (Jigasi, Jibri, token-derived ids), so only its character set is checked.
const AUDIO_MSID_RE = /^([A-Za-z0-9_.~]+(?:-[A-Za-z0-9_.~]+)*?)-audio-\d+(?:-\d+)?$/;
const SLOT_MSID_RE = /^remote-audio-\d+$/;

/**
 * The sender's endpoint id from a remote audio stream id, or null when the
 * stream names no participant (the bridge's `mixedmslabel`, an SSRC-rewriting
 * slot, a video stream, anything unrecognised).
 */
export function parseJitsiEndpointId(streamId: string | null | undefined): PlatformParticipantId | null {
  if (!streamId || SLOT_MSID_RE.test(streamId)) return null;
  return streamId.match(AUDIO_MSID_RE)?.[1] ?? null;
}

/** Whether a stream id is an SSRC-rewriting slot (owner not in the id). */
export function isJitsiSlotStream(streamId: string | null | undefined): boolean {
  return !!streamId && SLOT_MSID_RE.test(streamId);
}

const SSRC_MSID_LINE_RE = /^a=ssrc:(\d+) msid:(\S+)/;
const MEDIA_MSID_LINE_RE = /^a=msid:(\S+)/;
const SSRC_LINE_RE = /^a=ssrc:(\d+) /;

/**
 * Slot stream id (`remote-audio-<n>`) → SSRC, from a remote SDP. Reads the
 * `a=ssrc:<ssrc> msid:<slot> …` lines the bridge sends (live meet.jit.si,
 * 2026-11-22). A media section that names its slot only in `a=msid:` counts
 * when it has exactly one SSRC. Read-only: the SDP is never changed.
 */
export function parseJitsiSlotSsrcs(sdp: string): Map<string, number> {
  const out = new Map<string, number>();
  let sectionMsid: string | null = null;
  let sectionSsrcs = new Set<number>();
  const endSection = (): void => {
    if (sectionMsid && SLOT_MSID_RE.test(sectionMsid) && !out.has(sectionMsid) && sectionSsrcs.size === 1) {
      out.set(sectionMsid, [...sectionSsrcs][0]!);
    }
    sectionMsid = null;
    sectionSsrcs = new Set();
  };
  for (const line of sdp.split(/\r?\n/)) {
    if (line.startsWith("m=")) {
      endSection();
      continue;
    }
    const ssrcMsid = line.match(SSRC_MSID_LINE_RE);
    if (ssrcMsid) {
      const ssrc = Number(ssrcMsid[1]);
      const msid = ssrcMsid[2]!;
      if (SLOT_MSID_RE.test(msid) && ssrc <= 0xffffffff) out.set(msid, ssrc);
    }
    const ssrc = line.match(SSRC_LINE_RE);
    if (ssrc) sectionSsrcs.add(Number(ssrc[1]));
    const media = line.match(MEDIA_MSID_LINE_RE);
    if (media) sectionMsid = media[1]!;
  }
  endSection();
  return out;
}

/** What the adapter reads from the bridge (jitsi-colibri.ts) and the bridge
 * connection. Injected so tests can drive it. */
export interface JitsiBridgeView {
  /** Remote SDPs of the page's live peer connections. */
  remoteSdps(): string[];
  /** The endpoint the bridge last named as sending on `ssrc`. */
  audioOwner(ssrc: number): string | null;
  /** Be told when a slot owner or the local id changes (latest wins). */
  listen(cb: () => void): void;
  /** Stop being told, if `cb` is still the registered listener. */
  unlisten(cb: () => void): void;
}

const liveBridge: JitsiBridgeView = {
  remoteSdps() {
    const out: string[] = [];
    try {
      for (const pc of livePeerConnections()) {
        const sdp = pc.remoteDescription?.sdp;
        if (sdp) out.push(sdp);
      }
    } catch {
      // no page realm (tests) or a closed connection: no SDP
    }
    return out;
  },
  audioOwner: colibriAudioOwner,
  listen: (cb) => setBridgeListener(cb),
  unlisten: (cb) => setBridgeListener(null, cb),
};

/** Slot tracks remembered at most (a slot track lives for the bridge session;
 * the pool is a handful). */
const MAX_SLOT_TRACKS = 64;

/** Names Jitsi shows for a participant who never set one. Lower-case. */
const PLACEHOLDER_NAMES = new Set(["fellow jitster", "me", ""]);

/** Tile name ids: `participant_<endpointId>_name`. */
const TILE_NAME_ID_RE = /^participant_(.+)_name$/;
/** Screen shares get their own tile, keyed `<endpointId>-v<n>`: not a person. */
const VIRTUAL_SCREENSHARE_RE = /-v\d+$/;

/** The minimal DOM surface the roster scan reads, so tests can pass a fake. */
export interface JitsiRosterDom {
  querySelectorAll(selector: string): Iterable<{ id: string; textContent: string | null }>;
  querySelector(selector: string): { textContent: string | null } | null;
}

/**
 * Remote participants' names from the filmstrip tiles. Jitsi only renders the
 * label while display names are shown, and a large call virtualises its
 * tiles, so this is a best-effort sweep — anyone missing now is picked up by a
 * later poll. The local tile is `#localDisplayName` and never matches.
 */
export function harvestJitsiRoster(doc: JitsiRosterDom): RosterEntry[] {
  const out = new Map<string, string>();
  for (const el of doc.querySelectorAll('[id^="participant_"][id$="_name"]')) {
    const id = el.id.match(TILE_NAME_ID_RE)?.[1];
    if (!id || VIRTUAL_SCREENSHARE_RE.test(id)) continue;
    const name = (el.textContent ?? "").replace(/\s+/g, " ").trim();
    if (PLACEHOLDER_NAMES.has(name.toLowerCase())) continue;
    out.set(id, name);
  }
  return [...out].map(([participantId, displayName]) => ({ participantId, displayName }));
}

/** The suffix Jitsi appends to the local tile's name
 * (`interfaceConfig.DEFAULT_LOCAL_DISPLAY_NAME` via `appendSuffix`). */
const LOCAL_SUFFIX_RE = /\s*\(me\)$/i;

/**
 * Your own name from the local tile (`#localDisplayName`), without the
 * ` (me)` suffix. Null while the label is hidden or being edited, and for
 * Jitsi's placeholder (a user who set no name sees just `me`).
 */
export function readJitsiLocalName(doc: JitsiRosterDom): string | null {
  const text = doc.querySelector("#localDisplayName")?.textContent ?? "";
  const name = text.replace(/\s+/g, " ").trim().replace(LOCAL_SUFFIX_RE, "").trim();
  return PLACEHOLDER_NAMES.has(name.toLowerCase()) ? null : name;
}

/** Product-name tab titles that name no meeting. Lower-case. */
const GENERIC_TITLES = new Set(["jitsi meet", "jitsi", "8x8", "8x8 meet", "8x8 work", "jaas"]);

/**
 * The meeting's name. The conference-info header (`.subject-text--content`)
 * shows the moderator-set subject, falling back to the room name; the tab
 * title is `<Room Name> | <App name>` and is the fallback for builds or
 * configs that hide the header. Product names alone count as no name.
 */
export function extractJitsiMeetingTitle(
  subjectText: string | null | undefined,
  documentTitle: string | null | undefined,
): string | null {
  const subject = (subjectText ?? "").replace(/\s+/g, " ").trim();
  if (subject && !GENERIC_TITLES.has(subject.toLowerCase())) return subject;
  let title = (documentTitle ?? "").replace(/^\(\d+\)\s*/, "").trim();
  const bar = title.lastIndexOf(" | ");
  if (bar > 0) title = title.slice(0, bar).trim();
  if (!title || GENERIC_TITLES.has(title.toLowerCase())) return null;
  return title;
}

/** The two surfaces the title watcher reads. */
export interface JitsiTitleDom {
  title: string;
  querySelector(selector: string): { textContent: string | null } | null;
}

/** Takes the first meeting name observed and reports it exactly once, as
 * MeetMeetingTitleWatcher does. */
export class JitsiMeetingTitleWatcher {
  private resolved: string | null = null;

  constructor(private readonly onResolved: (title: string) => void) {}

  get title(): string | null {
    return this.resolved;
  }

  poll(doc: JitsiTitleDom): void {
    if (this.resolved) return;
    const subject = doc.querySelector(".subject-text--content")?.textContent;
    const title = extractJitsiMeetingTitle(subject, doc.title);
    if (!title) return;
    this.resolved = title;
    this.onResolved(title);
  }
}

export class JitsiAdapter implements PlatformAdapter {
  readonly platform = "jitsi" as const;
  private readonly names = new Map<string, string>();
  private rosterCb: ((entries: RosterEntry[]) => void) | null = null;
  private identityCb: ((trackId: string, id: PlatformParticipantId) => void) | null = null;
  private reassignCb: ((trackId: string) => void) | null = null;
  /** Slot tracks seen by identify(): track id → slot and the owner it is
   * currently identified as (null while unknown). Insertion-ordered, capped. */
  private readonly slotTracks = new Map<string, { slot: string; bound: string | null }>();
  private slotSsrcCache: { sdps: string[]; map: Map<string, number> } | null = null;
  private warnedSlots = false;
  private warnedLocal = false;
  private warnedLocalSlot = false;
  /** The endpoint id last reported with `isLocal`. */
  private reportedLocal: string | null = null;
  private disposed = false;
  private readonly onBridgeChange = (): void => this.checkSlots();

  constructor(
    private readonly dom: () => JitsiRosterDom | null = () => globalThis.document ?? null,
    private readonly localEndpoint: () => string | null = colibriLocalEndpointId,
    private readonly bridge: JitsiBridgeView = liveBridge,
  ) {}

  identify(track: MediaStreamTrack, stream: MediaStream): PlatformParticipantId | null {
    if (isJitsiSlotStream(stream.id)) return this.identifySlot(track.id, stream.id);
    const id = parseJitsiEndpointId(stream.id);
    if (id !== null && id === this.localEndpoint()) {
      // Your own audio never comes back from the bridge, so this stream id was
      // misread. You are on `mic`: never name a remote track after you.
      if (!this.warnedLocal) {
        this.warnedLocal = true;
        console.debug(`[ears][jitsi] remote stream ${stream.id} names the local endpoint — left anonymous`);
      }
      return null;
    }
    return id;
  }

  onIdentity(cb: (trackId: string, id: PlatformParticipantId) => void): void {
    this.identityCb = cb;
    this.listenToBridge();
  }

  onTrackReassigned(cb: (trackId: string) => void): void {
    this.reassignCb = cb;
    this.listenToBridge();
  }

  private listenToBridge(): void {
    if (this.disposed) return;
    try {
      this.bridge.listen(this.onBridgeChange);
    } catch {
      // no page realm: the 3 s poll still checks the slots
    }
  }

  /** A slot track at admission (or again after a reassignment): name it after
   * its current owner when the bridge has said who that is. */
  private identifySlot(trackId: string, slot: string): PlatformParticipantId | null {
    const owner = this.slotOwner(slot);
    this.slotTracks.delete(trackId);
    this.slotTracks.set(trackId, { slot, bound: owner });
    while (this.slotTracks.size > MAX_SLOT_TRACKS) this.slotTracks.delete(this.slotTracks.keys().next().value!);
    if (!owner && !this.warnedSlots) {
      this.warnedSlots = true;
      console.debug(
        `[ears][jitsi] SSRC-rewriting slot ${slot}: owner not known yet — ` +
          "named once the bridge channel's AudioSourcesMap and the bridge SDP both cover it",
      );
    }
    return owner;
  }

  /** The endpoint now sending on a slot: slot → SSRC (bridge SDP) → owner
   * (AudioSourcesMap). Never the local endpoint. */
  private slotOwner(slot: string): string | null {
    const ssrc = this.slotSsrcs().get(slot);
    if (ssrc === undefined) return null;
    const owner = this.bridge.audioOwner(ssrc);
    if (!owner) return null;
    if (owner === this.localEndpoint()) {
      if (!this.warnedLocalSlot) {
        this.warnedLocalSlot = true;
        console.debug(`[ears][jitsi] slot ${slot} maps to the local endpoint — left as it was`);
      }
      return null;
    }
    return owner;
  }

  private slotSsrcs(): Map<string, number> {
    const sdps = this.bridge.remoteSdps();
    const cached = this.slotSsrcCache;
    if (cached && cached.sdps.length === sdps.length && cached.sdps.every((s, i) => s === sdps[i])) return cached.map;
    const map = new Map<string, number>();
    for (const sdp of sdps) for (const [slot, ssrc] of parseJitsiSlotSsrcs(sdp)) if (!map.has(slot)) map.set(slot, ssrc);
    this.slotSsrcCache = { sdps: [...sdps], map };
    return map;
  }

  /** Compare every known slot track with its slot's current owner: name a
   * slot that was anonymous, and report one whose owner changed. Runs when
   * the bridge channel changes something and on every poll (the SDP can
   * arrive after the map). */
  private checkSlots(): void {
    if (this.disposed) return;
    // A snapshot: a reassignment re-enters identify(), which re-inserts the entry.
    for (const [trackId, entry] of [...this.slotTracks]) {
      const owner = this.slotOwner(entry.slot);
      if (!owner || owner === entry.bound) continue;
      const previous = entry.bound;
      entry.bound = owner;
      if (previous === null) {
        console.debug(`[ears][jitsi] slot ${entry.slot} (track ${trackId}) → ${owner}`);
        this.identityCb?.(trackId, owner);
      } else {
        console.debug(`[ears][jitsi] slot ${entry.slot} (track ${trackId}) changed owner: ${previous} → ${owner}`);
        this.reassignCb?.(trackId);
      }
    }
  }

  displayName(id: PlatformParticipantId): string | undefined {
    if (!this.names.has(id)) this.pollIdentities();
    return this.names.get(id);
  }

  onRoster(cb: (entries: RosterEntry[]) => void): void {
    this.rosterCb = cb;
  }

  pollIdentities(): void {
    if (this.disposed) return;
    this.checkSlots(); // the bridge SDP can name a slot after its map arrived
    const dom = this.dom();
    if (!dom) return;
    const local = this.localEndpoint();
    const fresh: RosterEntry[] = [];
    for (const entry of harvestJitsiRoster(dom)) {
      if (entry.participantId === local) continue; // only the local tile names you
      if (this.names.get(entry.participantId) === entry.displayName) continue;
      this.names.set(entry.participantId, entry.displayName);
      fresh.push(entry);
    }
    // You, once both halves are known: the endpoint id from the bridge channel
    // and the name from the local tile. Sent again when either changes, so the
    // newest pairing always carries the flag.
    const localName = local ? readJitsiLocalName(dom) : null;
    if (local && localName && (this.reportedLocal !== local || this.names.get(local) !== localName)) {
      this.reportedLocal = local;
      this.names.set(local, localName);
      fresh.push({ participantId: local, displayName: localName, isLocal: true });
    }
    if (fresh.length > 0) this.rosterCb?.(fresh);
  }

  dispose(): void {
    this.disposed = true;
    this.rosterCb = null;
    this.identityCb = null;
    this.reassignCb = null;
    try {
      this.bridge.unlisten(this.onBridgeChange);
    } catch {
      // nothing registered
    }
  }
}

registerAdapter(isJitsiHost, () => new JitsiAdapter());
