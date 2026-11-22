// Shared fixture plumbing for the rtc-hook family's tests (rtc-hook,
// track-provenance, meet-encoded-tee): fake browser globals for installHook()
// plus small track/stream fakes. Not a test file — vitest does not collect it.

export function flush(): Promise<void> {
  return new Promise((r) => setTimeout(r, 0));
}

export interface FakeTrack {
  kind: "audio" | "video";
  id: string;
  muted: boolean;
  addEventListener(type: string, fn: () => void, opts?: { once?: boolean }): void;
  removeEventListener(type: string, fn: () => void): void;
  dispatch(type: string): void;
}

export function fakeTrack(kind: "audio" | "video", id: string): FakeTrack {
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

export function controlledStream<T>() {
  let controller!: ReadableStreamDefaultController<T>;
  const stream = new ReadableStream<T>({
    start(c) {
      controller = c;
    },
  });
  return { stream, enqueue: (v: T) => controller.enqueue(v) };
}

/** Reset the fake browser globals installHook()/epoch.ts read from `window`. */
export function setUpGlobals(host: string, nativeCreateEncodedStreams?: (...a: unknown[]) => unknown) {
  const g = globalThis as unknown as Record<string, unknown>;
  delete g.__earsHookInstalled;
  delete g.__earsEpoch;
  delete g.__earsOnTrack;
  delete g.__earsLiveTracks;
  delete g.__earsEncodedAudioListeners;
  delete g.__earsTrackProvenance;
  delete g.__earsTrackProvenanceSeq;
  delete g.__earsWebAudioTracks;
  delete g.__earsJvbChannelWatch;
  delete g.__earsJitsiLocalEndpoint;
  delete g.__earsJitsiAudioOwners;
  delete g.__earsJitsiBridgeListener;
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

