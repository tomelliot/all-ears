import { registerAdapter, type PlatformAdapter, type PlatformParticipantId } from "./adapter";
import type { RosterEntry } from "../protocol";
import { colibriLocalEndpointId } from "./jitsi-colibri";

// Jitsi Meet (meet.jit.si, 8x8.vc / JaaS). Read from lib-jitsi-meet and
// jitsi-meet sources (2026-11-22). Not yet verified on a live call.
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
// Identity is intrinsic to the track, Zoom-style. lib-jitsi-meet rewrites
// every local MSID to `<endpointId>-<audio|video>-<index>-<pcId>`
// (LocalSdpMunger; older builds omit `-<pcId>`). That MSID is signalled to the
// other side unchanged, so the remote `MediaStream.id` names the sender's
// endpoint id: the MUC resource every other surface (the tile DOM, the
// participant list) keys participants by. No correlation, no guessing.
//
// Two stream ids carry no owner:
//   - `mixedmslabel` is the bridge's own RTCP-only stream. It sends no audio,
//     so the capture layer's wait-for-unmute keeps it from becoming a source.
//   - `remote-audio-<n>` appears when the deployment turns on SSRC rewriting
//     (`flags.ssrcRewritingEnabled`). The bridge then forwards audio over a
//     pool of reused slots and announces each slot's current owner in
//     `AudioSourcesMap` messages on its bridge channel. Neither meet.jit.si
//     nor 8x8.vc enables it (their config.js, 2026-11-22), so this adapter
//     does not read that channel: slot tracks are captured and stay
//     anonymous, with one log line saying why.
//
// Names come from the filmstrip tiles (`#participant_<endpointId>_name`), the
// same DOM the user sees. Jitsi's Redux store (`APP.store`) holds them too, but
// reading a private store is ruled out by the extension spec (MUST-NOT #6).
//
// You. The munged MSID is only in the SDP lib-jitsi-meet signals, never on our
// own peer connection, so the local endpoint id comes from the bridge
// channel's URL instead (jitsi-colibri.ts). The local tile carries no endpoint
// id in the DOM; its name label is `#localDisplayName`, shown as `<name> (me)`.

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
  private warnedSlots = false;
  private warnedLocal = false;
  /** The endpoint id last reported with `isLocal`. */
  private reportedLocal: string | null = null;
  private disposed = false;

  constructor(
    private readonly dom: () => JitsiRosterDom | null = () => globalThis.document ?? null,
    private readonly localEndpoint: () => string | null = colibriLocalEndpointId,
  ) {}

  identify(_track: MediaStreamTrack, stream: MediaStream): PlatformParticipantId | null {
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
    if (!id && isJitsiSlotStream(stream.id) && !this.warnedSlots) {
      this.warnedSlots = true;
      console.debug(
        "[ears][jitsi] this deployment forwards audio over SSRC-rewriting slots (remote-audio-<n>) — " +
          "audio is captured, but sources stay anonymous: the slot's owner is only on the bridge channel",
      );
    }
    return id;
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
  }
}

registerAdapter(isJitsiHost, () => new JitsiAdapter());
