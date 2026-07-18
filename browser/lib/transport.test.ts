import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EarsSocket } from "./transport";
import { INGEST_FORMAT, sourceLabel } from "./protocol";

// EarsSocket reaches out to the global WebSocket constructor at call time
// (inside open()), not at module-load time, so swapping globalThis.WebSocket
// before each test is enough — no need to mock the module itself.

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  binaryType = "";
  bufferedAmount = 0;
  url: string;
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: unknown[] = [];

  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
  }

  send(data: unknown): void {
    this.sent.push(data);
  }

  close(): void {
    this.onclose?.();
  }

  respond(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) });
  }
}

function textSent(ws: FakeWebSocket): unknown[] {
  return ws.sent.filter((s) => typeof s === "string").map((s) => JSON.parse(s as string));
}

function binarySent(ws: FakeWebSocket): ArrayBuffer[] {
  return ws.sent.filter((s) => s instanceof ArrayBuffer) as ArrayBuffer[];
}

function decodeFrame(buf: ArrayBuffer): { streamId: string; pcm: Uint8Array } {
  const bytes = new Uint8Array(buf);
  const idLen = bytes[0]!;
  const streamId = new TextDecoder().decode(bytes.slice(1, 1 + idLen));
  return { streamId, pcm: bytes.slice(1 + idLen) };
}

/** Connects and drives the socket through to "connected", returning the ws. */
function connectAndOpen(socket: EarsSocket): FakeWebSocket {
  socket.connect();
  const ws = FakeWebSocket.instances.at(-1)!;
  ws.onopen?.();
  return ws;
}

describe("EarsSocket", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    (globalThis as unknown as { WebSocket: unknown }).WebSocket = FakeWebSocket;
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("refuses to open a non-loopback URL and never constructs a WebSocket", () => {
    class NonLoopbackSocket extends EarsSocket {
      override get url(): string {
        return "ws://example.com:47811/ingest";
      }
    }
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const socket = new NonLoopbackSocket(47811);
    socket.connect();
    expect(FakeWebSocket.instances).toHaveLength(0);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("non-loopback"));
    errorSpy.mockRestore();
  });

  it("reaches connected status once the socket opens, and reconnects with growing backoff on drop", () => {
    const statuses: string[] = [];
    const socket = new EarsSocket(47811, (s) => statuses.push(s));

    const ws1 = connectAndOpen(socket);
    expect(statuses).toEqual(["connecting", "connected"]);

    ws1.onclose?.();
    expect(statuses).toEqual(["connecting", "connected", "disconnected"]);
    expect(FakeWebSocket.instances).toHaveLength(1); // reconnect not yet fired

    vi.advanceTimersByTime(500); // BASE_BACKOFF_MS
    expect(FakeWebSocket.instances).toHaveLength(2);

    const ws2 = FakeWebSocket.instances[1]!;
    ws2.onclose?.(); // a second consecutive drop before ever reconnecting successfully
    vi.advanceTimersByTime(999);
    expect(FakeWebSocket.instances).toHaveLength(2); // not yet — backoff doubled to 1000ms
    vi.advanceTimersByTime(1);
    expect(FakeWebSocket.instances).toHaveLength(3);
  });

  it("ingest.open is sent once per participant; a stream_id is reused for later frames", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane-a1b2", "meet", new Uint8Array([1, 2]));
    expect(textSent(ws)).toEqual([
      { cmd: "ingest.open", source: sourceLabel("meet", "jane-a1b2"), format: INGEST_FORMAT },
    ]);
    expect(binarySent(ws)).toHaveLength(0); // queued until ingest.open resolves

    ws.respond({ ok: true, data: { stream_id: "s1" } });
    const firstBatch = binarySent(ws);
    expect(firstBatch).toHaveLength(1); // the queued frame flushes on open
    expect(decodeFrame(firstBatch[0]!).streamId).toBe("s1");

    socket.sendPcm("jane-a1b2", "meet", new Uint8Array([3, 4]));
    expect(textSent(ws)).toHaveLength(1); // still just the one ingest.open
    expect(binarySent(ws)).toHaveLength(2);
    expect(decodeFrame(binarySent(ws)[1]!).streamId).toBe("s1");
  });

  it("a failed ingest.open marks the participant failed and drops future frames without retry", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    ws.respond({ ok: false, error: "boom" });

    socket.sendPcm("jane", "meet", new Uint8Array([2]));
    expect(textSent(ws)).toHaveLength(1); // no retry ingest.open
    expect(binarySent(ws)).toHaveLength(0); // no frame ever sent
    warnSpy.mockRestore();
  });

  it("participantLeft sends ingest.close for the open stream and forgets it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    ws.respond({ ok: true, data: { stream_id: "s7" } });

    socket.participantLeft("jane");
    expect(textSent(ws).at(-1)).toEqual({ cmd: "ingest.close", stream_id: "s7" });

    // A later frame for the same id is treated as a brand-new participant.
    socket.sendPcm("jane", "meet", new Uint8Array([2]));
    const opens = textSent(ws).filter((m) => (m as { cmd: string }).cmd === "ingest.open");
    expect(opens).toHaveLength(2);
  });

  it("drops the newest-over-limit frame under back-pressure rather than growing an unbounded queue", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    ws.respond({ ok: true, data: { stream_id: "s1" } });
    expect(binarySent(ws)).toHaveLength(1);

    ws.bufferedAmount = (1 << 20) + 1; // over BUFFERED_AMOUNT_LIMIT
    socket.sendPcm("jane", "meet", new Uint8Array([2]));
    expect(binarySent(ws)).toHaveLength(1); // the new frame was dropped, not queued or sent

    ws.bufferedAmount = 0;
    socket.sendPcm("jane", "meet", new Uint8Array([3]));
    expect(binarySent(ws)).toHaveLength(2); // back to normal once drained
    warnSpy.mockRestore();
  });

  it("disconnect() is terminal — no reconnect is scheduled after it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);
    socket.disconnect();
    expect(FakeWebSocket.instances).toHaveLength(1);
    vi.advanceTimersByTime(60_000);
    expect(FakeWebSocket.instances).toHaveLength(1);
    void ws;
  });
});
