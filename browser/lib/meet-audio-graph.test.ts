import { describe, expect, it } from "vitest";
import {
  AudioGraphRegistry,
  lineageOrigin,
  GRAPH_MAX_NODES,
  GRAPH_MAX_EDGES_PER_NODE,
} from "./meet-audio-graph";

// Pure-logic half of the Meet audio-graph probe (rtc-hook.ts feeds it from the
// pass-through wraps). The topology map is what a live call's records get read
// through, so it is pinned here rather than eyeballed from a console.

describe("AudioGraphRegistry", () => {
  it("assigns stable ids and records typed nodes", () => {
    const g = new AudioGraphRegistry();
    class GainNode {}
    const a = new GainNode();
    expect(g.ensure(a)).toBe("n1");
    expect(g.ensure(a)).toBe("n1"); // same object, same id
    expect(g.idOf(a)).toBe("n1");
    expect(g.snapshot()[0]).toMatchObject({ id: "n1", type: "GainNode" });
  });

  it("maps connect/disconnect into edges with fan-in, ignoring duplicate edges", () => {
    const g = new AudioGraphRegistry();
    const a = {};
    const b = {};
    g.noteConnect(a, b);
    g.noteConnect(a, b); // reconnect of an existing edge — not a second edge
    expect(g.counts()).toMatchObject({ nodes: 2, edges: 1 });
    const [snapA, snapB] = g.snapshot();
    expect(snapA!.outs).toEqual([snapB!.id]);
    expect(snapB!.fanIn).toBe(1);

    g.noteDisconnect(a, b);
    expect(g.counts().edges).toBe(0);
    expect(g.snapshot()[1]!.fanIn).toBe(0);
  });

  it("a bare disconnect drops every out-edge", () => {
    const g = new AudioGraphRegistry();
    const a = {};
    g.noteConnect(a, {});
    g.noteConnect(a, {});
    expect(g.counts().edges).toBe(2);
    g.noteDisconnect(a);
    expect(g.counts().edges).toBe(0);
  });

  it("caps tracked nodes and counts the overflow instead of growing", () => {
    const g = new AudioGraphRegistry();
    for (let i = 0; i < GRAPH_MAX_NODES + 5; i++) g.ensure({});
    expect(g.counts().nodes).toBe(GRAPH_MAX_NODES);
    expect(g.counts().overflow).toBe(5);
  });

  it("caps per-node fan-out", () => {
    const g = new AudioGraphRegistry();
    const hub = {};
    for (let i = 0; i < GRAPH_MAX_EDGES_PER_NODE + 3; i++) g.noteConnect(hub, {});
    expect(g.counts().edges).toBe(GRAPH_MAX_EDGES_PER_NODE);
  });

  it("counts worklet nodes by processor name", () => {
    const g = new AudioGraphRegistry();
    g.noteWorklet({}, "neteq-processor");
    g.noteWorklet({}, "neteq-processor");
    g.noteWorklet({}, "audio-analyzer-processor");
    expect(g.workletCount("neteq-processor")).toBe(2);
  });

  it("renders flat topology fields with processor and track-id labels — ids only, no names", () => {
    const g = new AudioGraphRegistry();
    const worklet = {};
    const source = {};
    g.noteWorklet(worklet, "neteq-processor");
    g.noteSource(source, ["track-a", "track-b"]);
    g.noteConnect(source, worklet);
    const fields = g.topologyFields();
    expect(fields.n1).toBe("AudioWorkletNode(neteq-processor) in:1");
    expect(fields.n2).toBe("MediaStreamAudioSourceNode(tracks=track-a|track-b) ->n1 in:0");
  });

  it("truncates topology fields past the limit and says by how much", () => {
    const g = new AudioGraphRegistry();
    for (let i = 0; i < 45; i++) g.ensure({});
    const fields = g.topologyFields(40);
    expect(Object.keys(fields)).toHaveLength(41); // 40 nodes + the truncation marker
    expect(fields.topology_truncated).toBe("5");
  });

  describe("output lineage", () => {
    const local = (id: string): "local" | "remote" | undefined =>
      id.startsWith("mic") ? "local" : id.startsWith("rx") ? "remote" : undefined;

    it("traces an output track back to the nodes its audio starts from", () => {
      const g = new AudioGraphRegistry();
      const source = {};
      const gain = {};
      const worklet = {};
      const dest = {};
      g.noteSource(source, ["mic-1"]);
      g.noteWorklet(worklet, "neteq-processor");
      g.noteDestination(dest, ["out-1"]);
      g.noteConnect(source, gain);
      g.noteConnect(gain, dest);
      g.noteConnect(worklet, dest);
      const lineage = g.lineageOf("out-1");
      expect(lineage?.nodeId).toBe(g.idOf(dest));
      expect(lineage?.roots).toEqual(
        expect.arrayContaining([
          { id: g.idOf(source), type: "MediaStreamAudioSourceNode", trackIds: ["mic-1"] },
          { id: g.idOf(worklet), type: "AudioWorkletNode", processor: "neteq-processor" },
        ]),
      );
      expect(lineage?.roots).toHaveLength(2);
    });

    it("returns null for a track no recorded output mints, and no roots for an unwired output", () => {
      const g = new AudioGraphRegistry();
      g.noteDestination({}, ["out-1"]);
      expect(g.lineageOf("other")).toBeNull();
      expect(g.lineageOf("out-1")?.roots).toEqual([]);
    });

    it("terminates on a feedback loop and drops a disconnected road", () => {
      const g = new AudioGraphRegistry();
      const source = {};
      const a = {};
      const b = {};
      const dest = {};
      g.noteSource(source, ["mic-1"]);
      g.noteDestination(dest, ["out-1"]);
      g.noteConnect(source, a);
      g.noteConnect(a, b);
      g.noteConnect(b, a); // delay-line style cycle
      g.noteConnect(b, dest);
      expect(g.lineageOf("out-1")?.roots.map((r) => r.trackIds)).toEqual([["mic-1"]]);
      g.noteDisconnect(b, dest);
      expect(g.lineageOf("out-1")?.roots).toEqual([]);
    });

    it("lineageOrigin: local only when every root is a source of known-local tracks", () => {
      const src = (ids: string[]) => ({ id: "n", type: "MediaStreamAudioSourceNode", trackIds: ids });
      const of = (roots: object[]) => lineageOrigin({ nodeId: "d", roots: roots as never }, local);
      expect(of([src(["mic-1"]), src(["mic-2"])])).toBe("local");
      expect(of([src(["mic-1"]), src(["rx-1"])])).toBeUndefined();
      expect(of([src(["mic-1"]), src(["mystery"])])).toBeUndefined();
      expect(of([src(["mic-1"]), { id: "n", type: "AudioWorkletNode", processor: "neteq-processor" }])).toBeUndefined();
      expect(of([src(["mic-1"]), { id: "n", type: "OscillatorNode" }])).toBeUndefined();
      expect(of([src([])])).toBeUndefined();
      expect(of([])).toBeUndefined();
      expect(lineageOrigin(null, local)).toBeUndefined();
    });
  });
});
