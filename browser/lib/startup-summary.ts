import type { Timers } from "./call-gate";

// One debug-log line per service-worker start.
//
// Chrome restarts the MV3 worker whenever an event arrives after it was idle.
// Each start used to log eight lines (debug on, two "connecting", two
// "connected", two socket URLs, site hooks), so a worker woken once a minute
// filled the 5000-entry ring in under 11 hours. StartupSummary absorbs those
// facts while the worker starts and emits them as one line, together with the
// first event that reached the worker — the reason it woke. Once the line is
// out (both sockets connected and site hooks synced, or the timeout passed),
// later status changes log as before.

export type StartupTransport = "ingest" | "control";

/** Longest the summary waits for the sockets before reporting what it has. */
export const STARTUP_SUMMARY_TIMEOUT_MS = 5_000;

export class StartupSummary {
  private readonly status: Partial<Record<StartupTransport, string>> = {};
  private hooks: string[] | undefined;
  private wake: string | undefined;
  private done = false;
  private readonly timer: unknown;

  constructor(
    private readonly emit: (line: string) => void,
    private readonly timers: Timers,
    timeoutMs = STARTUP_SUMMARY_TIMEOUT_MS,
  ) {
    this.timer = timers.setTimeout(() => this.finish(), timeoutMs);
  }

  /** True while the summary is still collecting (the caller must not log). */
  get collecting(): boolean {
    return !this.done;
  }

  /** A socket status change. Returns true when absorbed into the summary. */
  transport(which: StartupTransport, status: string): boolean {
    if (this.done) return false;
    this.status[which] = status;
    this.check();
    return true;
  }

  /** Site-hook registration finished. Returns true when absorbed. */
  siteHooks(origins: string[]): boolean {
    if (this.done) return false;
    this.hooks = origins;
    this.check();
    return true;
  }

  /** An event reached the worker. Only the first is kept: it woke the worker. */
  event(description: string): void {
    if (this.wake === undefined) this.wake = description;
  }

  private check(): void {
    if (this.status.ingest === "connected" && this.status.control === "connected" && this.hooks) {
      this.finish();
    }
  }

  private finish(): void {
    if (this.done) return;
    this.done = true;
    this.timers.clearTimeout(this.timer);
    const hooks = this.hooks
      ? `site hooks on ${this.hooks.length} origin(s)${this.hooks.length ? ` [${this.hooks.join(", ")}]` : ""}`
      : "site hooks pending";
    this.emit(
      `[ears][bg] worker started (woken by ${this.wake ?? "no event yet"}): ` +
        `ingest ${this.status.ingest ?? "pending"}, control ${this.status.control ?? "pending"}, ${hooks}`,
    );
  }
}
