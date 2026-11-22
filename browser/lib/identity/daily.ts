import { registerAdapter, type PlatformAdapter } from "./adapter";

// Daily (daily.co) — the call engine behind Cal Video and other embeds. The
// call runs in a cross-origin `<sub>.daily.co/<room>` iframe; the embedding
// page (app.cal.com) holds no media. Verified 2026-09-14 on a live Cal Video
// call: each remote participant arrives as an ordinary RTP receiver track,
// which Daily attaches to one of a pool of pre-created `<audio>` elements, and
// the receiver-track seam captured it (`browser:web:t1` reached earsd before
// this platform existed and was refused for want of a session).
//
// Identity is not solved: `identify()` returns null, so sources stay
// `browser:daily:t<n>`. Daily's own globals (`_daily`,
// `placeDailyContextOnWindow`) may expose the participant list — unexplored.

export function isDailyHost(host: string): boolean {
  return host === "daily.co" || host.endsWith(".daily.co");
}

/**
 * The meeting's external id from the call frame's URL: `<sub>/<room>`, with
 * the subdomain kept because room names are only unique within one Daily
 * domain. Null for anything that isn't a room page (the bare domain, Daily's
 * own asset hosts, a non-Daily URL). Query and hash — where Daily puts the
 * meeting token — are never read.
 */
export function parseDailyRoom(url: string | null | undefined): string | null {
  if (!url) return null;
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (!isDailyHost(u.hostname)) return null;
  const sub = u.hostname.slice(0, -".daily.co".length);
  if (!sub || sub.includes(".")) return null;
  const room = u.pathname.split("/").filter(Boolean)[0];
  if (!room || !/^[A-Za-z0-9_-]{1,128}$/.test(room)) return null;
  return `${sub}/${room}`;
}

/** What the call frame looks like at one instant, as the audio check needs it. */
export interface DailyAudioSnapshot {
  peerConnections: number;
  /** Remote audio tracks in the hook's registry (rtc-hook.ts liveTracks). */
  hookedTrackIds: string[];
  /** Audio tracks attached to `<audio>`/`<video>` elements — what Daily plays. */
  elementTrackIds: string[];
}

/** How long a played track may go unhooked before the check warns. */
export const DAILY_UNHOOKED_GRACE_MS = 5_000;

/**
 * Debug check for the one way this platform can be wrong silently: Daily
 * plays remote audio the hook never registered (a Daily release moving audio
 * off the receiver path, as Zoom's did — journal #152). Pure: callers pass the
 * snapshot and the clock.
 *
 * `observe` returns a summary line only when the snapshot changed, and a
 * warning once per track that stays unhooked past the grace period.
 */
export class DailyAudioCheck {
  private lastSummary = "";

  /** `product` names the platform in the warning; Jitsi reuses this check. */
  constructor(private readonly product: string = "Daily") {}

  private readonly unhookedSince = new Map<string, number>();
  private readonly warned = new Set<string>();

  observe(s: DailyAudioSnapshot, now: number): { log?: string; warn?: string } {
    const out: { log?: string; warn?: string } = {};
    const short = (ids: string[]) => ids.map((id) => id.slice(0, 8)).sort().join(",") || "-";
    const summary = `pcs=${s.peerConnections} hooked=${short(s.hookedTrackIds)} played=${short(s.elementTrackIds)}`;
    if (summary !== this.lastSummary) {
      this.lastSummary = summary;
      out.log = summary;
    }

    const hooked = new Set(s.hookedTrackIds);
    const unhooked = s.elementTrackIds.filter((id) => !hooked.has(id));
    for (const id of [...this.unhookedSince.keys()]) {
      if (!unhooked.includes(id)) this.unhookedSince.delete(id);
    }
    const overdue: string[] = [];
    for (const id of unhooked) {
      const since = this.unhookedSince.get(id) ?? now;
      this.unhookedSince.set(id, since);
      if (now - since >= DAILY_UNHOOKED_GRACE_MS && !this.warned.has(id)) {
        this.warned.add(id);
        overdue.push(id.slice(0, 8));
      }
    }
    if (overdue.length > 0) {
      out.warn =
        `${this.product} is playing remote audio the hook never saw (tracks ${overdue.join(",")}, pcs=${s.peerConnections}) — ` +
        `that audio is not being captured`;
    }
    return out;
  }
}

class DailyAdapter implements PlatformAdapter {
  readonly platform = "daily" as const;

  identify(): null {
    return null;
  }
}

registerAdapter(isDailyHost, () => new DailyAdapter());
