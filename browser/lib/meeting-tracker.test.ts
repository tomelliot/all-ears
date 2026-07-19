import { describe, expect, it, vi } from "vitest";
import {
  MeetingTracker,
  type MeetingControl,
  type MeetingState,
  type TimersLike,
} from "./meeting-tracker";

// Hand-rolled recording fake for the control plane (no network), plus manual
// timers so the "transcribing" hold window is driven explicitly.

class FakeControl implements MeetingControl {
  calls: Array<{ op: string; args: unknown[] }> = [];
  nextMeetingId = "meeting-uuid-1";
  private nextSession = 0;
  failOpen = false;

  async meetingResolve(platform: string, externalMeetingId: string): Promise<string> {
    this.calls.push({ op: "meetingResolve", args: [platform, externalMeetingId] });
    return this.nextMeetingId;
  }

  async sessionOpen(sources: readonly string[], slug: string): Promise<string> {
    this.calls.push({ op: "sessionOpen", args: [[...sources], slug] });
    if (this.failOpen) throw new Error("open failed");
    return `session-${++this.nextSession}`;
  }

  async sessionClose(id: string): Promise<void> {
    this.calls.push({ op: "sessionClose", args: [id] });
  }

  async sessionAddSource(id: string, source: string): Promise<void> {
    this.calls.push({ op: "sessionAddSource", args: [id, source] });
  }

  ops(op: string): Array<unknown[]> {
    return this.calls.filter((c) => c.op === op).map((c) => c.args);
  }
}

class ManualTimers implements TimersLike {
  pending: Array<{ fn: () => void }> = [];
  set(fn: () => void): unknown {
    const handle = { fn };
    this.pending.push(handle);
    return handle;
  }
  clear(handle: unknown): void {
    this.pending = this.pending.filter((p) => p !== handle);
  }
  fireAll(): void {
    const fire = this.pending.splice(0, this.pending.length);
    for (const p of fire) p.fn();
  }
}

function makeTracker(control = new FakeControl()) {
  const states: MeetingState[] = [];
  const timers = new ManualTimers();
  const tracker = new MeetingTracker(control, (s) => states.push(s), timers);
  return { tracker, control, states, timers };
}

const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

describe("MeetingTracker", () => {
  it("resolves the meeting then opens a session once a source is open, slug = meeting UUID", async () => {
    const { tracker, control, states } = makeTracker();

    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    expect(control.ops("meetingResolve")).toEqual([["meet", "AbC"]]);
    expect(control.ops("sessionOpen")).toEqual([]); // no open sources yet
    expect(tracker.state).toBe("recording");

    tracker.streamOpened("pcm-0", "meet", "spaces/AbC/devices/1");
    await flush();
    expect(control.ops("sessionOpen")).toEqual([
      [["browser:meet:spaces-AbC-devices-1"], "meeting-uuid-1"],
    ]);
    expect(states).toContain("recording");
  });

  it("adds later participants to the open session via session.add_source", async () => {
    const { tracker, control } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    await flush();

    tracker.streamOpened("pcm-0", "meet", "john");
    await flush();
    expect(control.ops("sessionAddSource")).toEqual([["session-1", "browser:meet:john"]]);

    // A repeat open for the same participant is a no-op.
    tracker.streamOpened("pcm-0", "meet", "john");
    await flush();
    expect(control.ops("sessionAddSource")).toHaveLength(1);
  });

  it("pause closes the session without touching capture; resume opens a fresh one", async () => {
    const { tracker, control } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    await flush();

    await tracker.setPaused(true);
    expect(control.ops("sessionClose")).toEqual([["session-1"]]);
    expect(tracker.state).toBe("paused");

    // Sources opening while paused are remembered but no session is opened.
    tracker.streamOpened("pcm-0", "meet", "john");
    await flush();
    expect(control.ops("sessionOpen")).toHaveLength(1);

    await tracker.setPaused(false);
    expect(tracker.state).toBe("recording");
    const opens = control.ops("sessionOpen");
    expect(opens).toHaveLength(2);
    // The fresh session reuses the same meeting UUID as slug and carries both sources.
    expect(opens[1]![1]).toBe("meeting-uuid-1");
    expect(new Set(opens[1]![0] as string[])).toEqual(
      new Set(["browser:meet:jane", "browser:meet:john"]),
    );
  });

  it("meeting end closes the session and holds a time-boxed transcribing state", async () => {
    const { tracker, control, timers } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    await flush();

    tracker.meetingEnded("AbC");
    await flush();
    expect(control.ops("sessionClose")).toEqual([["session-1"]]);
    expect(tracker.state).toBe("transcribing");
    expect(tracker.meetingActive).toBe(false);

    timers.fireAll();
    expect(tracker.state).toBe("idle");
  });

  it("the last participant leaving ends the meeting", async () => {
    const { tracker, control } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    tracker.streamOpened("pcm-0", "meet", "john");
    await flush();

    tracker.participantLeft("pcm-0", "jane");
    expect(tracker.meetingActive).toBe(true);
    tracker.participantLeft("pcm-0", "john");
    await flush();
    expect(tracker.meetingActive).toBe(false);
    expect(control.ops("sessionClose")).toEqual([["session-1"]]);
  });

  it("a port disconnect ends that port's meeting", async () => {
    const { tracker, control } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    await flush();

    tracker.portDisconnected("pcm-0");
    await flush();
    expect(tracker.meetingActive).toBe(false);
    expect(control.ops("sessionClose")).toEqual([["session-1"]]);
  });

  it("re-joining the same meeting opens a second session under the same meeting UUID", async () => {
    const { tracker, control, timers } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    await flush();
    tracker.meetingEnded("AbC");
    await flush();
    timers.fireAll();

    tracker.meetingStarted("pcm-1", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-1", "meet", "jane");
    await flush();

    // Two resolves for the same external id (the daemon answers with the same
    // UUID both times), two distinct sessions sharing the slug.
    expect(control.ops("meetingResolve")).toEqual([
      ["meet", "AbC"],
      ["meet", "AbC"],
    ]);
    const opens = control.ops("sessionOpen");
    expect(opens).toHaveLength(2);
    expect(opens[0]![1]).toBe("meeting-uuid-1");
    expect(opens[1]![1]).toBe("meeting-uuid-1");
  });

  it("a session.open failure is logged, not fatal, and doesn't wedge the tracker", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const control = new FakeControl();
    control.failOpen = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();
    tracker.streamOpened("pcm-0", "meet", "jane");
    await flush();
    expect(warnSpy).toHaveBeenCalled();

    // Recovery: a later stream open retries the session.open.
    control.failOpen = false;
    tracker.streamOpened("pcm-0", "meet", "john");
    await flush();
    expect(control.ops("sessionOpen")).toHaveLength(2);
    warnSpy.mockRestore();
  });

  it("a meeting ending while session.open is in flight closes the just-opened session", async () => {
    const { tracker, control } = makeTracker();
    tracker.meetingStarted("pcm-0", "meet", "AbC");
    await flush();

    // streamOpened kicks off sessionOpen; end the meeting before it settles.
    tracker.streamOpened("pcm-0", "meet", "jane");
    tracker.meetingEnded("AbC");
    await flush();

    // The open landed after the end, so the tracker closed it right back.
    expect(control.ops("sessionOpen")).toHaveLength(1);
    expect(control.ops("sessionClose")).toEqual([["session-1"]]);
    expect(tracker.meetingActive).toBe(false);
  });
});
