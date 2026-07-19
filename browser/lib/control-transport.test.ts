import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ControlSocket } from "./control-transport";

// Same FakeWebSocket approach as transport.test.ts: ControlSocket reaches for
// the global WebSocket constructor at call time, so swapping the global is
// enough.

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  url: string;
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

function sentJson(ws: FakeWebSocket): unknown[] {
  return ws.sent.map((s) => JSON.parse(s));
}

function connectAndOpen(socket: ControlSocket): FakeWebSocket {
  socket.connect();
  const ws = FakeWebSocket.instances.at(-1)!;
  ws.onopen?.();
  return ws;
}

describe("ControlSocket", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    (globalThis as unknown as { WebSocket: unknown }).WebSocket = FakeWebSocket;
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("targets ws://127.0.0.1:<port>/control", () => {
    const socket = new ControlSocket(47812);
    connectAndOpen(socket);
    expect(FakeWebSocket.instances[0]!.url).toBe("ws://127.0.0.1:47812/control");
  });

  it("meeting.resolve sends the wire request and resolves the meeting_id", async () => {
    const socket = new ControlSocket(47812);
    const ws = connectAndOpen(socket);

    const promise = socket.meetingResolve("meet", "AbC");
    expect(sentJson(ws)).toEqual([
      { cmd: "meeting.resolve", platform: "meet", external_id: "AbC" },
    ]);

    ws.respond({ ok: true, data: { meeting_id: "uuid-1" } });
    await expect(promise).resolves.toBe("uuid-1");
  });

  it("matches replies FIFO across pipelined requests", async () => {
    const socket = new ControlSocket(47812);
    const ws = connectAndOpen(socket);

    const open = socket.sessionOpen(["browser:meet:jane"], "uuid-1");
    const close = socket.sessionClose("sid-old");

    ws.respond({ ok: true, data: { id: "sid-new" } }); // answers open
    ws.respond({ ok: true, data: {} }); // answers close

    await expect(open).resolves.toBe("sid-new");
    await expect(close).resolves.toBeUndefined();
  });

  it("rejects on an ok:false reply with the daemon's error", async () => {
    const socket = new ControlSocket(47812);
    const ws = connectAndOpen(socket);

    const promise = socket.sessionAddSource("sid", "browser:meet:jane");
    ws.respond({ ok: false, error: "no such session 'sid'" });
    await expect(promise).rejects.toThrow(/no such session/);
  });

  it("rejects immediately when not connected", async () => {
    const socket = new ControlSocket(47812);
    await expect(socket.sessionClose("sid")).rejects.toThrow(/not connected/);
  });

  it("rejects in-flight requests when the socket drops, then reconnects with backoff", async () => {
    const socket = new ControlSocket(47812);
    const ws = connectAndOpen(socket);

    const inFlight = socket.sessionClose("sid");
    ws.onclose?.();
    await expect(inFlight).rejects.toThrow(/closed/);

    expect(FakeWebSocket.instances).toHaveLength(1);
    vi.advanceTimersByTime(500);
    expect(FakeWebSocket.instances).toHaveLength(2);
  });

  it("disconnect() is terminal — no reconnect is scheduled after it", () => {
    const socket = new ControlSocket(47812);
    connectAndOpen(socket);
    socket.disconnect();
    vi.advanceTimersByTime(60_000);
    expect(FakeWebSocket.instances).toHaveLength(1);
  });
});
