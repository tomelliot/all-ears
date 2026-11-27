import { describe, expect, it } from "vitest";
import type { Timers } from "./call-gate";
import { StartupSummary } from "./startup-summary";

function fakeTimers(): Timers & { fire(): void } {
  let pending: (() => void) | null = null;
  return {
    setTimeout(fn) {
      pending = fn;
      return 1;
    },
    clearTimeout() {
      pending = null;
    },
    fire() {
      const fn = pending;
      pending = null;
      fn?.();
    },
  };
}

describe("StartupSummary", () => {
  it("absorbs the start-up status lines and emits one line once everything is in", () => {
    const lines: string[] = [];
    const s = new StartupSummary((l) => lines.push(l), fakeTimers());
    s.event("alarm ears-capture-keepalive");
    expect(s.transport("ingest", "connecting")).toBe(true);
    expect(s.transport("control", "connecting")).toBe(true);
    expect(s.siteHooks([])).toBe(true);
    expect(s.transport("ingest", "connected")).toBe(true);
    expect(lines).toEqual([]);
    expect(s.transport("control", "connected")).toBe(true);
    expect(lines).toEqual([
      "[ears][bg] worker started (woken by alarm ears-capture-keepalive): " +
        "ingest connected, control connected, site hooks on 0 origin(s)",
    ]);
    expect(s.collecting).toBe(false);
  });

  it("logs normally after the summary is out", () => {
    const lines: string[] = [];
    const s = new StartupSummary((l) => lines.push(l), fakeTimers());
    s.siteHooks(["https://example.com/*"]);
    s.transport("ingest", "connected");
    s.transport("control", "connected");
    expect(lines[0]).toContain("site hooks on 1 origin(s) [https://example.com/*]");
    expect(s.transport("ingest", "disconnected")).toBe(false);
    expect(s.siteHooks([])).toBe(false);
  });

  it("keeps only the first event as the wake reason", () => {
    const lines: string[] = [];
    const s = new StartupSummary((l) => lines.push(l), fakeTimers());
    s.event("port pcm");
    s.event("message log-batch");
    s.siteHooks([]);
    s.transport("ingest", "connected");
    s.transport("control", "connected");
    expect(lines[0]).toContain("(woken by port pcm)");
  });

  it("reports what it has when the daemon is unreachable", () => {
    const timers = fakeTimers();
    const lines: string[] = [];
    const s = new StartupSummary((l) => lines.push(l), timers);
    s.transport("ingest", "disconnected");
    s.transport("control", "connecting");
    timers.fire();
    expect(lines).toEqual([
      "[ears][bg] worker started (woken by no event yet): " +
        "ingest disconnected, control connecting, site hooks pending",
    ]);
  });
});
