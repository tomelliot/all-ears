import { gzipSync } from "node:zlib";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { formatChannelSummary, installHook, setCollectionsListener, watchJvbDataChannels } from "./rtc-hook";
import { setUpGlobals } from "./rtc-test-helpers";
import type { CollectionsMuteEvent } from "./identity/meet-collections";
import { colibriAudioOwner } from "./identity/jitsi-colibri";

// Node has global ReadableStream/WritableStream (18+); no DOM needed. We fake
// just enough of the browser surface (window === globalThis, location,
// RTCPeerConnection, RTCRtpReceiver) for installHook()'s Meet-only tee to run
// against real stream objects.

// ── Meet collections datachannel (production tracer, not the debug one) ────

interface FakeDataChannel {
  label: string;
  addEventListener(type: string, fn: (ev: unknown) => void): void;
  dispatch(type: string, ev: unknown): void;
}

function fakeDataChannel(label: string): FakeDataChannel {
  const listeners = new Map<string, Set<(ev: unknown) => void>>();
  return {
    label,
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type)!.add(fn);
    },
    dispatch(type, ev) {
      for (const fn of [...(listeners.get(type) ?? [])]) fn(ev);
    },
  };
}

// Minimal synthetic protobuf encoder matching the documented 1.2.3.{2,10}
// schema (journal #49) — same approach as identity/meet-collections.test.ts;
// see that file's header comment for why real captured fixtures aren't used.
function encodeVarint(n: bigint): number[] {
  const out: number[] = [];
  let v = n;
  do {
    let byte = Number(v & 0x7fn);
    v >>= 7n;
    if (v > 0n) byte |= 0x80;
    out.push(byte);
  } while (v > 0n);
  return out;
}
function tag(fieldNumber: number, wireType: number): number[] {
  return encodeVarint(BigInt((fieldNumber << 3) | wireType));
}
function lenDelim(fieldNumber: number, payload: number[]): number[] {
  return [...tag(fieldNumber, 2), ...encodeVarint(BigInt(payload.length)), ...payload];
}
function varintField(fieldNumber: number, value: number): number[] {
  return [...tag(fieldNumber, 0), ...encodeVarint(BigInt(value))];
}
function stringField(fieldNumber: number, value: string): number[] {
  return lenDelim(fieldNumber, Array.from(new TextEncoder().encode(value)));
}
function collectionsMessageBytes(deviceId: string, flag: number): ArrayBuffer {
  // Path 1.2.3.2.6 (device id) and 1.2.3.2.10.1 (flag) — live-verified
  // 2026-07-19 (see identity/meet-collections.ts's header comment): the flag
  // lives inside the same per-device record (field 2, nested under field 3)
  // as the device id, not as a sibling of that record under field 3.
  const perDeviceRecord = [...stringField(6, deviceId), ...lenDelim(10, varintField(1, flag))];
  const field3 = lenDelim(3, lenDelim(2, perDeviceRecord));
  const field2 = lenDelim(2, field3);
  const root = Uint8Array.from(lenDelim(1, field2));
  const gz = gzipSync(Buffer.from(root));
  return gz.buffer.slice(gz.byteOffset, gz.byteOffset + gz.byteLength);
}

describe("Meet collections datachannel (rtc-hook.ts)", () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    // setCollectionsListener touches `window`, which only exists once a test's
    // globals are set up. Establish it here too: this file no longer shares a
    // module with the tee tests whose earlier setUpGlobals used to provide it.
    (globalThis as unknown as { window?: unknown }).window = globalThis;
    // The collections listener is a shared window global and each message
    // decodes asynchronously (real gzip, ~10-50ms). Without this, a prior
    // test's late decode lands in the *next* test's `events` array once that
    // test has installed its own listener — a cross-test leak that made the
    // "ignores non-collections" and "forwards one event" cases flaky. Clear the
    // listener and drain any in-flight decode (dropped against a null listener)
    // before each test installs a fresh one.
    setCollectionsListener(null);
    await new Promise((r) => setTimeout(r, 60));
  });

  function installAndConnect(): { pc: { dispatch(type: string, ev: unknown): void } } {
    setUpGlobals("meet.google.com");
    installHook();
    const Ctor = (globalThis as unknown as { RTCPeerConnection: new () => { dispatch(type: string, ev: unknown): void } })
      .RTCPeerConnection;
    return { pc: new Ctor() };
  }

  /** Poll until `cond` holds or the bound elapses — for the async gzip decode,
   * whose timing varies with system load, so a fixed sleep is flaky. */
  async function waitFor(cond: () => boolean, timeoutMs = 1000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!cond() && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 5));
    }
  }

  it("parses a collections-labeled channel's message and forwards it to the registered listener", async () => {
    const { pc } = installAndConnect();
    const events: CollectionsMuteEvent[] = [];
    setCollectionsListener((e) => events.push(e));

    const channel = fakeDataChannel("collections");
    pc.dispatch("datachannel", { channel });
    channel.dispatch("message", { data: collectionsMessageBytes("spaces/abc/devices/377", 0) });

    // Real gzip decompression via DecompressionStream schedules across several
    // real event-loop turns (~10ms observed, but slower under full-suite load),
    // so poll for the event with a generous bound instead of a fixed sleep that
    // races the decode.
    await waitFor(() => events.length > 0);

    expect(events).toEqual([{ deviceId: "spaces/abc/devices/377", micOpen: true }]);
  });

  it("ignores datachannels not labeled 'collections'", async () => {
    const { pc } = installAndConnect();
    const events: CollectionsMuteEvent[] = [];
    setCollectionsListener((e) => events.push(e));

    const channel = fakeDataChannel("some-other-channel");
    pc.dispatch("datachannel", { channel });
    channel.dispatch("message", { data: collectionsMessageBytes("spaces/abc/devices/377", 0) });

    await new Promise((r) => setTimeout(r, 0));
    expect(events).toEqual([]);
  });

  it("drops unparseable messages silently — no listener call, no throw", async () => {
    const { pc } = installAndConnect();
    const events: CollectionsMuteEvent[] = [];
    setCollectionsListener((e) => events.push(e));

    const channel = fakeDataChannel("collections");
    pc.dispatch("datachannel", { channel });
    expect(() => channel.dispatch("message", { data: new Uint8Array([1, 2, 3]).buffer })).not.toThrow();

    await new Promise((r) => setTimeout(r, 0));
    await new Promise((r) => setTimeout(r, 0));
    expect(events).toEqual([]);
  });
});

describe("formatChannelSummary (audioprocessor tee)", () => {
  it("buckets sizes and includes the sketch", () => {
    const samples = [
      { t: 0, byteLength: 40 },
      { t: 100, byteLength: 200 },
      { t: 200, byteLength: 200 },
      { t: 300, byteLength: 5000 },
    ];
    expect(formatChannelSummary(samples, "1:varint")).toBe(
      "4 msgs sizes{≤64B:1 ≤256B:2 >1KB:1} fields=1:varint",
    );
  });

  it("marks an unsniffed window", () => {
    expect(formatChannelSummary([], null)).toBe("0 msgs sizes{} fields=unsniffed");
  });
});

// ── Jitsi bridge datachannel ────────────────────────────────────────────────

describe("Jitsi bridge datachannel (rtc-hook.ts)", () => {
  const MAP =
    '{"colibriClass":"AudioSourcesMap","mappedSources":[{"source":"85b964a6-a0","owner":"85b964a6","ssrc":391968325}]}';

  type FakePc = {
    dispatch(type: string, ev: unknown): void;
    createDataChannel(label: string, init?: unknown): FakeDataChannel;
  };

  function connect(opts: { watch: boolean }): { pc: FakePc; created: Array<{ label: string; init: unknown }> } {
    setUpGlobals("meet.jit.si");
    const created: Array<{ label: string; init: unknown }> = [];
    const Native = (globalThis as unknown as { RTCPeerConnection: { prototype: Record<string, unknown> } })
      .RTCPeerConnection;
    Native.prototype.createDataChannel = function (label: string, init?: unknown) {
      created.push({ label, init });
      return fakeDataChannel(label);
    };
    installHook();
    if (opts.watch) watchJvbDataChannels();
    const Ctor = (globalThis as unknown as { RTCPeerConnection: new () => FakePc }).RTCPeerConnection;
    return { pc: new Ctor(), created };
  }

  beforeEach(() => {
    vi.restoreAllMocks();
    vi.spyOn(console, "debug").mockImplementation(() => {});
  });

  it("observes a JVB data channel the bridge opens (datachannel event)", () => {
    const { pc } = connect({ watch: true });
    const channel = fakeDataChannel("JVB data channel");
    pc.dispatch("datachannel", { channel });
    channel.dispatch("message", { data: MAP });
    expect(colibriAudioOwner(391968325)).toBe("85b964a6");
  });

  it("observes a JVB data channel the page creates, and hands back the native channel untouched", () => {
    const { pc, created } = connect({ watch: true });
    const init = { protocol: "http://jitsi.org/protocols/colibri" };
    const channel = pc.createDataChannel("JVB data channel", init);
    expect(created).toEqual([{ label: "JVB data channel", init }]);
    expect(channel.label).toBe("JVB data channel");
    channel.dispatch("message", { data: MAP });
    expect(colibriAudioOwner(391968325)).toBe("85b964a6");
  });

  it("ignores other channels, and every connection when the watch is off", () => {
    const watched = connect({ watch: true });
    watched.pc.createDataChannel("something else").dispatch("message", { data: MAP });
    expect(colibriAudioOwner(391968325)).toBeNull();

    const unwatched = connect({ watch: false });
    const jvb = fakeDataChannel("JVB data channel");
    unwatched.pc.dispatch("datachannel", { channel: jvb });
    jvb.dispatch("message", { data: MAP });
    unwatched.pc.createDataChannel("JVB data channel").dispatch("message", { data: MAP });
    expect(colibriAudioOwner(391968325)).toBeNull();
    expect(Object.prototype.hasOwnProperty.call(unwatched.pc, "createDataChannel")).toBe(false);
  });
});
