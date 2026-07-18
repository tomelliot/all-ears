import { beforeEach, describe, expect, it, vi } from "vitest";
import { installHook, setEncodedAudioListener, type EncodedAudioFrameLike } from "./rtc-hook";

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
    addEventListener(): void {}
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
