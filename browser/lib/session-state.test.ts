import { beforeEach, describe, expect, it } from "vitest";
import {
  KEEPALIVE_ALARM,
  KEEPALIVE_PERIOD_MINUTES,
  SESSION_STATE_KEY,
  SessionTracker,
  parseSessionState,
  type AlarmsLike,
  type SessionAreaLike,
} from "./session-state";

// Plain-object fakes for the two browser APIs, same pattern as
// transport.test.ts's FakeWebSocket — no mocking library.

class FakeAlarms implements AlarmsLike {
  created: { name: string; periodInMinutes: number }[] = [];
  cleared: string[] = [];
  create(name: string, info: { periodInMinutes: number }): void {
    this.created.push({ name, periodInMinutes: info.periodInMinutes });
  }
  clear(name: string): void {
    this.cleared.push(name);
  }
}

class FakeSessionArea implements SessionAreaLike {
  store: Record<string, unknown> = {};
  async get(key: string): Promise<Record<string, unknown>> {
    return key in this.store ? { [key]: this.store[key] } : {};
  }
  async set(items: Record<string, unknown>): Promise<void> {
    Object.assign(this.store, items);
  }
  async remove(key: string): Promise<void> {
    delete this.store[key];
  }
}

describe("parseSessionState", () => {
  it("reads back what activate persists", () => {
    expect(parseSessionState({ active: true, platform: "meet" })).toEqual({
      active: true,
      platform: "meet",
    });
  });

  it("treats missing/malformed state as no active session", () => {
    expect(parseSessionState(undefined)).toEqual({ active: false });
    expect(parseSessionState(null)).toEqual({ active: false });
    expect(parseSessionState("yes")).toEqual({ active: false });
    expect(parseSessionState({ active: "true" })).toEqual({ active: false });
  });

  it("drops an unknown platform but keeps the active flag", () => {
    expect(parseSessionState({ active: true, platform: "skype" })).toEqual({ active: true });
  });
});

describe("SessionTracker", () => {
  let alarms: FakeAlarms;
  let session: FakeSessionArea;
  let tracker: SessionTracker;

  beforeEach(() => {
    alarms = new FakeAlarms();
    session = new FakeSessionArea();
    tracker = new SessionTracker(alarms, session);
  });

  it("arms the keepalive and persists state on the first participant only", async () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p1", "alice", "meet"); // repeat PCM frame
    tracker.participantActive("p1", "bob", "meet");
    await Promise.resolve(); // let the fire-and-forget storage write land

    expect(alarms.created).toEqual([{ name: KEEPALIVE_ALARM, periodInMinutes: KEEPALIVE_PERIOD_MINUTES }]);
    expect(session.store[SESSION_STATE_KEY]).toEqual({ active: true, platform: "meet" });
  });

  it("disarms and clears state only when the LAST participant leaves", async () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p1", "bob", "meet");
    tracker.participantLeft("p1", "alice");
    expect(alarms.cleared).toEqual([]);

    tracker.participantLeft("p1", "bob");
    await Promise.resolve();
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
    expect(session.store[SESSION_STATE_KEY]).toBeUndefined();
  });

  it("ignores a leave for a participant it never saw", () => {
    tracker.participantLeft("p1", "ghost");
    expect(alarms.cleared).toEqual([]);
  });

  it("counts participants across ports; one tab closing doesn't end the session", () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p2", "zoom-guy", "zoom");

    const orphaned = tracker.portDisconnected("p2");
    expect(orphaned).toEqual(["zoom-guy"]);
    expect(alarms.cleared).toEqual([]); // alice's session is still live
  });

  it("returns orphaned participants and ends the session on the last port's disconnect", async () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p1", "bob", "meet");

    const orphaned = tracker.portDisconnected("p1");
    await Promise.resolve();
    expect(orphaned).toEqual(["alice", "bob"]);
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
    expect(session.store[SESSION_STATE_KEY]).toBeUndefined();
  });

  it("disconnect of an unknown/empty port returns nothing and touches nothing", () => {
    expect(tracker.portDisconnected("never-seen")).toEqual([]);
    expect(alarms.cleared).toEqual([]);
  });

  it("restore() re-arms the keepalive after a worker respawn mid-session", async () => {
    session.store[SESSION_STATE_KEY] = { active: true, platform: "zoom" };
    await tracker.restore();
    expect(alarms.created).toEqual([{ name: KEEPALIVE_ALARM, periodInMinutes: KEEPALIVE_PERIOD_MINUTES }]);
  });

  it("restore() clears any stale alarm when no session was active", async () => {
    await tracker.restore();
    expect(alarms.created).toEqual([]);
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
  });

  it("restore() survives a failing storage read (treats it as inactive)", async () => {
    const failing: SessionAreaLike = {
      get: () => Promise.reject(new Error("gone")),
      set: () => Promise.resolve(),
      remove: () => Promise.resolve(),
    };
    const t = new SessionTracker(alarms, failing);
    await t.restore();
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
  });
});
