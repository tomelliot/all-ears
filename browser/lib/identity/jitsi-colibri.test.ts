import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  colibriLocalEndpointId,
  installColibriSocketWatch,
  noteColibriSocket,
  parseColibriEndpointId,
} from "./jitsi-colibri";

describe("parseColibriEndpointId", () => {
  it("reads the endpoint id from a colibri-ws URL", () => {
    expect(
      parseColibriEndpointId(
        "wss://meet-jit-si-eu-west-2-1.jitsi.net:443/colibri-ws/jvb-123/3f0c9b1e4a2d6e7f/831de82b?pwd=secret",
      ),
    ).toBe("831de82b");
    expect(parseColibriEndpointId("wss://jitsi.example.org/colibri-ws/default-id/abc/jigasi-a1b2")).toBe("jigasi-a1b2");
  });

  it("tolerates a reverse-proxy path prefix", () => {
    expect(parseColibriEndpointId("wss://example.org/bridge1/colibri-ws/jvb1/conf/831de82b?pwd=x")).toBe("831de82b");
  });

  it("returns null for every other socket", () => {
    expect(parseColibriEndpointId("wss://meet.jit.si/xmpp-websocket?room=weeklystandup")).toBeNull();
    expect(parseColibriEndpointId("wss://example.org/colibri-relay-ws/jvb1/conf/relay-1?pwd=x")).toBeNull();
    expect(parseColibriEndpointId("wss://example.org/colibri-ws/jvb1/conf")).toBeNull();
    expect(parseColibriEndpointId("https://example.org/colibri-ws/jvb1/conf/831de82b")).toBeNull();
    expect(parseColibriEndpointId("wss://example.org/colibri-ws/jvb1/conf/%E0%A4%A")).toBeNull();
    expect(parseColibriEndpointId("wss://example.org/colibri-ws/jvb1/conf/a%20b")).toBeNull();
    expect(parseColibriEndpointId("not a url")).toBeNull();
    expect(parseColibriEndpointId(null)).toBeNull();
  });
});

// The watch installs on `window`; node has none, so give it the global object
// and a fake native WebSocket that records how it was built.
class FakeSocket {
  static readonly OPEN = 1;
  constructor(
    readonly url: string,
    readonly protocols?: string | string[],
  ) {}
}

type TestWindow = {
  window?: unknown;
  WebSocket?: unknown;
  __earsColibriWatch?: boolean;
  __earsJitsiLocalEndpoint?: string;
};
const g = globalThis as unknown as TestWindow;

describe("installColibriSocketWatch", () => {
  let saved: Pick<TestWindow, "window" | "WebSocket">;

  beforeEach(() => {
    saved = { window: g.window, WebSocket: g.WebSocket };
    g.window = globalThis;
    g.WebSocket = FakeSocket;
    delete g.__earsColibriWatch;
    delete g.__earsJitsiLocalEndpoint;
    vi.spyOn(console, "debug").mockImplementation(() => {});
  });

  afterEach(() => {
    g.window = saved.window;
    g.WebSocket = saved.WebSocket;
    delete g.__earsColibriWatch;
    delete g.__earsJitsiLocalEndpoint;
    vi.restoreAllMocks();
  });

  it("records the endpoint id and hands back the native socket untouched", () => {
    installColibriSocketWatch();
    const Ctor = g.WebSocket as unknown as new (url: string, p?: string) => FakeSocket;
    expect(Ctor).not.toBe(FakeSocket);
    const ws = new Ctor("wss://bridge.example/colibri-ws/jvb1/conf/831de82b?pwd=secret", "proto");
    expect(ws).toBeInstanceOf(FakeSocket);
    expect(ws).toBeInstanceOf(Ctor);
    expect(ws.protocols).toBe("proto");
    expect((Ctor as unknown as typeof FakeSocket).OPEN).toBe(1);
    expect(colibriLocalEndpointId()).toBe("831de82b");
    // Only the id is kept, never the URL with its password.
    const ours = Object.keys(g).filter((k) => k.startsWith("__ears"));
    expect(ours.map((k) => String(g[k as keyof TestWindow]))).not.toContain(expect.stringContaining("secret"));
    expect(vi.mocked(console.debug).mock.calls.flat().join(" ")).not.toContain("secret");
  });

  it("ignores other sockets", () => {
    installColibriSocketWatch();
    const Ctor = g.WebSocket as unknown as new (url: string) => FakeSocket;
    new Ctor("wss://meet.jit.si/xmpp-websocket?room=x");
    expect(colibriLocalEndpointId()).toBeNull();
  });

  it("wraps once per realm", () => {
    installColibriSocketWatch();
    const first = g.WebSocket;
    installColibriSocketWatch();
    expect(g.WebSocket).toBe(first);
  });

  it("keeps the newest endpoint id", () => {
    noteColibriSocket("wss://b/colibri-ws/jvb1/conf/831de82b");
    noteColibriSocket("wss://b/colibri-ws/jvb2/conf2/5c1a7f02");
    expect(colibriLocalEndpointId()).toBe("5c1a7f02");
  });
});
