import type { RosterEntry } from "../protocol";

// Zoom web-client names, read from the page DOM: the meeting topic (session
// title) and the participants' display names (attendees). Capture is mic-only
// on Zoom — the far end rides a DataChannel, not a MediaStreamTrack — so no
// track ever carries an identity and the DOM is the only surface.
//
// Same standing contract as the other identity paths: best-effort, read-only
// (nothing here opens a panel or clicks), never blocks capture. No name found
// sends nothing, and the daemon's defaults stand.
//
// ── TITLE ───────────────────────────────────────────────────────────────────
// Only a real topic is sent. With none, the session keeps its default
// `zoom <id>` and the daemon titles it from the roster at session end
// (RosterReconciler.derivedTitle: remote names joined with ", "). That is the
// names fallback, and it is better done there than here: it sees the whole
// call, and the extension gets one rename per session, so an early names
// title would lock out both a later topic and the late joiners.
//
// Zoom's auto-generated topics ("Emily Kegels's Zoom Meeting", "…'s Personal
// Meeting Room") count as no topic: they name the host, not the meeting, and
// would stop the roster title from matching the note the user files under
// the other person's name.
//
// ── LOCAL USER ──────────────────────────────────────────────────────────────
// No self marker is known on the video tiles: on 2026-10-26 live, both tiles,
// the user's own included, read as remote. The local user is named from two
// signals only, and with neither, isLocal stays absent (RosterEntry contract):
//   1. Zoom's own "(me)" marker in the participants panel, when it is open.
//   2. The pre-join name field, read in every readable frame on every tick, so
//      a field in another frame, or one that comes back on a rejoin, is seen.
// The name first established is kept for the rest of the call, so closing the
// panel does not turn the user back into a remote.
//
// ── SELECTORS ───────────────────────────────────────────────────────────────
// The tile names are verified live (2026-10-16, 2026-10-26). All others are
// UNVERIFIED; a miss costs nothing but the names. zoom-names-probe.js checks
// them, and hunts for a self-tile marker, in one call.

/** Every DOM selector this module reads, in one place. */
export const ZOOM_SELECTORS = {
  /** Participants panel rows — only present if the user opened the panel.
   * Carries Zoom's own role/self marker ("(Host, me)"), in the name or in a
   * sibling label. */
  participantName: ".participants-item__display-name",
  participantLabel: ".participants-item__name-label",
  /** Video-tile name overlays, tried in order; the first that matches wins,
   * so the footer (which may hold more than the name) is a fallback only. */
  tileNames: [".video-avatar__avatar-name", ".video-avatar__avatar-footer"],
  /** The pre-join "Your Name" field — the local user's name, read before join
   * so their own tile can be told apart when nothing marks it. The second id
   * is the older web client's. */
  preJoinName: "#input-for-name, #inputname",
  /** In-call topic elements. Low confidence: Zoom shows the topic in the
   * meeting-info popover, which is only in the DOM while open. */
  topic: ".meeting-info-container__meeting-topic, .meeting-topic",
} as const;

/** The DOM slice the scans need — the real document in production,
 * hand-rolled fakes in tests (no jsdom, as meet-meeting-title.test.ts). */
export interface ZoomElementLike {
  textContent: string | null;
  parentElement?: { querySelector(selectors: string): { textContent: string | null } | null } | null;
}

export interface ZoomDocumentLike {
  title: string;
  querySelectorAll(selectors: string): Iterable<ZoomElementLike>;
  querySelector(selectors: string): { textContent: string | null } | null;
}

/** Zoom's role and self markers, as they appear in a trailing "(…)". */
const ROLE_TOKENS = new Set(["host", "co-host", "cohost", "guest", "me", "you"]);
const SELF_TOKENS = new Set(["me", "you"]);

const TRAILING_GROUP_RE = /\s*\(([^()]*)\)\s*$/;

/** Longest plausible display name; anything longer is not a name label. */
const MAX_NAME_LEN = 80;

/**
 * A display name with Zoom's role suffixes removed, and whether one of them
 * marked the local user. Only groups made entirely of known role tokens are
 * stripped, so "Sam (Berlin office)" keeps its parenthetical.
 */
export function parseZoomDisplayName(raw: string | null | undefined): { name: string; isLocal: boolean } | null {
  let name = (raw ?? "").replace(/\s+/g, " ").trim();
  let isLocal = false;
  for (let m = name.match(TRAILING_GROUP_RE); m; m = name.match(TRAILING_GROUP_RE)) {
    const tokens = m[1]!.split(",").map((t) => t.trim().toLowerCase());
    if (!tokens.every((t) => ROLE_TOKENS.has(t))) break;
    if (tokens.some((t) => SELF_TOKENS.has(t))) isLocal = true;
    name = name.slice(0, m.index).trim();
  }
  if (!name || name.length > MAX_NAME_LEN) return null;
  return { name, isLocal };
}

/** What one roster scan found. `matched` is selector → element count, for the
 * debug line; it never holds a name. */
export interface ZoomRosterScan {
  /** Distinct remote names, in DOM order. */
  remote: string[];
  /** The local user's name, when something identified it. */
  local: string | null;
  /** What identified `local`: a "(me)" marker on screen, or `localHint`. */
  localVia: "marker" | "hint" | null;
  matched: Record<string, number>;
}

/**
 * A participants-panel row as one string: the name element's text, plus its
 * sibling label as a "(…)" group when the label holds only role tokens, with
 * or without Zoom's parentheses ("(Host, me)", "Me"). Any other label is
 * dropped, so it cannot leak into the name.
 */
function participantRowText(name: string, label: string): string {
  const inner = label.replace(/\s+/g, " ").trim().replace(/^\((.*)\)$/, "$1").trim();
  if (!inner) return name;
  const tokens = inner.split(",").map((t) => t.trim().toLowerCase());
  return tokens.every((t) => ROLE_TOKENS.has(t)) ? `${name} (${inner})` : name;
}

/** The entry of `names` equal to `wanted` ignoring case — the spelling Zoom
 * shows, which can differ in case from what the user typed before join. */
function findName(names: readonly string[], wanted: string | null | undefined): string | null {
  const key = parseZoomDisplayName(wanted)?.name.toLowerCase();
  return key ? (names.find((n) => n.toLowerCase() === key) ?? null) : null;
}

/**
 * Read every participant name visible in `docs` (the declaring frame plus
 * any same-origin frame around it). `localHint` is a name already known to be
 * the local user's (an earlier "(me)" marker, or the pre-join name), used when
 * no marker is on screen. It counts only when it matches a name shown.
 */
export function scanZoomRoster(docs: readonly ZoomDocumentLike[], localHint?: string | null): ZoomRosterScan {
  const matched: Record<string, number> = {};
  const names: string[] = [];
  let local: string | null = null;
  const take = (raw: string | null | undefined): void => {
    const parsed = parseZoomDisplayName(raw);
    if (!parsed) return;
    if (parsed.isLocal) local ??= parsed.name;
    names.push(parsed.name);
  };
  const count = (selector: string, n: number): void => {
    matched[selector] = (matched[selector] ?? 0) + n;
  };

  for (const doc of docs) {
    let n = 0;
    for (const el of doc.querySelectorAll(ZOOM_SELECTORS.participantName)) {
      n++;
      const label = el.parentElement?.querySelector(ZOOM_SELECTORS.participantLabel)?.textContent ?? "";
      take(participantRowText(el.textContent ?? "", label));
    }
    count(ZOOM_SELECTORS.participantName, n);

    for (const selector of ZOOM_SELECTORS.tileNames) {
      const els = [...doc.querySelectorAll(selector)];
      count(selector, els.length);
      if (els.length === 0) continue;
      for (const el of els) take(el.textContent);
      break;
    }
  }

  let localVia: ZoomRosterScan["localVia"] = local ? "marker" : null;
  if (!local) {
    local = findName(names, localHint);
    if (local) localVia = "hint";
  }
  const localKey = local?.toLowerCase();
  const remote = [...new Set(names)].filter((n) => n.toLowerCase() !== localKey);
  return { remote, local, localVia, matched };
}

/** The roster id for a DOM-read name. Zoom's DOM exposes no participant id,
 * so the name is the key: one row per distinct name, stable across scans. */
export function zoomNameId(name: string): string {
  return `zoom-name:${name.toLowerCase()}`;
}

/** The scan as roster entries: remotes, plus the local user flagged `isLocal`
 * (as Meet sends it) so the daemon never infers a remote as you. */
export function zoomRosterEntries(scan: ZoomRosterScan): RosterEntry[] {
  const entries: RosterEntry[] = scan.remote.map((name) => ({ participantId: zoomNameId(name), displayName: name }));
  if (scan.local) entries.push({ participantId: zoomNameId(scan.local), displayName: scan.local, isLocal: true });
  return entries;
}

/**
 * Forwards roster entries that are new, or newly known to be local, and
 * builds a name-free debug line whenever what the scan sees changes.
 */
export class ZoomRosterWatcher {
  /** id → whether it was last sent as local. */
  private readonly sent = new Map<string, boolean>();
  private lastSummary = "";
  private preJoinName: string | null = null;
  /** The local user's name once a scan established it, kept for the call. */
  private local: string | null = null;
  /** Which signal established `local`, for the debug line. */
  private localVia: "marker" | "pre-join" | null = null;

  constructor(
    private readonly onEntries: (entries: RosterEntry[]) => void,
    private readonly log: (line: string) => void = () => {},
  ) {}

  /** The local user's name, or null while no signal has established it. */
  get localName(): string | null {
    return this.local;
  }

  /** The local name, else the pre-join name: not proof enough for isLocal,
   * but enough to refuse a topic that only names the user. */
  get ownNameHint(): string | null {
    return this.local ?? this.preJoinName;
  }

  /** Remember the pre-join name field while it is on screen, in any frame.
   * The latest value wins, so a rejoin under another name counts. */
  observePreJoin(docs: readonly ZoomDocumentLike[]): void {
    for (const doc of docs) {
      const el = doc.querySelector(ZOOM_SELECTORS.preJoinName) as unknown as { value?: string } | null;
      const value = el?.value?.trim();
      if (value) this.preJoinName = value;
    }
  }

  poll(docs: readonly ZoomDocumentLike[]): void {
    // A "(me)" marker on screen beats the remembered name; failing both, the
    // pre-join name. A marker also replaces a name the pre-join field gave.
    const scan = scanZoomRoster(docs, this.local ?? this.preJoinName);
    if (scan.local && (!this.local || (scan.localVia === "marker" && this.localVia !== "marker"))) {
      this.local = scan.local;
      this.localVia = scan.localVia === "marker" ? "marker" : "pre-join";
    }
    const fresh = zoomRosterEntries(scan).filter((e) => {
      const known = this.sent.get(e.participantId);
      return known === undefined || (e.isLocal === true && !known);
    });
    for (const e of fresh) this.sent.set(e.participantId, e.isLocal === true);
    if (fresh.length > 0) this.onEntries(fresh);

    const hits = Object.entries(scan.matched)
      .filter(([, n]) => n > 0)
      .map(([sel, n]) => `${sel}=${n}`);
    const summary =
      `roster scan: ${scan.remote.length} remote, ${scan.local ? 1 : 0} local` +
      ` (pre-join name ${this.preJoinName ? "seen" : "not seen"}; local via ${this.localVia ?? "nothing"})` +
      `; matched ${hits.length ? hits.join(" ") : "nothing"}`;
    if (summary !== this.lastSummary) {
      this.lastSummary = summary;
      this.log(summary);
    }
  }
}

// ── Title ────────────────────────────────────────────────────────────────────

/** Product-name suffixes on the tab title. */
const TITLE_SUFFIX_RE = /\s*[-–—|]\s*Zoom(?: Workplace)?$/i;

/** Tab titles and labels that name a screen, not a meeting. */
const GENERIC_TITLES = new Set(
  [
    "Meeting",
    "Meeting on web",
    "Webinar",
    "Join Meeting",
    "Join Webinar",
    "Join from your browser",
    "Launch Meeting",
    "Waiting Room",
    "Waiting for host",
    "Topic",
    "Loading",
  ].map((t) => t.toLowerCase()),
);

/** The product's own screen names: "Zoom", "Zoom Meeting", "Zoom meeting on
 * web" (the web client's tab title, seen live 2026-10-26), "Zoom Workplace",
 * "Zoom Web Client", "Zoom Webinar", and their combinations. */
const GENERIC_ZOOM_TITLE_RE =
  /^zoom(?: workplace)?(?: (?:meeting|webinar))?(?: (?:on (?:the )?web|web(?: client| app)?))?$/i;

/** Zoom's auto-generated topics, which name the host rather than the meeting. */
const DEFAULT_TOPIC_RE = /['’]s? (?:Zoom Meeting|Personal Meeting Room)$/i;

/**
 * A usable meeting topic, or null for a generic, default, or id-only value.
 * With `localName`, a topic that is only the local user's name is refused
 * too: it names you, not the meeting.
 */
export function usableZoomTopic(raw: string | null | undefined, localName?: string | null): string | null {
  const title = (raw ?? "").replace(/\s+/g, " ").trim().replace(TITLE_SUFFIX_RE, "").trim();
  if (!title || title.length > 200) return null;
  if (GENERIC_TITLES.has(title.toLowerCase()) || GENERIC_ZOOM_TITLE_RE.test(title)) return null;
  if (DEFAULT_TOPIC_RE.test(title)) return null;
  if (/^[\d\s-]+$/.test(title)) return null; // the meeting id
  if (localName && title.toLowerCase() === localName.trim().toLowerCase()) return null;
  return title;
}

/** The meeting topic from the tab title, else a topic element; null if none. */
export function extractZoomMeetingTitle(
  docs: readonly ZoomDocumentLike[],
  localName?: string | null,
): { title: string; via: string } | null {
  for (const doc of docs) {
    const title = usableZoomTopic(doc.title, localName);
    if (title) return { title, via: "document.title" };
  }
  for (const doc of docs) {
    for (const el of doc.querySelectorAll(ZOOM_SELECTORS.topic)) {
      const title = usableZoomTopic(el.textContent, localName);
      if (title) return { title, via: ZOOM_SELECTORS.topic };
    }
  }
  return null;
}

/** Takes the first topic observed and reports it once (as TeamsMeetingTitleWatcher). */
export class ZoomMeetingTitleWatcher {
  private resolved: string | null = null;

  constructor(private readonly onResolved: (title: string, via: string) => void) {}

  get title(): string | null {
    return this.resolved;
  }

  poll(docs: readonly ZoomDocumentLike[], localName?: string | null): void {
    if (this.resolved) return;
    const found = extractZoomMeetingTitle(docs, localName);
    if (!found) return;
    this.resolved = found.title;
    this.onResolved(found.title, found.via);
  }
}
