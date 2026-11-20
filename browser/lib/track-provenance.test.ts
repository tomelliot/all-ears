import { beforeEach, describe, expect, it, vi } from "vitest";
import { installHook } from "./rtc-hook";
import {
  PROVENANCE_MAX_ENTRIES,
  registerTrackProvenance,
  registerWebAudioTrack,
  trackProvenance,
  trackSnapshot,
  webAudioTracks,
} from "./track-provenance";
import { setUpGlobals } from "./rtc-test-helpers";

// ── Track provenance (registry + passive wraps) ─────────────────────────────

describe("track provenance", () => {
  let cloneCounter: number;

  class FakeMediaStreamTrack {
    readonly readyState = "live";
    constructor(
      public id: string,
      public kind: "audio" | "video" = "audio",
      /** What `getSettings()` reports — a capture device carries a deviceId,
       * a decoded remote track carries neither key. */
      public settings: { deviceId?: string; groupId?: string } = {},
    ) {}
    addEventListener(): void {}
    getSettings(): { deviceId?: string; groupId?: string } {
      return this.settings;
    }
    clone(): FakeMediaStreamTrack {
      return new FakeMediaStreamTrack(`${this.id}-c${++cloneCounter}`, this.kind, this.settings);
    }
  }

  function fakeStream(...tracks: FakeMediaStreamTrack[]): { getAudioTracks(): FakeMediaStreamTrack[] } {
    return { getAudioTracks: () => tracks.filter((t) => t.kind === "audio") };
  }

  /** Meet host (the wraps are Meet-only) plus the capture-surface fakes the
   * provenance wraps hang off: mediaDevices, MediaStreamTrack, RTCRtpSender,
   * and sender methods on the fake RTCPeerConnection prototype. */
  function setUpProvenance(gumTracks: FakeMediaStreamTrack[]) {
    const native = () => ({ readable: new ReadableStream(), writable: new WritableStream() });
    setUpGlobals("meet.google.com", native);
    cloneCounter = 0;
    const g = globalThis as unknown as Record<string, unknown>;

    g.MediaStreamTrack = FakeMediaStreamTrack;

    const getUserMedia = vi.fn(async () => fakeStream(...gumTracks));
    // Node ≥21 defines a global navigator getter; defineProperty replaces it.
    Object.defineProperty(g, "navigator", {
      value: { mediaDevices: { getUserMedia } },
      configurable: true,
      writable: true,
    });

    class FakeRTCRtpSender {
      replaceTrack(_track: unknown): Promise<void> {
        return Promise.resolve();
      }
    }
    g.RTCRtpSender = FakeRTCRtpSender;

    const proto = (g.RTCPeerConnection as { prototype: Record<string, unknown> }).prototype;
    proto.addTrack = function (_track: unknown): string {
      return "native-sender";
    };
    proto.addTransceiver = function (_trackOrKind: unknown): string {
      return "native-transceiver";
    };

    // The WebAudio surface the seam's registry hangs off: Meet routes both
    // remote participant audio AND its own outgoing mic through here.
    const nativeCreateMediaStreamSource = vi.fn(() => ({ node: true }));
    class FakeAudioContext {}
    (FakeAudioContext.prototype as unknown as Record<string, unknown>).createMediaStreamSource =
      nativeCreateMediaStreamSource;
    g.AudioContext = FakeAudioContext;

    installHook();
    return { getUserMedia, FakeAudioContext, nativeCreateMediaStreamSource };
  }

  /** Route a stream into WebAudio exactly as Meet does. */
  function intoWebAudio(
    FakeAudioContext: new () => object,
    ...tracks: FakeMediaStreamTrack[]
  ): unknown {
    const ctx = new FakeAudioContext() as { createMediaStreamSource(s: unknown): unknown };
    return ctx.createMediaStreamSource(fakeStream(...tracks));
  }

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("marks getUserMedia audio tracks local and returns the stream untouched", async () => {
    const mic = new FakeMediaStreamTrack("mic-1");
    setUpProvenance([mic]);

    const nav = (globalThis as unknown as { navigator: { mediaDevices: { getUserMedia(): Promise<unknown> } } })
      .navigator;
    const stream = await nav.mediaDevices.getUserMedia();
    expect((stream as { getAudioTracks(): unknown[] }).getAudioTracks()).toEqual([mic]);

    expect(trackProvenance("mic-1")).toMatchObject({ origin: "local", via: "gum", rootId: "mic-1" });
  });

  it("clones inherit origin and lineage root, transitively", async () => {
    const mic = new FakeMediaStreamTrack("mic-1");
    setUpProvenance([mic]);
    const nav = (globalThis as unknown as { navigator: { mediaDevices: { getUserMedia(): Promise<unknown> } } })
      .navigator;
    await nav.mediaDevices.getUserMedia();

    const c1 = mic.clone();
    const c2 = c1.clone();
    expect(trackProvenance(c1.id)).toMatchObject({ origin: "local", via: "clone", rootId: "mic-1" });
    expect(trackProvenance(c2.id)).toMatchObject({ origin: "local", via: "clone", rootId: "mic-1" });
  });

  it("a clone of an unregistered parent stays unknown", () => {
    setUpProvenance([]);
    const stranger = new FakeMediaStreamTrack("stranger");
    const c = stranger.clone();
    expect(trackProvenance(c.id)).toBeUndefined();
  });

  // ── Classification on sight (the webaudio seam's own choke point) ─────────
  //
  // The gUM and sender wraps only fire when the page makes those calls while
  // the hook is installed. On the 2026-08-06 call the hook attached mid-join,
  // so Meet's own mic track reached createMediaStreamSource unclassified,
  // adopted as `unknown`, and the user was transcribed twice.

  it("classifies a mic track local on sight, from its device settings alone", () => {
    // No getUserMedia call is replayed here: this is the late-installing-hook
    // case, where there is no lineage left to back-fill from.
    const { FakeAudioContext } = setUpProvenance([]);
    const mic = new FakeMediaStreamTrack("mic-late", "audio", { deviceId: "default", groupId: "g" });

    intoWebAudio(FakeAudioContext, mic);

    expect(trackProvenance("mic-late")).toMatchObject({
      origin: "local",
      via: "device-settings",
      rootId: "mic-late",
    });
  });

  it("leaves a decoded remote track unclassified rather than calling it local", () => {
    // The real shape, read off a live Meet call: a decoded remote track DOES
    // report a deviceId (Meet's echo its own track id). Calling that local
    // would drop a participant's audio, so only groupId may decide.
    const { FakeAudioContext } = setUpProvenance([]);
    const remote = new FakeMediaStreamTrack("participant-1", "audio", { deviceId: "participant-1-dfb" });

    intoWebAudio(FakeAudioContext, remote);

    expect(trackProvenance("participant-1")).toBeUndefined();
  });

  it("never overrides an earlier verdict — first write still wins", () => {
    const { FakeAudioContext } = setUpProvenance([]);
    // A track that reports a capture device but which ontrack already called
    // remote: provenance must not flip under it.
    registerTrackProvenance("already-remote", "remote", "ontrack");
    const odd = new FakeMediaStreamTrack("already-remote", "audio", { groupId: "g1" });

    intoWebAudio(FakeAudioContext, odd);

    expect(trackProvenance("already-remote")).toMatchObject({ origin: "remote", via: "ontrack" });
  });

  it("registers the track and returns the node untouched either way", () => {
    // Classification is a bookkeeping side-effect: it must never change what
    // the seam can see, nor what Meet gets back from its own call.
    const { FakeAudioContext, nativeCreateMediaStreamSource } = setUpProvenance([]);
    const mic = new FakeMediaStreamTrack("mic-1", "audio", { deviceId: "default", groupId: "g1" });
    const remote = new FakeMediaStreamTrack("remote-1", "audio", { deviceId: "remote-1-uuid" });

    const node = intoWebAudio(FakeAudioContext, mic, remote);

    expect(node).toEqual({ node: true });
    expect(nativeCreateMediaStreamSource).toHaveBeenCalledTimes(1);
    // Both tracks are still offered to the seam — the adopt policy decides,
    // not the registry (capture-seams.ts owns that call).
    expect(webAudioTracks().map((t) => t.id)).toEqual(["mic-1", "remote-1"]);
  });

  it("survives a track that won't report settings", () => {
    const { FakeAudioContext } = setUpProvenance([]);
    const hostile = new FakeMediaStreamTrack("hostile");
    hostile.getSettings = () => {
      throw new Error("nope");
    };

    expect(() => intoWebAudio(FakeAudioContext, hostile)).not.toThrow();
    expect(trackProvenance("hostile")).toBeUndefined();
    expect(webAudioTracks().map((t) => t.id)).toEqual(["hostile"]);
  });

  it("marks addTrack/addTransceiver audio arguments local, passing results through", () => {
    setUpProvenance([]);
    const g = globalThis as unknown as {
      RTCPeerConnection: new () => { addTrack(t: unknown): unknown; addTransceiver(t: unknown): unknown };
    };
    const pc = new g.RTCPeerConnection();

    expect(pc.addTrack(new FakeMediaStreamTrack("out-1"))).toBe("native-sender");
    expect(trackProvenance("out-1")).toMatchObject({ origin: "local", via: "sender" });

    expect(pc.addTransceiver(new FakeMediaStreamTrack("out-2"))).toBe("native-transceiver");
    expect(trackProvenance("out-2")).toMatchObject({ origin: "local", via: "sender" });

    // A kind string and a video track both fall outside the audio-track guard.
    pc.addTransceiver("audio");
    pc.addTrack(new FakeMediaStreamTrack("cam-1", "video"));
    expect(trackProvenance("cam-1")).toBeUndefined();
  });

  it("marks replaceTrack replacements local and skips null", async () => {
    setUpProvenance([]);
    const g = globalThis as unknown as {
      RTCRtpSender: new () => { replaceTrack(t: unknown): Promise<void> };
    };
    const sender = new g.RTCRtpSender();
    await sender.replaceTrack(new FakeMediaStreamTrack("swap-1"));
    await sender.replaceTrack(null);
    expect(trackProvenance("swap-1")).toMatchObject({ origin: "local", via: "replaceTrack" });
  });

  it("marks ontrack deliveries remote, and first write wins over a later sender call", () => {
    setUpProvenance([]);
    const g = globalThis as unknown as {
      RTCPeerConnection: new () => {
        dispatch(type: string, ev: unknown): void;
        addTrack(t: unknown): unknown;
      };
    };
    const pc = new g.RTCPeerConnection();
    const incoming = new FakeMediaStreamTrack("in-1");
    pc.dispatch("track", { track: incoming, streams: [{}], transceiver: {} });
    expect(trackProvenance("in-1")).toMatchObject({ origin: "remote", via: "ontrack" });

    // Looping the remote track back into a sender must not relabel its content.
    pc.addTrack(incoming);
    expect(trackProvenance("in-1")).toMatchObject({ origin: "remote", via: "ontrack" });

    // Its clone carries the remote lineage too.
    expect(trackProvenance(incoming.clone().id)).toMatchObject({ origin: "remote", rootId: "in-1" });
  });

  it("caps the registry, evicting oldest-first", () => {
    setUpProvenance([]);
    for (let i = 0; i < PROVENANCE_MAX_ENTRIES + 1; i++) {
      registerTrackProvenance(`t-${i}`, "local", "gum");
    }
    expect(trackProvenance("t-0")).toBeUndefined();
    expect(trackProvenance(`t-${PROVENANCE_MAX_ENTRIES}`)).toMatchObject({ origin: "local" });
  });

  it("snapshots every WebAudio track with its settings, verdict and capture handle", () => {
    setUpProvenance([]);
    const mic = new FakeMediaStreamTrack("snap-mic", "audio", { deviceId: "default", groupId: "g1" });
    const mystery = new FakeMediaStreamTrack("snap-mystery", "audio", { deviceId: "snap-mystery" });
    registerWebAudioTrack(mic as unknown as MediaStreamTrack, "createMediaStreamSource");
    registerWebAudioTrack(mystery as unknown as MediaStreamTrack, "createMediaStreamSource");
    // A sender-side track that never reached WebAudio still shows in provenance.
    registerTrackProvenance("snap-sent", "local", "sender");

    const snapshot = trackSnapshot(new Map([["snap-mystery", "t5"]]));
    const byId = new Map(snapshot.tracks.map((t) => [t.trackId, t]));
    expect(byId.get("snap-mic")).toMatchObject({
      via: "createMediaStreamSource",
      origin: "local",
      provenanceVia: "device-settings",
      settings: { groupId: "g1" },
    });
    expect(byId.get("snap-mystery")).toMatchObject({ captureId: "t5", readyState: "live" });
    expect(byId.get("snap-mystery")?.origin).toBeUndefined();
    expect(snapshot.provenance).toContainEqual(
      expect.objectContaining({ trackId: "snap-sent", origin: "local", via: "sender" }),
    );
    // Plain data: survives the JSONL encoding the attribution log applies.
    expect(JSON.parse(JSON.stringify(snapshot))).toEqual(snapshot);
  });
});
