import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CLIENT_NAME, ControlError, ControlSocket } from "./control-transport";
import type { EventFrame, SnapshotWire } from "./protocol";

// Same FakeWebSocket approach as transport.test.ts: ControlSocket reaches for
// the global WebSocket constructor at call time, so swapping the global is
// enough.

class FakeWebSocket {
  static OPEN = 1;
  static instances: FakeWebSocket[] = [];
  url: string;
  readyState = FakeWebSocket.OPEN;
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: string[] = [];

  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    this.onclose?.();
  }

  respond(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) });
  }
}

function sentJson(ws: FakeWebSocket): Array<Record<string, unknown>> {
  return ws.sent.map((s) => JSON.parse(s) as Record<string, unknown>);
}

function connectAndOpen(socket: ControlSocket): FakeWebSocket {
  socket.connect();
  const ws = FakeWebSocket.instances.at(-1)!;
  ws.onopen?.();
  return ws;
}

const SNAPSHOT: SnapshotWire = { rev: 41, meetings: [], sources: [], sessions: [] };

/** Answers the hello + subscribe handshake so the socket reaches "ready". */
async function completeHandshake(ws: FakeWebSocket, bootId = "boot-1"): Promise<void> {
  const hello = sentJson(ws)[0]!;
  ws.respond({
    id: hello.id,
    result: { protocol: 2, daemon: "earsd-test", boot_id: bootId, capabilities: ["observe", "meetings"] },
  });
  await vi.waitFor(() => {
    expect(sentJson(ws).length).toBeGreaterThan(1);
  });
  const subscribe = sentJson(ws)[1]!;
  expect(subscribe.method).toBe("subscribe");
  ws.respond({ id: subscribe.id, result: SNAPSHOT });
}

async function readySocket(
  socket: ControlSocket,
): Promise<{ ws: FakeWebSocket; snapshots: SnapshotWire[] }> {
  const snapshots: SnapshotWire[] = [];
  socket.onReady = (snapshot) => snapshots.push(snapshot);
  const ws = connectAndOpen(socket);
  await completeHandshake(ws);
  await vi.waitFor(() => expect(snapshots).toHaveLength(1));
  return { ws, snapshots };
}

const MEETING = {
  id: "m-1",
  title: "meet abc",
  state: "active",
  started: "2026-07-19T10:00:00.000Z",
  intervals: [{ start: "2026-07-19T10:00:00.000Z", end: null }],
  attendees: [],
  sources: [],
  trigger: "browser-extension",
  rev: 1,
};

describe("ControlSocket (v2)", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    (globalThis as unknown as { WebSocket: unknown }).WebSocket = FakeWebSocket;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("targets ws://127.0.0.1:<port>/control", () => {
    const socket = new ControlSocket(47812);
    connectAndOpen(socket);
    expect(FakeWebSocket.instances[0]!.url).toBe("ws://127.0.0.1:47812/control");
  });

  it("sends hello first, then subscribe, then reports ready with the snapshot", async () => {
    const socket = new ControlSocket(47812);
    const { ws, snapshots } = await readySocket(socket);
    const frames = sentJson(ws);
    expect(frames[0]!.method).toBe("hello");
    expect(frames[0]!.params).toEqual({ protocol: 2, client: CLIENT_NAME });
    expect(frames[1]!.method).toBe("subscribe");
    expect(snapshots[0]).toEqual(SNAPSHOT);
  });

  it("meeting.start resolves the correlated result even out of order", async () => {
    const socket = new ControlSocket(47812);
    const { ws } = await readySocket(socket);

    const first = socket.meetingStart("meet", "abc");
    const second = socket.meetingEnd("m-1");
    const [startFrame, endFrame] = sentJson(ws).slice(2);

    // Answer in reverse order — correlation ids make this legal.
    ws.respond({ id: endFrame!.id, result: { ...MEETING, state: "ended" } });
    ws.respond({ id: startFrame!.id, result: MEETING });

    await expect(first).resolves.toEqual(MEETING);
    await expect(second).resolves.toMatchObject({ state: "ended" });
  });

  it("rejects with a coded ControlError on an error frame", async () => {
    const socket = new ControlSocket(47812);
    const { ws } = await readySocket(socket);

    const promise = socket.meetingPause("nope");
    const frame = sentJson(ws).at(-1)!;
    ws.respond({ id: frame.id, error: { code: "meeting_not_found", message: "no active meeting nope" } });

    await expect(promise).rejects.toThrow(/meeting_not_found/);
    await promise.catch((err: unknown) => {
      expect((err as ControlError).wire.code).toBe("meeting_not_found");
    });
  });

  it("routes notification frames to onEvent", async () => {
    const socket = new ControlSocket(47812);
    const events: EventFrame[] = [];
    socket.onEvent = (frame) => events.push(frame);
    const { ws } = await readySocket(socket);

    ws.respond({ event: "meeting", params: { meeting: MEETING }, rev: 42 });
    ws.respond({ event: "job", params: { job: "j1", kind: "transcribe", state: "running" } });

    expect(events).toHaveLength(2);
    expect(events[0]!.rev).toBe(42);
    expect(events[1]!.rev).toBeUndefined();
  });

  it("rejects immediately when not connected (or before the handshake lands)", async () => {
    const socket = new ControlSocket(47812);
    await expect(socket.meetingEnd("m-1")).rejects.toThrow(/not connected/);

    connectAndOpen(socket); // open but hello unanswered
    await expect(socket.meetingEnd("m-1")).rejects.toThrow(/not connected/);
  });

  it("rejects in-flight requests when the socket drops, then reconnects with backoff", async () => {
    vi.useFakeTimers();
    const socket = new ControlSocket(47812);
    const ws = connectAndOpen(socket);

    // The in-flight hello is stranded by the drop.
    expect(sentJson(ws)[0]!.method).toBe("hello");
    ws.onclose?.();

    expect(FakeWebSocket.instances).toHaveLength(1);
    vi.advanceTimersByTime(500);
    expect(FakeWebSocket.instances).toHaveLength(2);
  });

  it("re-runs the handshake on reconnect and flags a daemon restart via boot_id", async () => {
    const socket = new ControlSocket(47812);
    const bootChanges: boolean[] = [];
    socket.onReady = (_snapshot, bootChanged) => bootChanges.push(bootChanged);

    const first = connectAndOpen(socket);
    await completeHandshake(first, "boot-1");
    await vi.waitFor(() => expect(bootChanges).toHaveLength(1));

    vi.useFakeTimers();
    first.onclose?.();
    vi.advanceTimersByTime(500);
    vi.useRealTimers();

    const second = FakeWebSocket.instances.at(-1)!;
    second.onopen?.();
    await completeHandshake(second, "boot-2");
    await vi.waitFor(() => expect(bootChanges).toHaveLength(2));

    expect(bootChanges).toEqual([false, true]);
  });

  it("disconnect() is terminal — no reconnect is scheduled after it", () => {
    vi.useFakeTimers();
    const socket = new ControlSocket(47812);
    connectAndOpen(socket);
    socket.disconnect();
    vi.advanceTimersByTime(60_000);
    expect(FakeWebSocket.instances).toHaveLength(1);
  });
});
