import { describe, expect, it } from "vitest";
import { MeetingTracker, type MeetingControl, type MeetingState } from "./meeting-tracker";
import type { AttendeeUpsert, MeetingWire, SnapshotWire } from "./protocol";

// The tracker is a signal forwarder in v2: the daemon owns the meeting state
// machine, so these tests assert exactly which meeting verbs each DOM signal
// turns into — no session churn, no client-side pause emulation.

function meetingWire(overrides: Partial<MeetingWire> = {}): MeetingWire {
  return {
    id: "m-1",
    identity: { platform: "meet", external_id: "abc" },
    title: "meet abc",
    state: "active",
    started: "2026-07-19T10:00:00.000Z",
    intervals: [{ start: "2026-07-19T10:00:00.000Z", end: null }],
    attendees: [],
    sources: [],
    trigger: "browser-extension",
    rev: 1,
    ...overrides,
  };
}

type Call =
  | { verb: "start"; platform: string; externalMeetingId: string }
  | { verb: "end" | "pause" | "resume"; meeting: string }
  | { verb: "attendee"; meeting: string; attendee: AttendeeUpsert };

/** Records every verb; resolves immediately unless `deferStart` holds the
 * meeting.start promise open for in-flight-race tests. */
class FakeControl implements MeetingControl {
  calls: Call[] = [];
  deferStart = false;
  private startResolvers: Array<(m: MeetingWire) => void> = [];
  startResult: MeetingWire = meetingWire();

  meetingStart(platform: string, externalMeetingId: string): Promise<MeetingWire> {
    this.calls.push({ verb: "start", platform, externalMeetingId });
    if (this.deferStart) {
      return new Promise((resolve) => this.startResolvers.push(resolve));
    }
    return Promise.resolve(this.startResult);
  }

  resolveStart(meeting: MeetingWire = this.startResult): void {
    this.startResolvers.shift()?.(meeting);
  }

  meetingEnd(meeting: string): Promise<MeetingWire> {
    this.calls.push({ verb: "end", meeting });
    return Promise.resolve(meetingWire({ id: meeting, state: "ended" }));
  }

  meetingPause(meeting: string): Promise<MeetingWire> {
    this.calls.push({ verb: "pause", meeting });
    return Promise.resolve(meetingWire({ id: meeting, state: "paused" }));
  }

  meetingResume(meeting: string): Promise<MeetingWire> {
    this.calls.push({ verb: "resume", meeting });
    return Promise.resolve(meetingWire({ id: meeting, state: "active" }));
  }

  meetingAttendee(meeting: string, attendee: AttendeeUpsert): Promise<MeetingWire> {
    this.calls.push({ verb: "attendee", meeting, attendee });
    return Promise.resolve(meetingWire({ id: meeting }));
  }

  ofVerb(verb: Call["verb"]): Call[] {
    return this.calls.filter((c) => c.verb === verb);
  }
}

const NOW = "2026-07-19T11:00:00.000Z";

function makeTracker(control: FakeControl): {
  tracker: MeetingTracker;
  states: MeetingState[];
} {
  const states: MeetingState[] = [];
  const tracker = new MeetingTracker(control, (s) => states.push(s), () => NOW);
  return { tracker, states };
}

async function flush(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
}

describe("MeetingTracker (v2 signal forwarder)", () => {
  it("meeting-started declares the meeting and records its daemon id", async () => {
    const control = new FakeControl();
    const { tracker, states } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    expect(control.calls).toEqual([{ verb: "start", platform: "meet", externalMeetingId: "abc" }]);
    expect(states).toEqual(["recording"]);
    expect(tracker.meetingActive).toBe(true);
  });

  it("externalIdFor answers for the declaring port and goes silent once the meeting ends", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    expect(tracker.externalIdFor("p1", "meet")).toBeUndefined();

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(tracker.externalIdFor("p1", "meet")).toBe("abc");
    expect(tracker.externalIdFor("p2", "meet")).toBeUndefined(); // another tab's port
    expect(tracker.externalIdFor("p1", "zoom")).toBeUndefined(); // platform mismatch

    tracker.meetingEnded("abc");
    await flush();
    expect(tracker.externalIdFor("p1", "meet")).toBeUndefined();
  });

  it("a duplicate meeting-started is not re-declared", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    expect(control.ofVerb("start")).toHaveLength(1);
  });

  it("attendee signals queue until the meeting id lands, then flush in order", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.participantJoined("p1", "meet", "jane", "Jane Doe");
    tracker.streamOpened("p1", "meet", "jane");
    expect(control.ofVerb("attendee")).toHaveLength(0); // still queued

    control.resolveStart();
    await flush();

    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", meeting: "m-1", attendee: { id: "jane", display_name: "Jane Doe" } },
      {
        verb: "attendee",
        meeting: "m-1",
        attendee: { id: "jane", source: "browser:meet:jane" },
      },
    ]);
  });

  it("buffers participant/stream signals that arrive before meeting-started and flushes them once it lands", async () => {
    // The linkage race: the tab's participant-joined / ingest stream-opened
    // events beat the Meet meeting-id resolution, so meeting-started arrives
    // last. These must not be dropped (which stranded the meeting with no
    // attendees and no browser:* source).
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.participantJoined("p1", "meet", "jane", "Jane Doe");
    tracker.streamOpened("p1", "meet", "jane");
    expect(control.ofVerb("attendee")).toHaveLength(0); // no record yet — buffered

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    expect(control.ofVerb("start")).toEqual([{ verb: "start", platform: "meet", externalMeetingId: "abc" }]);
    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", meeting: "m-1", attendee: { id: "jane", display_name: "Jane Doe" } },
      { verb: "attendee", meeting: "m-1", attendee: { id: "jane", source: "browser:meet:jane" } },
    ]);
  });

  it("drops buffered pre-start signals if the port disconnects before declaring", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.participantJoined("p1", "meet", "jane", "Jane Doe");
    tracker.portDisconnected("p1");

    // A later meeting on the same port id must not resurrect the dropped signal.
    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("attendee")).toHaveLength(0);
  });

  it("participant-left upserts a left timestamp; the last leaver ends the meeting", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.participantJoined("p1", "meet", "jane", "Jane");
    tracker.participantJoined("p1", "meet", "marcus", "Marcus");
    await flush();

    tracker.participantLeft("p1", "jane");
    await flush();
    expect(control.ofVerb("end")).toHaveLength(0);
    expect(control.calls.at(-1)).toEqual({
      verb: "attendee",
      meeting: "m-1",
      attendee: { id: "jane", left: NOW },
    });

    tracker.participantLeft("p1", "marcus");
    await flush();
    expect(control.ofVerb("end")).toEqual([{ verb: "end", meeting: "m-1" }]);
    expect(tracker.meetingActive).toBe(false);
  });

  it("rosterUpdate upserts display-name-only attendees keyed by device id (issue #23)", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.rosterUpdate("p1", "meet", [
      { participantId: "spaces/s/devices/445", displayName: "Tom Elliot" },
      { participantId: "spaces/s/devices/446", displayName: "Tom E" },
    ]);
    await flush();

    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", meeting: "m-1", attendee: { id: "spaces/s/devices/445", display_name: "Tom Elliot" } },
      { verb: "attendee", meeting: "m-1", attendee: { id: "spaces/s/devices/446", display_name: "Tom E" } },
    ]);
  });

  it("a roster name is identity-only: it does not enrol a capture participant or keep the meeting alive", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    // One real capture participant plus a roster name for someone never captured.
    tracker.participantJoined("p1", "meet", "speaker-1");
    tracker.rosterUpdate("p1", "meet", [{ participantId: "spaces/s/devices/445", displayName: "Tom Elliot" }]);
    await flush();

    // The only capture participant leaving ends the meeting — the roster name
    // must not count as a live participant that strands it open.
    tracker.participantLeft("p1", "speaker-1");
    await flush();
    expect(control.ofVerb("end")).toEqual([{ verb: "end", meeting: "m-1" }]);
    expect(tracker.meetingActive).toBe(false);
  });

  it("buffers roster names that arrive before meeting-started and flushes them once it lands", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.rosterUpdate("p1", "meet", [{ participantId: "spaces/s/devices/445", displayName: "Tom Elliot" }]);
    expect(control.ofVerb("attendee")).toHaveLength(0); // no record yet — buffered

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", meeting: "m-1", attendee: { id: "spaces/s/devices/445", display_name: "Tom Elliot" } },
    ]);
  });

  it("rosterUpdate with an empty batch is a no-op", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.rosterUpdate("p1", "meet", []);
    await flush();
    expect(control.ofVerb("attendee")).toHaveLength(0);
  });

  it("the pause toggle maps to meeting.pause / meeting.resume — never session churn", async () => {
    const control = new FakeControl();
    const { tracker, states } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    await tracker.setPaused(true);
    expect(control.ofVerb("pause")).toEqual([{ verb: "pause", meeting: "m-1" }]);
    expect(states).toEqual(["recording", "paused"]);
    expect(tracker.paused).toBe(true);

    await tracker.setPaused(false);
    expect(control.ofVerb("resume")).toEqual([{ verb: "resume", meeting: "m-1" }]);
    expect(tracker.paused).toBe(false);
  });

  it("a pause toggled before the meeting id lands is applied when it does", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await tracker.setPaused(true);
    expect(control.ofVerb("pause")).toHaveLength(0); // no id yet

    control.resolveStart();
    await flush();
    expect(control.ofVerb("pause")).toEqual([{ verb: "pause", meeting: "m-1" }]);
  });

  it("meeting-ended and port disconnect both end the daemon meeting", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.meetingEnded("abc");
    await flush();
    expect(control.ofVerb("end")).toEqual([{ verb: "end", meeting: "m-1" }]);

    control.startResult = meetingWire({
      id: "m-2",
      identity: { platform: "meet", external_id: "xyz" },
    });
    tracker.meetingStarted("p2", "meet", "xyz");
    await flush();
    tracker.portDisconnected("p2");
    await flush();
    expect(control.ofVerb("end").at(-1)).toEqual({ verb: "end", meeting: "m-2" });
  });

  it("a meeting ended while meeting.start is in flight is ended once the id lands", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.meetingEnded("abc");
    expect(control.ofVerb("end")).toHaveLength(0);

    control.resolveStart();
    await flush();
    expect(control.ofVerb("end")).toEqual([{ verb: "end", meeting: "m-1" }]);
  });

  it("job telemetry drives the transcribing badge with real pipeline state", async () => {
    const control = new FakeControl();
    const { tracker, states } = makeTracker(control);

    tracker.jobEvent({
      event: "job",
      params: { job: "j1", kind: "transcribe", meeting: "m-1", state: "started" },
    });
    expect(states).toEqual(["transcribing"]);

    tracker.jobEvent({
      event: "job",
      params: { job: "j1", kind: "transcribe", meeting: "m-1", state: "done" },
    });
    expect(states).toEqual(["transcribing", "idle"]);
  });

  it("onReady re-declares live meetings (idempotent recovery) and adopts daemon pause state", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("start")).toHaveLength(1);

    // Reconnect: the daemon says the meeting is paused (e.g. paused from the
    // CLI while the worker was evicted).
    const snapshot: SnapshotWire = {
      rev: 50,
      meetings: [meetingWire({ state: "paused" })],
      sources: [],
      sessions: [],
    };
    control.startResult = meetingWire({ state: "paused" });
    tracker.onReady(snapshot, true);
    await flush();

    expect(control.ofVerb("start")).toHaveLength(2); // re-declared, converges
    expect(tracker.paused).toBe(true);
  });
});
