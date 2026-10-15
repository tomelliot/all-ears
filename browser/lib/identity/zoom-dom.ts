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
// ── SELECTORS ───────────────────────────────────────────────────────────────
// All UNVERIFIED against a live web-client build (2026-10-15). A miss costs
// nothing but the names; confirm with the console checks in the PR notes.

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
   * so their own tile can be told apart when nothing marks it. */
  preJoinName: "#input-for-name",
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
  matched: Record<string, number>;
}

/**
 * Read every participant name visible in `docs` (the declaring frame plus
 * any same-origin frame around it). `localHint` is the pre-join name, used
 * when no "(me)" marker is on screen.
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
      take(`${el.textContent ?? ""} ${label}`);
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

  const hint = parseZoomDisplayName(localHint)?.name ?? null;
  if (!local && hint && names.includes(hint)) local = hint;
  const remote = [...new Set(names)].filter((n) => n !== local);
  return { remote, local, matched };
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
  private localHint: string | null = null;

  constructor(
    private readonly onEntries: (entries: RosterEntry[]) => void,
    private readonly log: (line: string) => void = () => {},
  ) {}

  /** Remember the pre-join name field while it is on screen. */
  observePreJoin(doc: ZoomDocumentLike): void {
    const el = doc.querySelector(ZOOM_SELECTORS.preJoinName) as unknown as { value?: string } | null;
    const value = el?.value?.trim();
    if (value) this.localHint = value;
  }

  poll(docs: readonly ZoomDocumentLike[]): void {
    const scan = scanZoomRoster(docs, this.localHint);
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
      ` (pre-join name ${this.localHint ? "seen" : "not seen"}); matched ${hits.length ? hits.join(" ") : "nothing"}`;
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
    "Zoom",
    "Zoom Meeting",
    "Zoom Workplace",
    "Zoom Web Client",
    "Meeting",
    "Join Meeting",
    "Launch Meeting",
    "Topic",
    "Loading",
  ].map((t) => t.toLowerCase()),
);

/** Zoom's auto-generated topics, which name the host rather than the meeting. */
const DEFAULT_TOPIC_RE = /['’]s? (?:Zoom Meeting|Personal Meeting Room)$/i;

/** A usable meeting topic, or null for a generic, default, or id-only value. */
export function usableZoomTopic(raw: string | null | undefined): string | null {
  const title = (raw ?? "").replace(/\s+/g, " ").trim().replace(TITLE_SUFFIX_RE, "").trim();
  if (!title || title.length > 200) return null;
  if (GENERIC_TITLES.has(title.toLowerCase())) return null;
  if (DEFAULT_TOPIC_RE.test(title)) return null;
  if (/^[\d\s-]+$/.test(title)) return null; // the meeting id
  return title;
}

/** The meeting topic from the tab title, else a topic element; null if none. */
export function extractZoomMeetingTitle(docs: readonly ZoomDocumentLike[]): { title: string; via: string } | null {
  for (const doc of docs) {
    const title = usableZoomTopic(doc.title);
    if (title) return { title, via: "document.title" };
  }
  for (const doc of docs) {
    for (const el of doc.querySelectorAll(ZOOM_SELECTORS.topic)) {
      const title = usableZoomTopic(el.textContent);
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

  poll(docs: readonly ZoomDocumentLike[]): void {
    if (this.resolved) return;
    const found = extractZoomMeetingTitle(docs);
    if (!found) return;
    this.resolved = found.title;
    this.onResolved(found.title, found.via);
  }
}
