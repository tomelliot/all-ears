import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CaptureOrchestrator, initCapture, type CaptureDeps } from "./audio-tap";
import { claimEpoch } from "./epoch";
import type { PlatformAdapter } from "./identity/adapter";
import { liveTracks, type TrackRecord, type TrackSink } from "./rtc-hook";
import type { TrackProvenanceRecord } from "./track-provenance";
import { SEAM_ESCALATION_GRACE_MS, SeamArbiter, seamOrderFor } from "./capture-seams";
import type { FrameSourceFactory } from "./frame-pipeline";
import type { Platform } from "./protocol";

// ── Track-scoped source handles (R3) ────────────────────────────────────────
//
// A source id is a stable per-track handle (`t<n>`), minted once at admission
// and never changed for the track's life. Identity never rides the source id:
// a platform id — known at admission or confirmed mid-call — flows as a
// `participant-identified` attendee upsert linking the handle's source, and
// the pipeline is never restarted for it.

interface PostedEnvelope {
  __ears?: boolean;
  msg?: { kind: string } & Record<string, unknown>;
}

class FakeMediaTrack {
  muted = false;
  readyState: "live" | "ended" = "live";
  private readonly listeners = new Map<string, Set<() => void>>();
  constructor(readonly id: string) {}
  addEventListener(kind: string, fn: () => void): void {
    if (!this.listeners.has(kind)) this.listeners.set(kind, new Set());
    this.listeners.get(kind)!.add(fn);
  }
  removeEventListener(kind: string, fn: () => void): void {
    this.listeners.get(kind)?.delete(fn);
  }
  dispatch(kind: string): void {
    for (const fn of [...(this.listeners.get(kind) ?? [])]) fn();
  }
}

/** WebCodecs breakout-box fake: exposes each track's stream controller so a
 * test can push decoded frames through the real capture pipeline. */
class FakeTrackProcessor {
  static controllers = new Map<string, ReadableStreamDefaultController<unknown>>();
  readable: ReadableStream<unknown>;
  constructor(init: { track: { id: string } }) {
    this.readable = new ReadableStream({
      start(controller) {
        FakeTrackProcessor.controllers.set(init.track.id, controller);
      },
    });
  }
}

/** One decoded frame: 3200 samples of 16 kHz audio at peak 0.1 — enough for
 * the accumulator to emit at least one full 100 ms pcm frame per push. */
function decodedFrame(): unknown {
  return {
    sampleRate: 16000,
    numberOfFrames: 3200,
    numberOfChannels: 1,
    format: "f32",
    copyTo(dest: Float32Array) {
      dest.fill(0.1);
    },
    close() {},
  };
}

describe("track-scoped source handles (R3)", () => {
  let posted: Array<{ kind: string } & Record<string, unknown>>;

  function stubWindow(): void {
    posted = [];
    (globalThis as { window?: unknown }).window = {
      postMessage: (envelope: PostedEnvelope) => {
        if (envelope?.msg) posted.push(envelope.msg);
      },
    };
    (globalThis as { MediaStreamTrackProcessor?: unknown }).MediaStreamTrackProcessor =
      FakeTrackProcessor;
    FakeTrackProcessor.controllers.clear();
  }

  function registerLive(track: FakeMediaTrack): void {
    liveTracks().set(track as unknown as MediaStreamTrack, {
      stream: { id: `stream-${track.id}` } as unknown as MediaStream,
    });
  }

  const ofKind = (kind: string) => posted.filter((m) => m.kind === kind);

  async function pushFrame(trackId: string): Promise<void> {
    FakeTrackProcessor.controllers.get(trackId)!.enqueue(decodedFrame());
    // The processor loop consumes asynchronously; yield until it has.
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  beforeEach(stubWindow);

  afterEach(() => {
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    liveTracks().clear();
    delete (globalThis as { MediaStreamTrackProcessor?: unknown }).MediaStreamTrackProcessor;
    delete (globalThis as { window?: unknown }).window;
  });

  it("mints a short opaque handle per admitted track; a platform id becomes an identity upsert, never the source id", () => {
    const trackA = new FakeMediaTrack("zoom-track-a");
    const trackB = new FakeMediaTrack("zoom-track-b");
    registerLive(trackA);
    registerLive(trackB);
    const adapter = {
      platform: "zoom",
      // The platform knows track A's owner at admission; track B resolves to
      // nothing — its handle carries the audio just the same.
      identify: (track: MediaStreamTrack) => (track.id === "zoom-track-a" ? "zoom-1024" : null),
    } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter });

    const joined = ofKind("participant-joined");
    expect(joined).toHaveLength(2);
    const ids = joined.map((m) => (m.participant as { kind: string; id: string }).id);
    // Handles are track-scoped and identity-free for every track — platform-
    // identified or not — and distinct per track.
    for (const id of ids) expect(id).toMatch(/^t\d+$/);
    expect(new Set(ids).size).toBe(2);
    for (const m of joined) expect((m.participant as { kind: string }).kind).toBe("synthetic");

    // The known identity arrived as an attendee upsert linking the source.
    const identified = ofKind("participant-identified");
    expect(identified).toHaveLength(1);
    expect(identified[0]).toMatchObject({ participantId: "zoom-1024", platform: "zoom" });
    const capturedUnder = identified[0]!.captureId as string;
    expect(ids).toContain(capturedUnder);
  });

  it("keeps the handle, the pipeline, and the frame stream across a mid-call identity upgrade", async () => {
    const track = new FakeMediaTrack("meet-track");
    registerLive(track);
    let identityCb: ((trackId: string, id: string) => void) | undefined;
    const adapter = {
      platform: "meet",
      identify: () => null,
      displayName: (id: string) => (id === "spaces/s/devices/9" ? "Jane Doe" : undefined),
      onIdentity: (cb: (trackId: string, id: string) => void) => {
        identityCb = cb;
      },
    } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "meet", adapter });

    const joined = ofKind("participant-joined");
    expect(joined).toHaveLength(1);
    const handle = (joined[0]!.participant as { id: string }).id;
    expect(handle).toMatch(/^t\d+$/);

    await pushFrame("meet-track");
    const before = ofKind("pcm");
    expect(before.length).toBeGreaterThan(0);
    expect(before.at(-1)).toMatchObject({ participantId: handle, seq: before.length });

    // The engine confirms the track's owner mid-call.
    identityCb!("meet-track", "spaces/s/devices/9");

    // No restart: nothing left, nothing re-joined, the handle unchanged —
    // the identity is a metadata upsert.
    expect(ofKind("participant-left")).toHaveLength(0);
    expect(ofKind("participant-joined")).toHaveLength(1);
    expect(ofKind("participant-identified")).toEqual([
      {
        kind: "participant-identified",
        platform: "meet",
        participantId: "spaces/s/devices/9",
        captureId: handle,
        displayName: "Jane Doe",
      },
    ]);

    // Frames continue across the upgrade on the same pipeline: same handle,
    // seq unbroken (a restart would reset the counter and lose frames).
    await pushFrame("meet-track");
    const after = ofKind("pcm");
    expect(after.length).toBeGreaterThan(before.length);
    expect(after.at(-1)).toMatchObject({ participantId: handle, seq: after.length });
  });

  it("a late identity for an already-dead track still resolves to the source that recorded it", () => {
    const track = new FakeMediaTrack("meet-track-2");
    registerLive(track);
    let identityCb: ((trackId: string, id: string) => void) | undefined;
    const adapter = {
      platform: "meet",
      identify: () => null,
      onIdentity: (cb: (trackId: string, id: string) => void) => {
        identityCb = cb;
      },
    } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "meet", adapter });
    const handle = (ofKind("participant-joined")[0]!.participant as { id: string }).id;

    // The track ends before the correlation confirms (the Etel case)…
    track.readyState = "ended";
    liveTracks().clear();
    // …and the identity still lands as the same upsert, keyed by track id.
    identityCb!("meet-track-2", "spaces/s/devices/14");

    expect(ofKind("participant-identified")).toEqual([
      {
        kind: "participant-identified",
        platform: "meet",
        participantId: "spaces/s/devices/14",
        captureId: handle,
      },
    ]);
  });

  it("re-adoption across an epoch handoff keeps the track's handle (a new generation, not a new source)", () => {
    const track = new FakeMediaTrack("stable-track");
    registerLive(track);
    const adapter = { platform: "zoom", identify: () => null } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter });
    const first = ofKind("participant-joined");
    expect(first).toHaveLength(1);
    const handle = (first[0]!.participant as { id: string }).id;
    expect(first[0]).toMatchObject({ generation: 1 });

    // A re-inject supersedes the epoch and replays the live registry.
    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter });
    const joined = ofKind("participant-joined");
    expect(joined).toHaveLength(2);
    expect(joined[1]).toMatchObject({ generation: 2 });
    expect((joined[1]!.participant as { id: string }).id).toBe(handle);
  });
});

describe("initCapture epoch teardown", () => {
  beforeEach(() => {
    // initCapture touches only postMessage on window (status messages); the
    // epoch counter and track registry live as window globals and start clean
    // on a fresh stub.
    (globalThis as { window?: unknown }).window = { postMessage: () => {} };
  });

  afterEach(() => {
    delete (globalThis as { window?: unknown }).window;
  });

  it("disposes each epoch's adapter when the epoch is superseded or stopped (B10)", () => {
    const disposed: string[] = [];
    const makeAdapter = (name: string): PlatformAdapter =>
      ({
        platform: "meet",
        identify: () => null,
        dispose: () => disposed.push(name),
      }) as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "meet", adapter: makeAdapter("first") });
    expect(disposed).toEqual([]); // the live epoch's adapter stays alive

    // A new epoch (re-inject / toggle cycle) supersedes: the old epoch's
    // teardown chain must dispose the old adapter, never the new one.
    initCapture({ epoch: claimEpoch(), platform: "meet", adapter: makeAdapter("second") });
    expect(disposed).toEqual(["first"]);

    // Toggling capture off tears down the final epoch via __earsTeardown.
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    expect(disposed).toEqual(["first", "second"]);
  });

  it("survives an adapter without dispose, and a dispose that throws", () => {
    const noDispose = { platform: "zoom", identify: () => null } as unknown as PlatformAdapter;
    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter: noDispose });

    const throwing = {
      platform: "meet",
      identify: () => null,
      dispose: () => {
        throw new Error("identity teardown must never break capture teardown");
      },
    } as unknown as PlatformAdapter;
    initCapture({ epoch: claimEpoch(), platform: "meet", adapter: throwing });

    expect(() =>
      (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.(),
    ).not.toThrow();
  });
});

// ── CaptureOrchestrator with fakes (R7) ─────────────────────────────────────
//
// The admission/orchestration layer, constructed directly with fake deps —
// the scenarios below were previously only exercised by real calls (plan
// finding F1). Fakes everywhere: poster, flight recorder, clock, epoch check,
// hook registries, frame sources. The arbiter is the REAL SeamArbiter (pure,
// clock-injected) so escalation runs the production state machine.

/** A track whose clone/stop the seam-adoption path drives. */
class FakeSeamTrack extends FakeMediaTrack {
  stopped = false;
  lastClone?: FakeSeamTrack;
  clone(): FakeSeamTrack {
    this.lastClone = new FakeSeamTrack(`${this.id}-clone`);
    return this.lastClone;
  }
  stop(): void {
    this.stopped = true;
  }
  dispatchTo(kind: "unmute" | "ended" | "mute"): void {
    this.dispatch(kind);
  }
}

interface FakeSourceRecord {
  onFrame: (frame: unknown) => void;
  onFatal: (reason: string) => void;
  started: boolean;
  stopped: boolean;
}

function makeHarness(opts?: {
  platform?: Platform;
  seams?: string[];
  adapter?: Partial<PlatformAdapter> | null;
}) {
  const platform = opts?.platform ?? "meet";
  const posted: Array<{ kind: string } & Record<string, unknown>> = [];
  const recorded: Array<{ type: string } & Record<string, unknown>> = [];
  const live = new Map<MediaStreamTrack, TrackRecord>();
  const webTracks: FakeSeamTrack[] = [];
  const provenance = new Map<string, TrackProvenanceRecord>();
  const frameSources = new Map<string, FakeSourceRecord>();
  const flush = vi.fn();
  let sink: TrackSink | undefined;
  const clock = { now: 0 };
  const epoch = { current: 1 };

  const fakeSourceFactory = (track: MediaStreamTrack): FrameSourceFactory => {
    return (onFrame, onFatal) => {
      const rec: FakeSourceRecord = {
        onFrame: onFrame as (frame: unknown) => void,
        onFatal,
        started: false,
        stopped: false,
      };
      frameSources.set(track.id, rec);
      return {
        start: () => {
          rec.started = true;
        },
        stop: () => {
          rec.stopped = true;
        },
      };
    };
  };

  const deps: CaptureDeps = {
    post: (msg) => posted.push(msg as { kind: string } & Record<string, unknown>),
    record: (event) => recorded.push(event as { type: string } & Record<string, unknown>),
    flush,
    now: () => clock.now,
    isCurrentEpoch: (e) => e === epoch.current,
    setTrackSink: (s) => {
      sink = s;
    },
    liveTracks: () => live,
    webAudioTracks: () => webTracks as unknown as MediaStreamTrack[],
    trackProvenance: (id) => provenance.get(id),
    makeArbiter: () => new SeamArbiter(opts?.seams ?? seamOrderFor(platform)),
    meetDecodeSource: fakeSourceFactory,
    trackProcessorSource: fakeSourceFactory,
  };
  const orchestrator = new CaptureOrchestrator(deps);
  const adapter =
    opts?.adapter === null
      ? null
      : ({ platform, identify: () => null, ...opts?.adapter } as unknown as PlatformAdapter);

  return {
    orchestrator,
    posted,
    recorded,
    live,
    webTracks,
    provenance,
    frameSources,
    flush,
    clock,
    epoch,
    adapter,
    platform,
    sink: (track: FakeSeamTrack, streamId = `stream-${track.id}`) =>
      sink!(track as unknown as MediaStreamTrack, { id: streamId } as unknown as MediaStream),
    init: () => orchestrator.initCapture({ epoch: epoch.current, platform, adapter }),
    ofKind: (kind: string) => posted.filter((m) => m.kind === kind),
    ofType: (type: string) => recorded.filter((e) => e.type === type),
    registerLive: (track: FakeSeamTrack) =>
      live.set(track as unknown as MediaStreamTrack, {
        stream: { id: `stream-${track.id}` } as unknown as MediaStream,
      }),
    /** Push one decoded frame through the real TrackCapture consume path. */
    pushFrame: (trackId: string) => frameSources.get(trackId)!.onFrame(decodedFrame()),
  };
}

describe("CaptureOrchestrator admission (fakes)", () => {
  beforeEach(() => {
    (globalThis as { window?: unknown }).window = {};
  });

  afterEach(() => {
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    delete (globalThis as { window?: unknown }).window;
  });

  it("starts a pipeline for an unmuted receiver track and admits it exactly once", () => {
    const h = makeHarness();
    const track = new FakeSeamTrack("r1");
    h.registerLive(track);
    h.init();

    expect(h.ofKind("participant-joined")).toHaveLength(1);
    expect(h.frameSources.get("r1")?.started).toBe(true);
    expect(h.ofType("admitted")).toHaveLength(1);

    // The hook re-dispatching the same track (or the reconcile sweep) is a skip.
    h.sink(track);
    h.orchestrator.reconcile();
    expect(h.ofKind("participant-joined")).toHaveLength(1);
    // Appearance is news once, however often the sweep re-offers the track.
    expect(h.ofType("track-appeared")).toHaveLength(1);
  });

  it("defers a receiver track muted at dispatch: no attendee until its first unmute", () => {
    const h = makeHarness();
    const track = new FakeSeamTrack("muted-1");
    track.muted = true;
    h.registerLive(track);
    h.init();

    // Deferred, with the reason recorded — nothing joined, no pipeline built.
    expect(h.ofKind("participant-joined")).toHaveLength(0);
    expect(h.ofType("deferred")).toMatchObject([{ trackId: "muted-1" }]);
    expect(h.frameSources.has("muted-1")).toBe(false);

    // First unmute re-runs admission and starts the pipeline.
    track.muted = false;
    track.dispatchTo("unmute");
    expect(h.ofKind("participant-joined")).toHaveLength(1);
    expect(h.frameSources.get("muted-1")?.started).toBe(true);
    expect(h.ofType("track-unmuted").length).toBeGreaterThanOrEqual(1);
  });

  it("a muted track that ends without unmuting never becomes an attendee (journal #165)", () => {
    const h = makeHarness();
    const track = new FakeSeamTrack("phantom");
    track.muted = true;
    h.registerLive(track);
    h.init();

    track.dispatchTo("ended");
    expect(h.ofKind("participant-joined")).toHaveLength(0);
    expect(h.ofType("track-ended")).toMatchObject([{ trackId: "phantom" }]);

    // A later (impossible in the DOM, defensive here) unmute changes nothing:
    // the deferral cleaned itself up.
    track.muted = false;
    track.dispatchTo("unmute");
    expect(h.ofKind("participant-joined")).toHaveLength(0);
  });

  it("an ended track is never re-admitted after its pipeline dies (journal #176)", () => {
    const h = makeHarness();
    const track = new FakeSeamTrack("r1");
    h.registerLive(track);
    h.init();
    expect(h.ofType("admitted")).toHaveLength(1);

    // Meeting end: the track ends and the processor construct fails fatally,
    // tearing the pipeline down. The live registry still holds the track.
    track.readyState = "ended";
    h.frameSources.get("r1")!.onFatal("failed to construct processor: Input track cannot be ended");

    // The reconcile sweep re-offers everything in the live registry.
    h.orchestrator.reconcile();
    h.sink(track);
    expect(h.ofType("admitted")).toHaveLength(1); // one admission ever — no crash-readmit loop
  });

  it("a deferred track whose epoch was superseded before unmute never starts", () => {
    const h = makeHarness();
    const track = new FakeSeamTrack("stale");
    track.muted = true;
    h.registerLive(track);
    h.init();

    h.epoch.current = 2; // a newer epoch owns capture now
    track.muted = false;
    track.dispatchTo("unmute");
    expect(h.ofKind("participant-joined")).toHaveLength(0);
  });
});

describe("CaptureOrchestrator escalation and adoption (fakes)", () => {
  beforeEach(() => {
    (globalThis as { window?: unknown }).window = {};
  });

  afterEach(() => {
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    delete (globalThis as { window?: unknown }).window;
  });

  it("escalates off a frameless seam after the unmute grace and adopts the webaudio tracks", () => {
    const h = makeHarness();
    const receiver = new FakeSeamTrack("r1");
    h.registerLive(receiver);
    const web = new FakeSeamTrack("wa1");
    h.webTracks.push(web);
    h.init();
    expect(h.ofKind("participant-joined")).toHaveLength(1);
    const receiverHandle = (h.ofKind("participant-joined")[0]!.participant as { id: string }).id;

    // The platform claims audio is flowing…
    receiver.dispatchTo("unmute");
    // …but no frame decodes within the grace window.
    h.clock.now = SEAM_ESCALATION_GRACE_MS;
    h.orchestrator.reconcile();

    expect(h.ofType("escalated")).toMatchObject([{ from: "receiver-track", to: "webaudio-track" }]);
    // The receiver pipeline went down with the ordinary participant-left shape…
    expect(h.ofKind("participant-left")).toMatchObject([{ participantId: receiverHandle }]);
    // …and the webaudio track came up as a fresh source on a CLONE.
    const joined = h.ofKind("participant-joined");
    expect(joined).toHaveLength(2);
    expect(h.ofType("adopted")).toMatchObject([{ trackId: "wa1" }]);
    expect(h.frameSources.get("wa1-clone")?.started).toBe(true);
    expect(h.orchestrator.debugState().seam?.active).toBe("webaudio-track");
  });

  it("a track admitted on its deferral unmute still escalates after a frameless grace (journal #176)", () => {
    const h = makeHarness();
    const receiver = new FakeSeamTrack("r1");
    receiver.muted = true;
    h.registerLive(receiver);
    const web = new FakeSeamTrack("wa1");
    h.webTracks.push(web);
    h.init();
    expect(h.ofType("deferred")).toHaveLength(1);

    // The unmute that admits the track is the LAST unmute event it ever fires:
    // the pipeline starts with the track already unmuted, so arming must not
    // depend on a later event.
    receiver.muted = false;
    receiver.dispatchTo("unmute");
    expect(h.frameSources.get("r1")?.started).toBe(true);

    h.clock.now = SEAM_ESCALATION_GRACE_MS;
    h.orchestrator.reconcile();

    expect(h.ofType("escalated")).toMatchObject([{ from: "receiver-track", to: "webaudio-track" }]);
    expect(h.ofType("adopted")).toMatchObject([{ trackId: "wa1" }]);
  });

  it("a receiver track already unmuted at dispatch escalates without ever firing an unmute event (journal #176)", () => {
    const h = makeHarness();
    const receiver = new FakeSeamTrack("r1");
    h.registerLive(receiver);
    const web = new FakeSeamTrack("wa1");
    h.webTracks.push(web);
    h.init();
    expect(h.frameSources.get("r1")?.started).toBe(true);

    h.clock.now = SEAM_ESCALATION_GRACE_MS;
    h.orchestrator.reconcile();
    expect(h.ofType("escalated")).toMatchObject([{ from: "receiver-track", to: "webaudio-track" }]);
  });

  it("a decoded frame proves the seam: the same grace elapsing later never escalates", () => {
    const h = makeHarness();
    const receiver = new FakeSeamTrack("r1");
    h.registerLive(receiver);
    h.init();

    receiver.dispatchTo("unmute");
    h.pushFrame("r1"); // capture confirmed live on this seam

    h.clock.now = SEAM_ESCALATION_GRACE_MS * 3;
    h.orchestrator.reconcile();
    expect(h.ofType("escalated")).toHaveLength(0);
    expect(h.orchestrator.debugState().seam).toMatchObject({ active: "receiver-track", proven: true });
    expect(h.ofKind("pcm").length).toBeGreaterThan(0); // frames flowed end to end
  });

  it("webaudio adoption skips local-provenance tracks and takes one track per lineage root", () => {
    const h = makeHarness({ seams: ["webaudio-track"] });
    const mic = new FakeSeamTrack("mic");
    const remoteA = new FakeSeamTrack("root-a");
    const remoteAClone = new FakeSeamTrack("root-a-dup");
    h.provenance.set("mic", { origin: "local", via: "gum", rootId: "mic", seq: 1 });
    h.provenance.set("root-a", { origin: "remote", via: "ontrack", rootId: "root-a", seq: 2 });
    h.provenance.set("root-a-dup", { origin: "remote", via: "clone", rootId: "root-a", seq: 3 });
    h.webTracks.push(mic, remoteA, remoteAClone);
    h.init();

    h.orchestrator.reconcile();

    expect(h.ofType("adopted")).toMatchObject([{ trackId: "root-a" }]);
    expect(h.ofKind("participant-joined")).toHaveLength(1);
    expect(mic.lastClone).toBeUndefined(); // the local mic was never even cloned
  });

  it("adopt/retire race: a track classified local AFTER adoption is retired on the next sweep and never re-adopted", () => {
    const h = makeHarness({ seams: ["webaudio-track"] });
    const track = new FakeSeamTrack("late-local");
    h.webTracks.push(track);
    h.init();

    // Unknown provenance adopts (fail-safe: a dropped remote track is data loss).
    h.orchestrator.reconcile();
    expect(h.ofType("adopted")).toMatchObject([{ trackId: "late-local" }]);
    const handle = (h.ofKind("participant-joined")[0]!.participant as { id: string }).id;

    // The page hands the track to a sender: provenance improves to `local`.
    h.provenance.set("late-local", { origin: "local", via: "sender", rootId: "late-local", seq: 1 });
    h.orchestrator.reconcile();

    expect(h.ofType("retired")).toMatchObject([{ trackId: "late-local" }]);
    expect(h.ofKind("participant-left")).toMatchObject([{ participantId: handle }]);
    expect(track.lastClone?.stopped).toBe(true); // our clone released the source

    // Later sweeps neither re-adopt nor re-retire it.
    h.orchestrator.reconcile();
    expect(h.ofType("adopted")).toHaveLength(1);
    expect(h.ofType("retired")).toHaveLength(1);
  });
});

describe("CaptureOrchestrator reconcile sweep and handles (fakes)", () => {
  beforeEach(() => {
    (globalThis as { window?: unknown }).window = {};
  });

  afterEach(() => {
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    delete (globalThis as { window?: unknown }).window;
  });

  it("adopts a live track that appeared after init, polls identities, and flushes the flight recorder", () => {
    const polls = vi.fn();
    const h = makeHarness({ adapter: { pollIdentities: polls } });
    h.init();
    expect(h.ofKind("participant-joined")).toHaveLength(0);

    const late = new FakeSeamTrack("late-1");
    h.registerLive(late); // dispatchTrack landed between sweeps
    h.orchestrator.reconcile();

    expect(h.ofKind("participant-joined")).toHaveLength(1);
    expect(polls).toHaveBeenCalledTimes(1);
    expect(h.flush).toHaveBeenCalled();
  });

  it("does nothing once a newer epoch owns capture", () => {
    const h = makeHarness();
    const track = new FakeSeamTrack("r1");
    h.init();
    h.epoch.current = 2;
    h.registerLive(track);
    h.orchestrator.reconcile();
    expect(h.ofKind("participant-joined")).toHaveLength(0);
  });

  it("mints one stable opaque handle per track: distinct across tracks, kept across re-admission", () => {
    const h = makeHarness();
    const a = new FakeSeamTrack("track-a");
    const b = new FakeSeamTrack("track-b");
    h.registerLive(a);
    h.registerLive(b);
    h.init();

    const joined = h.ofKind("participant-joined");
    const ids = joined.map((m) => (m.participant as { id: string }).id);
    expect(ids).toHaveLength(2);
    for (const id of ids) expect(id).toMatch(/^t\d+$/);
    expect(new Set(ids).size).toBe(2);
    const handleA = (joined.find((m) => (m.generation as number) >= 1)!.participant as { id: string }).id;

    // Track A's pipeline dies (track ended) but the track is re-offered — the
    // decoder-restart / registry-replay shape. Same handle, next generation.
    a.dispatchTo("ended");
    expect(h.ofKind("participant-left")).toHaveLength(1);
    h.orchestrator.reconcile();
    const rejoined = h.ofKind("participant-joined");
    expect(rejoined).toHaveLength(3);
    expect((rejoined[2]!.participant as { id: string }).id).toBe(handleA);
    expect(rejoined[2]!.generation).toBe(2);
  });

  it("routes a mid-call identity to the handle whose audio is on disk, without touching the pipeline", () => {
    let identityCb: ((trackId: string, id: string) => void) | undefined;
    const h = makeHarness({
      adapter: {
        onIdentity: (cb) => {
          identityCb = cb;
        },
        displayName: (id: string) => (id === "spaces/x/devices/3" ? "Ada" : undefined),
      },
    });
    const track = new FakeSeamTrack("r1");
    h.registerLive(track);
    h.init();
    const handle = (h.ofKind("participant-joined")[0]!.participant as { id: string }).id;

    identityCb!("r1", "spaces/x/devices/3");

    expect(h.ofKind("participant-identified")).toMatchObject([
      { participantId: "spaces/x/devices/3", captureId: handle, displayName: "Ada" },
    ]);
    expect(h.ofType("identity-link")).toMatchObject([{ trackId: "r1", captureId: handle }]);
    expect(h.ofKind("participant-left")).toHaveLength(0); // no restart, ever
    expect(h.frameSources.get("r1")?.stopped).toBe(false);
  });

  it("a reassigned track (reused Jitsi slot) ends its source and continues the same pipeline under a fresh handle", () => {
    let reassign: ((trackId: string) => void) | undefined;
    let owner = "aaaa0001";
    const h = makeHarness({
      platform: "jitsi",
      adapter: {
        identify: () => owner,
        onTrackReassigned: (cb) => {
          reassign = cb;
        },
        displayName: (id: string) => ({ aaaa0001: "Ada", bbbb0002: "Bea" })[id],
      },
    });
    const track = new FakeSeamTrack("remote-audio-1");
    h.registerLive(track);
    h.init();
    const first = (h.ofKind("participant-joined")[0]!.participant as { id: string }).id;
    h.pushFrame("remote-audio-1");
    expect(h.ofKind("pcm").at(-1)).toMatchObject({ participantId: first });

    owner = "bbbb0002";
    reassign!("remote-audio-1");

    const joined = h.ofKind("participant-joined");
    expect(joined).toHaveLength(2);
    const second = (joined[1]!.participant as { id: string }).id;
    expect(second).not.toBe(first);
    expect(joined[1]!.generation).toBe(1);
    expect(h.ofKind("participant-left")).toMatchObject([{ participantId: first, generation: 1 }]);
    expect(h.ofKind("participant-identified")).toMatchObject([
      { participantId: "aaaa0001", captureId: first, displayName: "Ada" },
      { participantId: "bbbb0002", captureId: second, displayName: "Bea" },
    ]);
    // Same pipeline, same frame source: a track allows one processor ever.
    expect(h.frameSources.get("remote-audio-1")?.stopped).toBe(false);
    const before = h.ofKind("pcm").length;
    h.pushFrame("remote-audio-1");
    const after = h.ofKind("pcm").slice(before);
    expect(after.length).toBeGreaterThan(0);
    expect(after.every((m) => m.participantId === second)).toBe(true);
    expect(after[0]).toMatchObject({ seq: 1 }); // a new source counts from the start

    // The sweep keeps the new handle; an unknown track id is ignored.
    h.orchestrator.reconcile();
    reassign!("no-such-track");
    expect(h.ofKind("participant-joined")).toHaveLength(2);
  });
});
