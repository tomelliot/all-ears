import { describe, expect, it } from "vitest";
import { CallGate, GatedForwarder, isCallLive, isUrgentLog, type Timers } from "./call-gate";
import type { LogEntry } from "./debug-log";
import { emptyRelayState } from "./relay-core";

const entry = (msg: string, level: LogEntry["level"] = "debug"): LogEntry => ({ t: 0, ctx: "relay", level, msg });

/** Manual timers: `fire()` runs every pending callback. */
function fakeTimers(): Timers & { fire(): void; pending: number } {
  const pending = new Map<number, () => void>();
  let next = 0;
  return {
    setTimeout(fn) {
      const id = next++;
      pending.set(id, fn);
      return id;
    },
    clearTimeout(h) {
      pending.delete(h as number);
    },
    fire() {
      const fns = [...pending.values()];
      pending.clear();
      for (const fn of fns) fn();
    },
    get pending() {
      return pending.size;
    },
  };
}

describe("isCallLive", () => {
  it("is false for a fresh relay state", () => {
    expect(isCallLive(emptyRelayState())).toBe(false);
  });

  it("is true once a meeting is declared", () => {
    const s = { ...emptyRelayState(), liveMeeting: { platform: "jitsi" as const, externalMeetingId: "m" } };
    expect(isCallLive(s)).toBe(true);
  });

  it("is true with a capture participant before the meeting is declared", () => {
    const s = emptyRelayState();
    s.participants.set("t1", { platform: "jitsi", kind: "synthetic" });
    expect(isCallLive(s)).toBe(true);
  });
});

describe("isUrgentLog", () => {
  it("flags a batch with a warn or error line", () => {
    expect(isUrgentLog([entry("a"), entry("b", "warn")])).toBe(true);
    expect(isUrgentLog([entry("a", "error")])).toBe(true);
    expect(isUrgentLog([entry("a"), entry("b", "info")])).toBe(false);
  });
});

describe("GatedForwarder", () => {
  it("holds while closed and keeps only the newest items", () => {
    const shipped: number[][] = [];
    const f = new GatedForwarder<number>((xs) => shipped.push(xs), 3, () => false);
    f.push([1, 2]);
    f.push([3, 4, 5]);
    expect(shipped).toEqual([]);
    expect(f.heldCount).toBe(3);
    f.drain();
    expect(shipped).toEqual([[3, 4, 5]]);
    expect(f.heldCount).toBe(0);
  });

  it("ships an urgent batch while closed, held items first", () => {
    const shipped: number[][] = [];
    const f = new GatedForwarder<number>((xs) => shipped.push(xs), 10, () => false);
    f.push([1]);
    f.push([2], true);
    expect(shipped).toEqual([[1, 2]]);
  });

  it("ships straight through while open, and never ships an empty batch", () => {
    const shipped: number[][] = [];
    const f = new GatedForwarder<number>((xs) => shipped.push(xs), 10, () => true);
    f.push([]);
    f.drain();
    f.push([1]);
    expect(shipped).toEqual([[1]]);
  });
});

describe("CallGate", () => {
  it("sends nothing while no call has started", () => {
    const shipped: string[][] = [];
    const gate = new CallGate(fakeTimers(), 1000);
    const out = gate.forwarder<string>((xs) => shipped.push(xs), 10);
    out.push(["perf"]);
    gate.setLive(false);
    out.push(["perf"]);
    expect(shipped).toEqual([]);
    expect(gate.open).toBe(false);
  });

  it("drains every stream when a call starts, then forwards directly", () => {
    const logs: string[][] = [];
    const perf: string[][] = [];
    const gate = new CallGate(fakeTimers(), 1000);
    const logOut = gate.forwarder<string>((xs) => logs.push(xs), 10);
    const perfOut = gate.forwarder<string>((xs) => perf.push(xs), 10);
    logOut.push(["pre-call"]);
    perfOut.push(["heap"]);
    gate.setLive(true);
    expect(logs).toEqual([["pre-call"]]);
    expect(perf).toEqual([["heap"]]);
    logOut.push(["in-call"]);
    expect(logs).toEqual([["pre-call"], ["in-call"]]);
  });

  it("stays open for the linger after the call ends, then holds again", () => {
    const timers = fakeTimers();
    const shipped: string[][] = [];
    const gate = new CallGate(timers, 1000);
    const out = gate.forwarder<string>((xs) => shipped.push(xs), 10);
    gate.setLive(true);
    gate.setLive(false);
    out.push(["meeting ended"]);
    expect(shipped).toEqual([["meeting ended"]]);
    timers.fire();
    expect(gate.open).toBe(false);
    out.push(["idle"]);
    expect(shipped).toEqual([["meeting ended"]]);
  });

  it("cancels the linger when a new call starts", () => {
    const timers = fakeTimers();
    const gate = new CallGate(timers, 1000);
    gate.setLive(true);
    gate.setLive(false);
    expect(timers.pending).toBe(1);
    gate.setLive(true);
    expect(timers.pending).toBe(0);
    expect(gate.open).toBe(true);
  });
});
