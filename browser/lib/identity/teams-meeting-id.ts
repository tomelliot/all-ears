// Teams' *external* meeting id — the chat thread the call hangs off,
// `19:meeting_<48 chars>@thread.v2`. It is handed to `session.start` as
// `external_id` and nothing else; the daemon mints its own session UUID from
// it (same contract as Meet's <space> and Zoom's numeric id).
//
// Unlike Zoom, this cannot be read off the URL. On the anonymous join path
// (teams.microsoft.com/light-meetings/launch?anon=true&lightExperience=true)
// the URL carries no thread id at all — only tenant/object ids that repeat
// across every meeting from one organiser, and per-session correlation ids
// that would fragment one meeting across rejoins (journal #161). The thread id
// *is* present in the document, so this needs a Meet-style poll: scrape, stop
// on first resolve.
//
// ── SURFACES, CHEAPEST FIRST ────────────────────────────────────────────────
//
// Serialising the whole DOM once a second is not free on an SPA the size of
// Teams. Measured in Chromium on a synthetic 30k-element / 3.9 MB document:
//
//     documentElement.innerHTML + regex     4.9  ms
//     documentElement.textContent + regex   0.09 ms   (55x cheaper)
//     location.href + regex                 free
//
// — and ~4 MB of garbage per serialise besides. So the surfaces are tried in
// cost order and the expensive one is rate-limited to one poll in five:
//
//   1. `url` — free, and authoritative when present. The signed-in client
//      routes calls by thread id (`#/l/meetup-join/19:meeting_…@thread.v2`),
//      which the anonymous light client does not. UNVERIFIED against a live
//      signed-in call; it costs one regex against a short string, and a miss
//      just falls through.
//   2. `documentText` — every text node, which includes the contents of inline
//      `<script>` config blobs. Misses attribute values.
//   3. `documentHtml` — full markup, the only surface that sees attributes.
//      Last resort, rate-limited.
//
// Resource-timing URLs (`performance.getEntriesByType("resource")`) were
// considered as a fourth surface and dropped: #161 already places the id in
// the document, so it buys no coverage, and the caller only polls at all while
// a peer connection is live, which is what actually bounds the cost.
//
// Known weakness: on the full client the chat rail stays mounted during a
// call, so surfaces 2-3 can in principle see *another* meeting's thread id.
// The URL is checked first for exactly that reason. Not observed; worth a
// live confirmation before leaning on it.

/**
 * Teams thread id for a meeting. `meeting_` is required rather than matching
 * any `19:…@thread.v2`: ordinary group chats share that shape, and a page
 * showing a chat list is full of them — resolving one would file the recording
 * under a random conversation. The observed live id was 69 characters
 * (`19:` + `meeting_` + 48 + `@thread.v2`); the length here is left loose so a
 * differently-sized id still resolves.
 */
const THREAD_ID_RE = /19:meeting_[A-Za-z0-9_\-+=]{10,256}@thread\.v2/;

/** How many polls between full-markup sweeps. See the cost note above: the
 * first poll sweeps (a re-injection mid-call resolves at once), then one in
 * five, so the 4.9 ms surface costs ~0.1% of a core while a call is up. */
const HTML_SWEEP_EVERY = 5;

/**
 * Pull a Teams meeting thread id out of arbitrary text, or null. Tolerates
 * percent-encoding (`19%3Ameeting_…%40thread.v2`), which is how the id appears
 * inside a query string, by retrying on the decoded form — only worth doing
 * for short, URL-shaped inputs, so callers pass whole documents through
 * unencoded and short strings through `parseTeamsMeetingIdFromUrl`.
 */
export function parseTeamsMeetingId(text: string | null | undefined): string | null {
  if (!text) return null;
  return THREAD_ID_RE.exec(text)?.[0] ?? null;
}

/** As `parseTeamsMeetingId`, but also tries the percent-decoded form. Keep
 * this off the document-sized surfaces: decoding those would cost more than
 * the scan it is helping. */
export function parseTeamsMeetingIdFromUrl(url: string | null | undefined): string | null {
  const direct = parseTeamsMeetingId(url);
  if (direct || !url) return direct;
  let decoded: string;
  try {
    decoded = decodeURIComponent(url);
  } catch {
    return null; // malformed escape — nothing to read
  }
  return parseTeamsMeetingId(decoded);
}

/**
 * Fallback for calls joined by numeric meeting ID (`teams.microsoft.com/meet/<digits>?p=…`).
 * Those land on `light-meetings/launch?coords=<base64 JSON>` and the page never
 * carries a `19:meeting_…@thread.v2` id; `coords.meetingCode` is the only stable
 * key. Returns `meet:<digits>` so it cannot collide with a thread id.
 */
export function parseTeamsMeetingCodeFromUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  let coords: string | null;
  try {
    coords = new URL(url).searchParams.get("coords");
  } catch {
    return null;
  }
  if (!coords) return null;
  try {
    const parsed = JSON.parse(atob(coords)) as { meetingCode?: unknown };
    const code = typeof parsed.meetingCode === "string" ? parsed.meetingCode.replace(/\s+/g, "") : "";
    return /^\d{6,20}$/.test(code) ? `meet:${code}` : null;
  } catch {
    return null;
  }
}

/**
 * The surfaces the watcher scrapes, as lazy accessors so it can skip the
 * expensive ones — hand-rolled fakes in tests, the real page in production
 * (same pattern as meet-meeting-id.ts's `TileDocumentLike`).
 */
export interface TeamsIdSources {
  /** `location.href`. */
  url: string;
  /** Every text node of the document, concatenated. */
  documentText: () => string;
  /** The document's full serialised markup. Called at most once per
   * `HTML_SWEEP_EVERY` polls — see the cost note above. */
  documentHtml: () => string;
}

/**
 * Takes the first thread id observed and reports it exactly once.
 *
 * The timer wiring stays in hook.content.ts; this class is the pure,
 * unit-testable part.
 */
export class TeamsMeetingIdWatcher {
  private resolved: string | null = null;
  private polls = 0;

  constructor(private readonly onResolved: (threadId: string) => void) {}

  /** The resolved thread id, or null while still unknown. */
  get threadId(): string | null {
    return this.resolved;
  }

  /** Scan the page. Cheap on most ticks; see `HTML_SWEEP_EVERY`. */
  poll(sources: TeamsIdSources): void {
    if (this.resolved) return;
    const sweepHtml = this.polls++ % HTML_SWEEP_EVERY === 0;
    const threadId =
      parseTeamsMeetingIdFromUrl(sources.url) ??
      parseTeamsMeetingId(sources.documentText()) ??
      (sweepHtml ? parseTeamsMeetingId(sources.documentHtml()) : null) ??
      // Only after a full sweep has missed, so a thread id wins when the page has one.
      (sweepHtml ? parseTeamsMeetingCodeFromUrl(sources.url) : null);
    if (!threadId) return;
    this.resolved = threadId;
    this.onResolved(threadId);
  }
}
