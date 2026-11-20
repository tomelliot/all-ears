import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { hookDebugState, installHook } from "./rtc-hook";
import {
  __resetMeetGraphProbe,
  GRAPH_BRIDGE_MAX_NODES,
  setMeetGraphSinks,
  stopMeetGraphProbe,
} from "./meet-webaudio-probe";
import {
  registerTrackProvenance,
  registerWebAudioTrack,
  trackProvenance,
  trackSnapshot,
  webAudioTracks,
} from "./track-provenance";

// The Meet audio-graph probe's DOM-facing half: the pass-through wraps on
// AudioNode.connect/disconnect and the AudioWorkletNode constructor, plus the
// downstream capture bridge. Two constraints under test throughout:
//
//   1. The native call ALWAYS runs and its result is returned untouched.
//   2. NOTHING is ever connected to an AudioWorkletNode. An extra output edge
//      on Meet's neteq worklet trips a Chromium CHECK on the realtime audio
//      thread and kills the renderer (journal #93) — the bridge taps the
//      NATIVE node downstream instead.

interface Emitted {
  metric: string;
  fields: Record<string, number | string>;
}

interface ConnectCall {
  self: unknown;
  target: unknown;
}

function setUpGlobals(opts?: {
  debugAudio?: boolean;
  bridge?: boolean;
  /** Downstream target `numberOfOutputs`; 0 models a sink-shaped node. */
  targetOutputs?: number;
}): {
  FakeAudioNode: new () => { context: unknown; numberOfOutputs: number; connect: (t: unknown) => unknown };
  FakeGenerator: new (init: { kind: string }) => object;
  ctx: { createMediaStreamDestination: () => object };
  connectCalls: ConnectCall[];
  disconnectCalls: ConnectCall[];
  emitted: Emitted[];
  bridged: Array<{ stream: unknown; participantId: string }>;
} {
  const g = globalThis as unknown as Record<string, unknown>;
  delete g.__earsHookInstalled;
  delete g.__earsEpoch;
  delete g.__earsOnTrack;
  delete g.__earsLiveTracks;
  delete g.__earsEncodedAudioListeners;
  delete g.__earsLivePCs;
  delete g.__earsWebAudioTracks;
  delete g.__earsGraphSinks;
  delete g.__earsGraphLineage;
  delete g.__earsTrackProvenance;
  delete g.__earsTrackProvenanceSeq;
  g.window = globalThis;
  g.location = { host: "meet.google.com" };

  const store = new Map<string, string>();
  if (opts?.debugAudio !== false) store.set("__earsDebugAudio", "1");
  if (opts?.bridge) store.set("__earsGraphBridge", "1");
  g.localStorage = { getItem: (k: string) => store.get(k) ?? null };

  class FakeRTCPeerConnection {
    addEventListener(): void {}
  }
  g.RTCPeerConnection = FakeRTCPeerConnection;
  class FakeRTCRtpReceiver {}
  (FakeRTCRtpReceiver.prototype as Record<string, unknown>).createEncodedStreams = () => ({
    readable: new ReadableStream(),
    writable: new WritableStream(),
  });
  g.RTCRtpReceiver = FakeRTCRtpReceiver;

  class FakeMediaStream {
    constructor(public tracks: unknown[] = []) {}
    getAudioTracks(): unknown[] {
      return this.tracks;
    }
  }
  g.MediaStream = FakeMediaStream;

  const connectCalls: ConnectCall[] = [];
  const disconnectCalls: ConnectCall[] = [];
  const nativeConnect = function (this: unknown, target: unknown): unknown {
    connectCalls.push({ self: this, target });
    return target; // the WebAudio contract: connect(node) returns the target
  };
  const nativeDisconnect = function (this: unknown, target: unknown): void {
    disconnectCalls.push({ self: this, target });
  };

  class FakeDestinationNode {
    stream = new FakeMediaStream();
    numberOfOutputs = 0;
    constructor(public context: unknown) {}
  }
  const ctx = {
    state: "running",
    createMediaStreamDestination(): object {
      return new FakeDestinationNode(ctx);
    },
  };

  class FakeAudioNode {
    context: unknown = ctx;
    numberOfOutputs = opts?.targetOutputs ?? 1;
  }
  (FakeAudioNode.prototype as unknown as Record<string, unknown>).connect = nativeConnect;
  (FakeAudioNode.prototype as unknown as Record<string, unknown>).disconnect = nativeDisconnect;
  g.AudioNode = FakeAudioNode;

  // AudioWorkletNode extends AudioNode in the DOM — so it inherits the wrapped
  // connect/disconnect, exactly like Meet's own nodes do.
  class FakeAudioWorkletNode extends FakeAudioNode {
    override numberOfOutputs = 1;
    constructor(
      public override context: unknown,
      public processor: string,
    ) {
      super();
    }
  }
  g.AudioWorkletNode = FakeAudioWorkletNode;

  class FakeGenerator {
    id = `gen-${Math.random().toString(36).slice(2, 8)}`;
    kind: string;
    constructor(init: { kind: string }) {
      this.kind = init.kind;
    }
  }
  g.MediaStreamTrackGenerator = FakeGenerator;

  const emitted: Emitted[] = [];
  const bridged: Array<{ stream: unknown; participantId: string }> = [];

  installHook();
  setMeetGraphSinks({
    emitPerf: (metric, fields) => emitted.push({ metric, fields }),
    bridgeStream: (stream, participantId) => bridged.push({ stream, participantId }),
  });

  return {
    FakeAudioNode: g.AudioNode as never,
    FakeGenerator: g.MediaStreamTrackGenerator as never,
    ctx,
    connectCalls,
    disconnectCalls,
    emitted,
    bridged,
  };
}

/** Construct through the (wrapped) global, the way Meet does. */
function newWorklet(
  h: ReturnType<typeof setUpGlobals>,
  processor = "neteq-processor",
): { connect: (t: unknown) => unknown; disconnect: (t?: unknown) => unknown } {
  const Ctor = (globalThis as unknown as Record<string, unknown>)
    .AudioWorkletNode as new (ctx: unknown, p: string) => never;
  return new Ctor(h.ctx, processor);
}

describe("Meet audio-graph probe (meet-webaudio-probe.ts)", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    __resetMeetGraphProbe();
    setMeetGraphSinks(null);
    vi.useRealTimers();
  });

  it("connect is pass-through — native runs, its result comes back — and the graph maps the edge", () => {
    const h = setUpGlobals();
    const a = new h.FakeAudioNode();
    const b = new h.FakeAudioNode();
    const result = a.connect(b);
    expect(result).toBe(b);
    expect(h.connectCalls).toEqual([{ self: a, target: b }]);
    expect(hookDebugState().graph).toMatchObject({ nodes: 2, edges: 1 });
  });

  it("maps the graph with __earsDebugAudio off — provenance needs it on every call", () => {
    const h = setUpGlobals({ debugAudio: false });
    const a = new h.FakeAudioNode();
    const b = new h.FakeAudioNode();
    a.connect(b);
    expect(h.connectCalls).toHaveLength(1);
    expect(hookDebugState().graph).toMatchObject({ nodes: 2, edges: 1 });
    vi.advanceTimersByTime(60_000);
    expect(h.emitted).toEqual([]); // the emitter stays a debug surface
  });

  describe("graph outputs and provenance", () => {
    const track = (id: string): MediaStreamTrack =>
      ({ id, kind: "audio", readyState: "live", getSettings: () => ({}) }) as unknown as MediaStreamTrack;
    const stream = (...tracks: MediaStreamTrack[]): unknown => {
      const Ctor = (globalThis as unknown as Record<string, unknown>).MediaStream as new (t: unknown[]) => unknown;
      return new Ctor(tracks);
    };
    /** A node carrying `mediaStream` (a source) or `stream` (a destination). */
    const node = (h: ReturnType<typeof setUpGlobals>, extra: Record<string, unknown> = {}) =>
      Object.assign(new h.FakeAudioNode(), extra);

    it("names an output fed only by the microphone local, through intermediate nodes", () => {
      const h = setUpGlobals({ debugAudio: false });
      registerTrackProvenance("mic", "local", "gum");
      const source = node(h, { mediaStream: stream(track("mic")) });
      const gain = node(h);
      const noiseFilter = newWorklet(h, "noise-filter");
      const dest = node(h, { stream: stream(track("out")) });
      source.connect(gain);
      gain.connect(noiseFilter);
      noiseFilter.connect(dest);

      registerWebAudioTrack(track("out"), "createMediaStreamSource");
      expect(trackProvenance("out")).toBeUndefined(); // nothing but the graph knows
      webAudioTracks();
      expect(trackProvenance("out")).toMatchObject({ origin: "local", via: "graph" });
    });

    it("leaves an output fed by the NetEQ worklet unclassified — it adopts", () => {
      const h = setUpGlobals({ debugAudio: false });
      const dest = node(h, { stream: stream(track("remote-out")) });
      newWorklet(h).connect(dest);
      registerWebAudioTrack(track("remote-out"), "createMediaStreamSource");
      webAudioTracks();
      expect(trackProvenance("remote-out")).toBeUndefined();
    });

    it("leaves an output that mixes the microphone with a remote road unclassified", () => {
      const h = setUpGlobals({ debugAudio: false });
      registerTrackProvenance("mic", "local", "gum");
      const dest = node(h, { stream: stream(track("mixed")) });
      node(h, { mediaStream: stream(track("mic")) }).connect(dest);
      newWorklet(h).connect(dest);
      registerWebAudioTrack(track("mixed"), "createMediaStreamSource");
      webAudioTracks();
      expect(trackProvenance("mixed")).toBeUndefined();
    });

    it("follows a chain of outputs fed back in as sources", () => {
      const h = setUpGlobals({ debugAudio: false });
      registerTrackProvenance("mic", "local", "gum");
      const first = node(h, { stream: stream(track("stage-1")) });
      node(h, { mediaStream: stream(track("mic")) }).connect(first);
      const second = node(h, { stream: stream(track("stage-2")) });
      node(h, { mediaStream: stream(track("stage-1")) }).connect(second);
      // Registered downstream-first: the chain must not depend on order.
      registerWebAudioTrack(track("stage-2"), "createMediaStreamSource");
      registerWebAudioTrack(track("stage-1"), "createMediaStreamSource");
      webAudioTracks();
      expect(trackProvenance("stage-1")).toMatchObject({ origin: "local", via: "graph" });
      expect(trackProvenance("stage-2")).toMatchObject({ origin: "local", via: "graph" });
    });

    it("names an already-registered output local once the page wires it up", () => {
      const h = setUpGlobals({ debugAudio: false });
      registerTrackProvenance("mic", "local", "gum");
      const dest = node(h, { stream: stream(track("late")) });
      registerWebAudioTrack(track("late"), "createMediaStreamSource");
      webAudioTracks();
      expect(trackProvenance("late")).toBeUndefined();
      node(h, { mediaStream: stream(track("mic")) }).connect(dest);
      webAudioTracks();
      expect(trackProvenance("late")).toMatchObject({ origin: "local", via: "graph" });
    });

    it("reports each output's roots and the mapped graph in the track snapshot", () => {
      const h = setUpGlobals({ debugAudio: false });
      const dest = node(h, { stream: stream(track("remote-out")) });
      newWorklet(h).connect(dest);
      registerWebAudioTrack(track("remote-out"), "createMediaStreamSource");
      const snapshot = trackSnapshot();
      expect(snapshot.tracks[0]).toMatchObject({
        trackId: "remote-out",
        graphRoots: ["AudioWorkletNode(neteq-processor)"],
      });
      expect(snapshot.graph).toContainEqual(
        expect.objectContaining({ type: "MediaStreamAudioDestinationNode", outputTrackIds: ["remote-out"] }),
      );
      expect(JSON.parse(JSON.stringify(snapshot))).toEqual(snapshot);
    });
  });

  it("registers worklet nodes and counts neteq-processor instances", () => {
    const h = setUpGlobals();
    newWorklet(h, "neteq-processor");
    newWorklet(h, "neteq-processor");
    newWorklet(h, "audio-analyzer-processor");
    const state = hookDebugState();
    expect(state.webaudio.netEqWorkletNodes).toBe(2);
    expect(state.webaudio.audioWorkletNodes).toBe(3);
    expect(state.graph.nodes).toBe(3);
  });

  it("NEVER connects anything to a worklet — the renderer-fatal edge (journal #93)", () => {
    const h = setUpGlobals({ bridge: true });
    const worklet = newWorklet(h);
    const gain = new h.FakeAudioNode();
    worklet.connect(gain); // Meet's own wiring
    vi.advanceTimersByTime(60_000);
    // The only connect call with the worklet as source is Meet's own edge to
    // the gain. Every probe-added edge hangs off the native gain.
    const workletEdges = h.connectCalls.filter((c) => c.self === worklet);
    expect(workletEdges).toEqual([{ self: worklet, target: gain }]);
  });

  it("bridges the native node DOWNSTREAM of a neteq worklet when __earsGraphBridge is set", () => {
    const h = setUpGlobals({ bridge: true });
    const worklet = newWorklet(h);
    const gain = new h.FakeAudioNode();
    worklet.connect(gain);
    // The tap: gain → MediaStreamAudioDestinationNode, via the native connect.
    const tapEdges = h.connectCalls.filter((c) => c.self === gain);
    expect(tapEdges).toHaveLength(1);
    expect(h.bridged).toHaveLength(1);
    expect(h.bridged[0]!.participantId).toBe("graphtap-1");
    expect(hookDebugState().graph.bridgedNodes).toBe(1);
    expect(h.emitted.some((e) => e.metric === "meet_graph_bridge")).toBe(true);
  });

  it("taps a shared downstream target once, and distinct targets separately", () => {
    const h = setUpGlobals({ bridge: true });
    const mixer = new h.FakeAudioNode();
    newWorklet(h).connect(mixer);
    newWorklet(h).connect(mixer); // second neteq into the same mixer: no re-tap
    expect(h.bridged.map((b) => b.participantId)).toEqual(["graphtap-1"]);
    const own = new h.FakeAudioNode();
    newWorklet(h).connect(own); // its own downstream node: a second stream
    expect(h.bridged.map((b) => b.participantId)).toEqual(["graphtap-1", "graphtap-2"]);
  });

  it("does not bridge by default (flag off), even with the debug probe active", () => {
    const h = setUpGlobals();
    newWorklet(h).connect(new h.FakeAudioNode());
    expect(h.bridged).toHaveLength(0);
    expect(hookDebugState().graph.bridgedNodes).toBe(0);
  });

  it("bridges without __earsDebugAudio — capture does not require the debug probe", () => {
    const h = setUpGlobals({ debugAudio: false, bridge: true });
    newWorklet(h).connect(new h.FakeAudioNode());
    expect(h.bridged.map((b) => b.participantId)).toEqual(["graphtap-1"]);
  });

  it("records a sink-shaped downstream target as untappable instead of branching off it", () => {
    const h = setUpGlobals({ bridge: true, targetOutputs: 0 });
    const sink = new h.FakeAudioNode();
    newWorklet(h).connect(sink);
    expect(h.bridged).toHaveLength(0);
    expect(h.connectCalls.filter((c) => c.self === sink)).toHaveLength(0);
    const record = h.emitted.find((e) => e.metric === "meet_graph_bridge");
    expect(record?.fields.kind).toBe("untappable-sink");
  });

  it("caps bridged streams at GRAPH_BRIDGE_MAX_NODES", () => {
    const h = setUpGlobals({ bridge: true });
    for (let i = 0; i < GRAPH_BRIDGE_MAX_NODES + 3; i++) {
      newWorklet(h).connect(new h.FakeAudioNode());
    }
    expect(h.bridged).toHaveLength(GRAPH_BRIDGE_MAX_NODES);
  });

  it("bridges an audio MediaStreamTrackGenerator directly — no graph mutation at all", () => {
    const h = setUpGlobals({ bridge: true });
    new h.FakeGenerator({ kind: "audio" });
    new h.FakeGenerator({ kind: "video" });
    expect(h.bridged.map((b) => b.participantId)).toEqual(["graphgen-1"]);
    expect(h.connectCalls).toHaveLength(0);
  });

  it("stopMeetGraphProbe severs every bridge branch via the native disconnect", () => {
    const h = setUpGlobals({ bridge: true });
    const gain = new h.FakeAudioNode();
    newWorklet(h).connect(gain);
    const dest = h.connectCalls.find((c) => c.self === gain)!.target;
    stopMeetGraphProbe();
    expect(h.disconnectCalls).toEqual([{ self: gain, target: dest }]);
    // Idempotent: a second stop has nothing left to sever.
    stopMeetGraphProbe();
    expect(h.disconnectCalls).toHaveLength(1);
  });

  it("emits a periodic summary and topology through the perf sink while the debug probe is on", () => {
    const h = setUpGlobals();
    newWorklet(h).connect(new h.FakeAudioNode());
    vi.advanceTimersByTime(30_000);
    const summaries = h.emitted.filter((e) => e.metric === "meet_graph_summary");
    expect(summaries.length).toBeGreaterThanOrEqual(2);
    expect(summaries[0]!.fields).toMatchObject({ neteq_nodes: 1 });
    const topology = h.emitted.find((e) => e.metric === "meet_graph_topology");
    expect(topology).toBeDefined();
    const rendered = Object.values(topology!.fields).join(" ");
    expect(rendered).toContain("neteq-processor");
  });

  it("emits no perf records when __earsDebugAudio is off and the bridge is idle", () => {
    const h = setUpGlobals({ debugAudio: false });
    newWorklet(h).connect(new h.FakeAudioNode());
    new h.FakeGenerator({ kind: "audio" });
    vi.advanceTimersByTime(60_000);
    expect(h.emitted).toHaveLength(0);
  });
});
