import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  colibriAudioOwner,
  colibriLocalEndpointId,
  endpointIdFromSourceName,
  installColibriSocketWatch,
  noteBridgeMessage,
  noteColibriSocket,
  observeBridgeDataChannel,
  parseBridgeMessage,
  parseColibriEndpointId,
  setBridgeListener,
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

// Live meet.jit.si messages (2026-11-22), as the JVB data channel delivered them.
const AUDIO_SOURCES_MAP =
  '{"colibriClass":"AudioSourcesMap","mappedSources":[{"source":"85b964a6-a0","owner":"85b964a6","ssrc":391968325}]}';
const SENDER_SOURCE_CONSTRAINTS = '{"colibriClass":"SenderSourceConstraints","sourceName":"831de82b-v0","maxHeight":360}';

describe("endpointIdFromSourceName", () => {
  it("strips the media suffix", () => {
    expect(endpointIdFromSourceName("831de82b-v0")).toBe("831de82b");
    expect(endpointIdFromSourceName("831de82b-a0")).toBe("831de82b");
    expect(endpointIdFromSourceName("jigasi-a1b2-v12")).toBe("jigasi-a1b2");
  });

  it("refuses anything that is not a source name", () => {
    expect(endpointIdFromSourceName("831de82b")).toBeNull();
    expect(endpointIdFromSourceName("831de82b-x0")).toBeNull();
    expect(endpointIdFromSourceName("a b-v0")).toBeNull();
    expect(endpointIdFromSourceName("-v0")).toBeNull();
    expect(endpointIdFromSourceName(42)).toBeNull();
  });
});

describe("parseBridgeMessage", () => {
  it("reads AudioSourcesMap and SenderSourceConstraints", () => {
    expect(parseBridgeMessage(AUDIO_SOURCES_MAP)).toEqual({
      kind: "audio-sources",
      sources: [{ ssrc: 391968325, owner: "85b964a6" }],
    });
    expect(parseBridgeMessage(SENDER_SOURCE_CONSTRAINTS)).toEqual({ kind: "local-endpoint", endpointId: "831de82b" });
  });

  it("ignores every other message type", () => {
    for (const msg of [
      '{"colibriClass":"EndpointStats","from":"85b964a6"}',
      '{"colibriClass":"DominantSpeakerEndpointChangeEvent","dominantSpeakerEndpoint":"85b964a6","previousSpeakers":[]}',
      '{"colibriClass":"ForwardedSources","forwardedSources":["85b964a6-v0"]}',
      '{"colibriClass":"EndpointMessage","from":"85b964a6","msgPayload":{"sourceName":"85b964a6-v0"}}',
      '{"colibriClass":"VideoSourcesMap","mappedSources":[{"source":"85b964a6-v0","owner":"85b964a6","ssrc":1}]}',
    ]) {
      expect(parseBridgeMessage(msg)).toBeNull();
    }
  });

  it("drops malformed, oversized and non-string frames, and bad entries", () => {
    expect(parseBridgeMessage('{"colibriClass":"AudioSourcesMap"')).toBeNull();
    expect(parseBridgeMessage(new ArrayBuffer(8))).toBeNull();
    expect(parseBridgeMessage(null)).toBeNull();
    expect(parseBridgeMessage(`${AUDIO_SOURCES_MAP}${" ".repeat(70_000)}`)).toBeNull();
    expect(parseBridgeMessage('{"colibriClass":"SenderSourceConstraints","sourceName":"bad id-v0"}')).toBeNull();
    expect(
      parseBridgeMessage(
        JSON.stringify({
          colibriClass: "AudioSourcesMap",
          mappedSources: [
            { owner: "aaaa0001", ssrc: -1 },
            { owner: "aaaa0001", ssrc: 2 ** 32 },
            { owner: "aaaa0001", ssrc: 1.5 },
            { owner: "a b", ssrc: 7 },
            { ssrc: 8 },
            null,
            { owner: "bbbb0002", ssrc: 9 },
          ],
        }),
      ),
    ).toEqual({ kind: "audio-sources", sources: [{ ssrc: 9, owner: "bbbb0002" }] });
  });
});

// The watch installs on `window`; node has none, so give it the global object
// and a fake native WebSocket that records how it was built.
class FakeSocket {
  static readonly OPEN = 1;
  readonly listeners: Array<(ev: { data: unknown }) => void> = [];
  constructor(
    readonly url: string,
    readonly protocols?: string | string[],
  ) {}
  addEventListener(_type: string, fn: (ev: { data: unknown }) => void): void {
    this.listeners.push(fn);
  }
}

type TestWindow = {
  window?: unknown;
  WebSocket?: unknown;
  __earsColibriWatch?: boolean;
  __earsJitsiLocalEndpoint?: string;
  __earsJitsiAudioOwners?: Map<number, string>;
  __earsJitsiBridgeListener?: () => void;
};
const g = globalThis as unknown as TestWindow;

function resetBridgeState(): void {
  delete g.__earsColibriWatch;
  delete g.__earsJitsiLocalEndpoint;
  delete g.__earsJitsiAudioOwners;
  delete g.__earsJitsiBridgeListener;
}

describe("bridge channel state", () => {
  let savedWindow: unknown;

  beforeEach(() => {
    savedWindow = g.window;
    g.window = globalThis;
    resetBridgeState();
    vi.spyOn(console, "debug").mockImplementation(() => {});
  });

  afterEach(() => {
    g.window = savedWindow;
    resetBridgeState();
    vi.restoreAllMocks();
  });

  it("records slot owners and the local id from data-channel messages, without touching the event", () => {
    const listeners: Array<(ev: { data: unknown }) => void> = [];
    observeBridgeDataChannel({ addEventListener: (_t, fn) => listeners.push(fn) });
    const changed = vi.fn();
    setBridgeListener(changed);
    const ev = Object.freeze({ data: AUDIO_SOURCES_MAP });
    for (const fn of listeners) fn(ev);
    expect(colibriAudioOwner(391968325)).toBe("85b964a6");
    expect(colibriLocalEndpointId()).toBeNull(); // camera off: no SenderSourceConstraints, no local id
    for (const fn of listeners) fn({ data: SENDER_SOURCE_CONSTRAINTS });
    expect(colibriLocalEndpointId()).toBe("831de82b");
    expect(changed).toHaveBeenCalledTimes(2);
    // Repeats are not changes; garbage never throws into the page's channel.
    for (const fn of listeners) fn({ data: AUDIO_SOURCES_MAP });
    for (const fn of listeners) fn({ data: "{not json AudioSourcesMap" });
    expect(changed).toHaveBeenCalledTimes(2);
  });

  it("takes the newest owner for a reused slot", () => {
    noteBridgeMessage(AUDIO_SOURCES_MAP);
    noteBridgeMessage(
      '{"colibriClass":"AudioSourcesMap","mappedSources":[{"source":"4494e60c-a0","owner":"4494e60c","ssrc":391968325}]}',
    );
    expect(colibriAudioOwner(391968325)).toBe("4494e60c");
  });

  it("keeps at most 64 slot owners, dropping the stalest", () => {
    for (let ssrc = 1; ssrc <= 70; ssrc++) {
      noteBridgeMessage(JSON.stringify({ colibriClass: "AudioSourcesMap", mappedSources: [{ owner: `e${ssrc}`, ssrc }] }));
    }
    expect(g.__earsJitsiAudioOwners?.size).toBe(64);
    expect(colibriAudioOwner(1)).toBeNull();
    expect(colibriAudioOwner(70)).toBe("e70");
  });

  it("a disposed listener unregisters only itself", () => {
    const a = vi.fn();
    const b = vi.fn();
    setBridgeListener(a);
    setBridgeListener(b);
    setBridgeListener(null, a); // a was superseded: b stays
    noteBridgeMessage(AUDIO_SOURCES_MAP);
    expect(a).not.toHaveBeenCalled();
    expect(b).toHaveBeenCalledTimes(1);
    setBridgeListener(null, b);
    expect(g.__earsJitsiBridgeListener).toBeUndefined();
  });

  it("a throwing listener never escapes", () => {
    setBridgeListener(() => {
      throw new Error("boom");
    });
    expect(() => noteBridgeMessage(AUDIO_SOURCES_MAP)).not.toThrow();
  });
});

describe("installColibriSocketWatch", () => {
  let saved: Pick<TestWindow, "window" | "WebSocket">;

  beforeEach(() => {
    saved = { window: g.window, WebSocket: g.WebSocket };
    g.window = globalThis;
    g.WebSocket = FakeSocket;
    resetBridgeState();
    vi.spyOn(console, "debug").mockImplementation(() => {});
  });

  afterEach(() => {
    g.window = saved.window;
    g.WebSocket = saved.WebSocket;
    resetBridgeState();
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

  it("ignores other sockets, and never listens to them", () => {
    installColibriSocketWatch();
    const Ctor = g.WebSocket as unknown as new (url: string) => FakeSocket;
    const ws = new Ctor("wss://meet.jit.si/xmpp-websocket?room=x");
    expect(colibriLocalEndpointId()).toBeNull();
    expect(ws.listeners).toHaveLength(0);
  });

  it("reads slot owners from a colibri socket's messages with the shared parser", () => {
    installColibriSocketWatch();
    const Ctor = g.WebSocket as unknown as new (url: string) => FakeSocket;
    const ws = new Ctor("wss://bridge.example/colibri-ws/jvb1/conf/831de82b?pwd=secret");
    expect(ws.listeners).toHaveLength(1);
    ws.listeners[0]!({ data: AUDIO_SOURCES_MAP });
    expect(colibriAudioOwner(391968325)).toBe("85b964a6");
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
