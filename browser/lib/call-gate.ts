import type { LogEntry } from "./debug-log";
import type { RelayState } from "./relay-core";

// Holds a meeting tab's debug-log and perf batches while no call is live.
//
// Every runtime.sendMessage from a content script wakes the MV3 service worker.
// Perf collection runs from page load (a 1 s flush, a long-task observer, a
// stats poller), so a meeting tab left open with no call would otherwise wake
// the worker about once a minute (Chrome throttles hidden-tab timers to that),
// and each wake writes the worker's startup lines into the 5000-entry log ring.
//
// While idle, items wait in a bounded in-page buffer (oldest dropped first), so
// the pre-call context — the join sequence, deferred tracks — still ships when
// the call starts. A warn/error log line ships at once, held lines first: a
// failure outside a call is worth one wake. After the call ends the gate stays
// open for a short linger so the call's last lines (track closes, meeting-ended)
// still reach the store.

/** A call is live once the hook has declared a meeting or admitted a capture
 * participant — participants can precede the meeting declaration (Jitsi). */
export function isCallLive(state: RelayState): boolean {
  return state.liveMeeting !== null || state.participants.size > 0;
}

/** How long the gate stays open after the last call ends. */
export const CALL_GATE_LINGER_MS = 10_000;
/** Held log entries kept while idle. */
export const MAX_HELD_LOG_ENTRIES = 500;
/** Held perf records kept while idle. Records arrive ~1/s per context, so this
 * is the last few minutes before a call. */
export const MAX_HELD_PERF_RECORDS = 300;

export interface Timers {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const realTimers: Timers = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

/** One gated stream: ships batches while open, holds them (bounded) while closed. */
export class GatedForwarder<T> {
  private held: T[] = [];

  constructor(
    private readonly ship: (items: T[]) => void,
    private readonly maxHeld: number,
    private readonly isOpen: () => boolean,
  ) {}

  /** Forward a batch. `urgent` ships it (and anything held) even while closed. */
  push(items: T[], urgent = false): void {
    if (items.length === 0) return;
    if (this.isOpen() || urgent) {
      this.release(items);
      return;
    }
    this.held.push(...items);
    if (this.held.length > this.maxHeld) this.held.splice(0, this.held.length - this.maxHeld);
  }

  /** Ship whatever is held (the gate just opened). */
  drain(): void {
    this.release([]);
  }

  /** Items currently held (tests, diagnostics). */
  get heldCount(): number {
    return this.held.length;
  }

  private release(items: T[]): void {
    const batch = this.held.length > 0 ? [...this.held, ...items] : items;
    this.held = [];
    if (batch.length > 0) this.ship(batch);
  }
}

/** A warn or error line is worth one worker wake even outside a call. */
export function isUrgentLog(entries: LogEntry[]): boolean {
  return entries.some((e) => e.level === "warn" || e.level === "error");
}

/**
 * The relay's gate: open while a call is live and for {@link CALL_GATE_LINGER_MS}
 * after it ends. Streams attach with {@link forwarder}; call {@link setLive}
 * after every relay state change.
 */
export class CallGate {
  private readonly forwarders: GatedForwarder<unknown>[] = [];
  private live = false;
  private lingering = false;
  private lingerTimer: unknown = null;

  constructor(
    private readonly timers: Timers = realTimers,
    private readonly lingerMs = CALL_GATE_LINGER_MS,
  ) {}

  get open(): boolean {
    return this.live || this.lingering;
  }

  /** A gated stream sharing this gate's open state. */
  forwarder<T>(ship: (items: T[]) => void, maxHeld: number): GatedForwarder<T> {
    const f = new GatedForwarder<T>(ship, maxHeld, () => this.open);
    this.forwarders.push(f as GatedForwarder<unknown>);
    return f;
  }

  setLive(live: boolean): void {
    if (live === this.live) return;
    this.live = live;
    this.cancelLinger();
    if (live) {
      for (const f of this.forwarders) f.drain();
      return;
    }
    this.lingering = true;
    this.lingerTimer = this.timers.setTimeout(() => {
      this.lingerTimer = null;
      this.lingering = false;
    }, this.lingerMs);
  }

  private cancelLinger(): void {
    if (this.lingerTimer !== null) this.timers.clearTimeout(this.lingerTimer);
    this.lingerTimer = null;
    this.lingering = false;
  }
}
