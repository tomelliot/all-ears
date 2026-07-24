import { gzipSync } from "node:zlib";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { installHook, setCollectionsListener, setEncodedAudioListener, type EncodedAudioFrameLike } from "./rtc-hook";
import type { CollectionsMuteEvent } from "./identity/meet-collections";

// Node has global ReadableStream/WritableStream (18+); no DOM needed. We fake
// just enough of the browser surface (window === globalThis, location,
// RTCPeerConnection, RTCRtpReceiver) for installHook()'s Meet-only tee to run
// against real stream objects.

function flush(): Promise<void> {
  return new Promise((r) => setTimeout(r, 0));
}

interface FakeTrack {
  kind: "audio" | "video";
  id: string;
  muted: boolean;
  addEventListener(type: string, fn: () => void, opts?: { once?: boolean }): void;
  removeEventListener(type: string, fn: () => void): void;
  dispatch(type: string): void;
}

function fakeTrack(kind: "audio" | "video", id: string): FakeTrack {
  const listeners = new Map<string, Set<() => void>>();
  return {
    kind,
    id,
    muted: false,
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type)!.add(fn);
    },
    removeEventListener(type, fn) {
      listeners.get(type)?.delete(fn);
    },
    dispatch(type) {
      for (const fn of [...(listeners.get(type) ?? [])]) fn();
    },
  };
}

function controlledStream<T>() {
  let controller!: ReadableStreamDefaultController<T>;
  const stream = new ReadableStream<T>({
    start(c) {
      controller = c;
    },
  });
  return { stream, enqueue: (v: T) => controller.enqueue(v) };
}

/** Reset the fake browser globals installHook()/epoch.ts read from `window`. */
function setUpGlobals(host: string, nativeCreateEncodedStreams?: (...a: unknown[]) => unknown) {
  const g = globalThis as unknown as Record<string, unknown>;
  delete g.__earsHookInstalled;
  delete g.__earsEpoch;
  delete g.__earsOnTrack;
  delete g.__earsLiveTracks;
  delete g.__earsEncodedAudioListeners;
  g.window = globalThis;
  g.location = { host };

  class FakeRTCPeerConnection {
    private listeners = new Map<string, Set<(ev: unknown) => void>>();
    addEventListener(type: string, fn: (ev: unknown) => void): void {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type)!.add(fn);
    }
    dispatch(type: string, ev: unknown): void {
      for (const fn of [...(this.listeners.get(type) ?? [])]) fn(ev);
    }
  }
  g.RTCPeerConnection = FakeRTCPeerConnection;

  class FakeRTCRtpReceiver {}
  if (nativeCreateEncodedStreams) {
    (FakeRTCRtpReceiver.prototype as unknown as Record<string, unknown>).createEncodedStreams =
      nativeCreateEncodedStreams;
  }
  g.RTCRtpReceiver = FakeRTCRtpReceiver;

  return { FakeRTCRtpReceiver };
}

describe("Meet encoded-audio tee (rtc-hook.ts)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("does not wrap createEncodedStreams on non-Meet hosts", () => {
    const native = vi.fn(() => ({ readable: new ReadableStream(), writable: new WritableStream() }));
    const { FakeRTCRtpReceiver } = setUpGlobals("zoom.us", native);

    installHook();

    expect((FakeRTCRtpReceiver.prototype as unknown as Record<string, unknown>).createEncodedStreams).toBe(native);
  });

  it("passes video receivers through untouched on Meet", () => {
    const nativeReadable = new ReadableStream();
    const nativeWritable = new WritableStream();
    const native = vi.fn(() => ({ readable: nativeReadable, writable: nativeWritable }));
    const { FakeRTCRtpReceiver } = setUpGlobals("meet.google.com", native);

    installHook();

    const receiver = Object.create(FakeRTCRtpReceiver.prototype) as { track: FakeTrack; createEncodedStreams(): unknown };
    receiver.track = fakeTrack("video", "v1");
    const result = receiver.createEncodedStreams() as { readable: unknown; writable: unknown };

    expect(result.readable).toBe(nativeReadable);
    expect(result.writable).toBe(nativeWritable);
  });

  it("tees the audio branch: Meet's own branch keeps flowing and our listener also receives every frame", async () => {
    const { stream: nativeReadable, enqueue } = controlledStream<EncodedAudioFrameLike>();
    const native = vi.fn(() => ({ readable: nativeReadable, writable: new WritableStream() }));
    const { FakeRTCRtpReceiver } = setUpGlobals("meet.google.com", native);

    installHook();

    const receiver = Object.create(FakeRTCRtpReceiver.prototype) as {
      track: FakeTrack;
      createEncodedStreams(): { readable: ReadableStream<EncodedAudioFrameLike>; writable: WritableStream };
    };
    const track = fakeTrack("audio", "a1");
    receiver.track = track;
    const theirs = receiver.createEncodedStreams();
    expect(theirs.readable).not.toBe(nativeReadable); // it's the tee'd branch, not the original

    const received: EncodedAudioFrameLike[] = [];
    setEncodedAudioListener(track as unknown as MediaStreamTrack, (f) => received.push(f));

    const frame: EncodedAudioFrameLike = { data: new ArrayBuffer(4), timestamp: 100 };
    enqueue(frame);
    await flush();

    expect(received).toEqual([frame]);

    // Meet's own branch is untouched — it independently sees the same frame.
    const theirReader = theirs.readable.getReader();
    const { value, done } = await theirReader.read();
    expect(done).toBe(false);
    expect(value).toEqual(frame);
  });

  it("track event and createEncodedStreams() are not ordered — a listener registered before the tee still receives frames", async () => {
    const { stream: nativeReadable, enqueue } = controlledStream<EncodedAudioFrameLike>();
    const native = vi.fn(() => ({ readable: nativeReadable, writable: new WritableStream() }));
    const { FakeRTCRtpReceiver } = setUpGlobals("meet.google.com", native);

    installHook();

    const track = fakeTrack("audio", "a2");
    const received: EncodedAudioFrameLike[] = [];
    // audio-tap.ts's track sink can fire before Meet ever calls createEncodedStreams().
    setEncodedAudioListener(track as unknown as MediaStreamTrack, (f) => received.push(f));

    const receiver = Object.create(FakeRTCRtpReceiver.prototype) as { track: FakeTrack; createEncodedStreams(): unknown };
    receiver.track = track;
    receiver.createEncodedStreams();

    const frame: EncodedAudioFrameLike = { data: new ArrayBuffer(4), timestamp: 200 };
    enqueue(frame);
    await flush();

    expect(received).toEqual([frame]);
  });

  it("frames published with no listener registered are dropped, not buffered", async () => {
    const { stream: nativeReadable, enqueue } = controlledStream<EncodedAudioFrameLike>();
    const native = vi.fn(() => ({ readable: nativeReadable, writable: new WritableStream() }));
    const { FakeRTCRtpReceiver } = setUpGlobals("meet.google.com", native);

    installHook();

    const track = fakeTrack("audio", "a3");
    const receiver = Object.create(FakeRTCRtpReceiver.prototype) as { track: FakeTrack; createEncodedStreams(): unknown };
    receiver.track = track;
    receiver.createEncodedStreams();

    enqueue({ data: new ArrayBuffer(4), timestamp: 1 });
    await flush();

    const received: EncodedAudioFrameLike[] = [];
    setEncodedAudioListener(track as unknown as MediaStreamTrack, (f) => received.push(f));

    const frame2: EncodedAudioFrameLike = { data: new ArrayBuffer(4), timestamp: 2 };
    enqueue(frame2);
    await flush();

    // Only the frame that arrived *after* registration was delivered.
    expect(received).toEqual([frame2]);
  });

  it("epoch handoff: unsubscribing then resubscribing hands off cleanly without re-teeing", async () => {
    const { stream: nativeReadable, enqueue } = controlledStream<EncodedAudioFrameLike>();
    const native = vi.fn(() => ({ readable: nativeReadable, writable: new WritableStream() }));
    const { FakeRTCRtpReceiver } = setUpGlobals("meet.google.com", native);

    installHook();

    const track = fakeTrack("audio", "a4");
    const receiver = Object.create(FakeRTCRtpReceiver.prototype) as { track: FakeTrack; createEncodedStreams(): unknown };
    receiver.track = track;
    receiver.createEncodedStreams();
    expect(native).toHaveBeenCalledTimes(1);

    const epoch1: EncodedAudioFrameLike[] = [];
    setEncodedAudioListener(track as unknown as MediaStreamTrack, (f) => epoch1.push(f));
    enqueue({ data: new ArrayBuffer(4), timestamp: 1 });
    await flush();
    expect(epoch1).toHaveLength(1);

    // Old epoch tears down (audio-tap.ts's TrackCapture.stop() path).
    setEncodedAudioListener(track as unknown as MediaStreamTrack, null);

    const epoch2: EncodedAudioFrameLike[] = [];
    setEncodedAudioListener(track as unknown as MediaStreamTrack, (f) => epoch2.push(f));
    enqueue({ data: new ArrayBuffer(4), timestamp: 2 });
    await flush();

    expect(epoch2).toHaveLength(1);
    expect(epoch1).toHaveLength(1); // epoch1 never received epoch2's frame
    expect(native).toHaveBeenCalledTimes(1); // createEncodedStreams() called exactly once, ever
  });
});

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
