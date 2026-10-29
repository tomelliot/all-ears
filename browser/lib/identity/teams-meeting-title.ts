// Teams' *human* meeting name, read from the tab title — same contract as
// meet-meeting-title.ts: best-effort, never blocks capture, and no name found
// sends no title at all.
//
// Observed live on the anonymous light client (2026-10-14, a meeting-ID join):
//   pre-join   "Microsoft Teams meeting | Microsoft Teams"
//   in call    "Call <meeting subject> | Microsoft Teams"
// The "Call " prefix is kept: it is not yet known whether it is Teams'
// decoration or part of the subject, and stripping a real word is worse than
// keeping a redundant one.
//
// Every app view of the signed-in client also titles itself "<View> |
// Microsoft Teams" (Chat, Calendar, …). Those are listed as generic so a call
// started from one of them never gets the view's name. UNVERIFIED against the
// signed-in client.

/** Leading "(3) " unread count. */
const NOTIFICATION_PREFIX_RE = /^\(\d+\)\s*/;

/** Product-name suffixes, longest first. */
const PRODUCT_SUFFIXES = [" | Microsoft Teams (free)", " | Microsoft Teams"];

/** Tab titles that name a screen, not a meeting. Compared case-insensitively. */
const GENERIC_TITLES = new Set(
  [
    "Microsoft Teams",
    "Microsoft Teams meeting",
    "Join conversation",
    "Meeting",
    "Meet",
    "Call",
    "Calls",
    "Chat",
    "Calendar",
    "Activity",
    "Teams",
    "Loading",
  ].map((t) => t.toLowerCase()),
);

/** The meeting's name from a Teams tab title, or null when the title is generic. */
export function extractTeamsMeetingTitle(rawTitle: string | null | undefined): string | null {
  let title = (rawTitle ?? "").replace(NOTIFICATION_PREFIX_RE, "").trim();
  for (const suffix of PRODUCT_SUFFIXES) {
    if (title.toLowerCase().endsWith(suffix.toLowerCase())) {
      title = title.slice(0, title.length - suffix.length).trim();
      break;
    }
  }
  if (!title || GENERIC_TITLES.has(title.toLowerCase())) return null;
  return title;
}

/**
 * Takes the first meeting name observed and reports it exactly once (see
 * MeetMeetingTitleWatcher for why only the first).
 */
export class TeamsMeetingTitleWatcher {
  private resolved: string | null = null;

  constructor(private readonly onResolved: (title: string) => void) {}

  get title(): string | null {
    return this.resolved;
  }

  poll(doc: { title: string }): void {
    if (this.resolved) return;
    const title = extractTeamsMeetingTitle(doc.title);
    if (!title) return;
    this.resolved = title;
    this.onResolved(title);
  }
}
