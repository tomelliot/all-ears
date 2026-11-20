// Meet WebAudio graph mapping (journal #75, #93).
//
// Meet decodes participant Opus inside WASM (NetEQ over SharedArrayBuffer) and
// plays out through `AudioWorkletNode(processor="neteq-processor")`, so encoded
// frames never enter JS and the createEncodedStreams tee reads nothing. The one
// question that decides whether per-participant capture is recoverable at all:
// does the WebAudio graph downstream of that WASM carry audio PER PARTICIPANT
// (N tappable nodes), or is it ALREADY MIXED before anything tappable (one node
// carrying everyone)?
//
// This module is the pure half of the map: a bounded registry of the page's
// audio graph, fed by rtc-hook.ts's pass-through connect/worklet wraps.
// Everything DOM-touching (the wraps, the bridge, the emission timer) stays in
// rtc-hook.ts so this logic is unit-testable in node. The registry only ever
// OBSERVES — the verdict itself comes from recordings made by the downstream
// capture bridge (rtc-hook.ts tapNetEqDownstream), which is ground truth.

/** Hard cap on tracked graph nodes: a tile-heavy call must not build unbounded
 * bookkeeping. Nodes past the cap are counted (`overflow`) but not stored. */
export const GRAPH_MAX_NODES = 128;

/** Per-node out-edge cap — fan-out past this is counted, not stored. */
export const GRAPH_MAX_EDGES_PER_NODE = 32;

interface GraphNodeInfo {
  id: string;
  type: string;
  /** AudioWorkletNode processor name, when known. */
  processor?: string;
  /** MediaStreamAudioSourceNode input track ids, when known. */
  trackIds?: string[];
  /** MediaStreamAudioDestinationNode output track ids, when known. */
  outputTrackIds?: string[];
  outs: Set<string>;
  fanIn: number;
  createdAt: number;
}

/** One graph node, serializable for debug reports and perf records. */
export interface GraphNodeSnapshot {
  id: string;
  type: string;
  processor?: string;
  trackIds?: string[];
  outputTrackIds?: string[];
  outs: string[];
  fanIn: number;
}

/** A node that feeds a graph output and has no recorded input of its own —
 * where that output's audio comes from. */
export interface GraphRoot {
  id: string;
  type: string;
  processor?: string;
  trackIds?: string[];
}

/** Where one graph-output track's audio comes from. */
export interface GraphLineage {
  /** The MediaStreamAudioDestinationNode that owns the track. */
  nodeId: string;
  roots: GraphRoot[];
}

/**
 * Whether a graph output carries only the user's own audio.
 *
 * `local` needs positive evidence on every road in: each root must be a
 * stream source whose every track is already known local. A worklet root
 * (Meet's NetEQ playout), a source with an unknown or remote track, any other
 * generator, or no recorded root at all leaves the output unclassified — and
 * unclassified adopts (capture-seams.ts), so a gap in the map can only cost a
 * duplicate, never a participant.
 */
export function lineageOrigin(
  lineage: GraphLineage | null,
  originOf: (trackId: string) => "local" | "remote" | undefined,
): "local" | undefined {
  if (!lineage || lineage.roots.length === 0) return undefined;
  for (const root of lineage.roots) {
    if (root.type !== "MediaStreamAudioSourceNode") return undefined;
    if (!root.trackIds || root.trackIds.length === 0) return undefined;
    if (!root.trackIds.every((id) => originOf(id) === "local")) return undefined;
  }
  return "local";
}

/**
 * Bounded, id-assigning registry of the live audio graph. Keys are the real
 * node objects (WeakMap — the registry never keeps a node alive); values are
 * small structural records. All methods are total: unknown objects register on
 * first sight, and over-cap nodes degrade to a counter rather than growing.
 */
export class AudioGraphRegistry {
  private readonly ids = new WeakMap<object, string>();
  private readonly info = new Map<string, GraphNodeInfo>();
  private seq = 0;
  private overflowCount = 0;
  private edgeCount = 0;

  private register(node: object, type?: string): string | null {
    const existing = this.ids.get(node);
    if (existing) return existing;
    if (this.info.size >= GRAPH_MAX_NODES) {
      this.overflowCount += 1;
      return null;
    }
    this.seq += 1;
    const id = `n${this.seq}`;
    this.ids.set(node, id);
    this.info.set(id, {
      id,
      type: type ?? constructorName(node),
      outs: new Set(),
      fanIn: 0,
      createdAt: Date.now(),
    });
    return id;
  }

  /** Register (or look up) a node; returns its id, or null once over cap. */
  ensure(node: object, type?: string): string | null {
    return this.register(node, type);
  }

  idOf(node: object): string | null {
    return this.ids.get(node) ?? null;
  }

  /** Register an AudioWorkletNode with its processor name. */
  noteWorklet(node: object, processor: string): string | null {
    const id = this.register(node, "AudioWorkletNode");
    if (id) this.info.get(id)!.processor = processor;
    return id;
  }

  /** Register a MediaStreamAudioSourceNode with the track ids feeding it. */
  noteSource(node: object, trackIds: string[]): string | null {
    const id = this.register(node, "MediaStreamAudioSourceNode");
    if (id) this.info.get(id)!.trackIds = trackIds;
    return id;
  }

  /** True once a source node's input tracks are recorded. */
  hasSourceTracks(node: object): boolean {
    const id = this.ids.get(node);
    return id !== undefined && this.info.get(id)?.trackIds !== undefined;
  }

  /** Register a MediaStreamAudioDestinationNode with the track ids it mints. */
  noteDestination(node: object, trackIds: string[]): string | null {
    const id = this.register(node, "MediaStreamAudioDestinationNode");
    if (id) this.info.get(id)!.outputTrackIds = trackIds;
    return id;
  }

  /**
   * The roots feeding the destination node that mints `trackId`, or null when
   * no recorded destination owns that track. Walks the recorded edges
   * backwards; a cycle is visited once.
   */
  lineageOf(trackId: string): GraphLineage | null {
    let destId: string | null = null;
    for (const node of this.info.values()) {
      if (node.outputTrackIds?.includes(trackId)) {
        destId = node.id;
        break;
      }
    }
    if (!destId) return null;
    const inputs = new Map<string, string[]>();
    for (const node of this.info.values()) {
      for (const out of node.outs) {
        const list = inputs.get(out);
        if (list) list.push(node.id);
        else inputs.set(out, [node.id]);
      }
    }
    const roots: GraphRoot[] = [];
    const seen = new Set<string>([destId]);
    const queue = [...(inputs.get(destId) ?? [])];
    while (queue.length > 0) {
      const id = queue.pop()!;
      if (seen.has(id)) continue;
      seen.add(id);
      const node = this.info.get(id);
      if (!node) continue;
      const feeders = inputs.get(id) ?? [];
      if (feeders.length === 0) {
        roots.push({
          id: node.id,
          type: node.type,
          ...(node.processor !== undefined ? { processor: node.processor } : {}),
          ...(node.trackIds !== undefined ? { trackIds: node.trackIds } : {}),
        });
      } else {
        queue.push(...feeders);
      }
    }
    return { nodeId: destId, roots };
  }

  /** Record `from.connect(to)`. Either end registers on first sight. `to` may
   * be an AudioParam or anything else — it still gets a typed node entry, so
   * fan-out to params is visible in the topology. */
  noteConnect(from: object, to: unknown): void {
    const fromId = this.register(from);
    if (!fromId) return;
    if (typeof to !== "object" || to === null) return;
    const toId = this.register(to);
    if (!toId) return;
    const fromInfo = this.info.get(fromId)!;
    if (fromInfo.outs.has(toId)) return; // reconnect of an existing edge
    if (fromInfo.outs.size >= GRAPH_MAX_EDGES_PER_NODE) return;
    fromInfo.outs.add(toId);
    this.edgeCount += 1;
    this.info.get(toId)!.fanIn += 1;
  }

  /** Record `from.disconnect(to?)`. A bare disconnect drops every out-edge. */
  noteDisconnect(from: object, to?: unknown): void {
    const fromId = this.ids.get(from);
    if (!fromId) return;
    const fromInfo = this.info.get(fromId);
    if (!fromInfo) return;
    const drop = (toId: string): void => {
      if (!fromInfo.outs.delete(toId)) return;
      this.edgeCount -= 1;
      const toInfo = this.info.get(toId);
      if (toInfo) toInfo.fanIn = Math.max(0, toInfo.fanIn - 1);
    };
    if (to !== undefined && typeof to === "object" && to !== null) {
      const toId = this.ids.get(to);
      if (toId) drop(toId);
      return;
    }
    for (const toId of [...fromInfo.outs]) drop(toId);
  }

  counts(): { nodes: number; edges: number; overflow: number } {
    return { nodes: this.info.size, edges: this.edgeCount, overflow: this.overflowCount };
  }

  /** How many registered AudioWorkletNodes carry this processor name. */
  workletCount(processor: string): number {
    let n = 0;
    for (const node of this.info.values()) if (node.processor === processor) n += 1;
    return n;
  }

  snapshot(limit = 40): GraphNodeSnapshot[] {
    const out: GraphNodeSnapshot[] = [];
    for (const node of this.info.values()) {
      if (out.length >= limit) break;
      out.push({
        id: node.id,
        type: node.type,
        ...(node.processor !== undefined ? { processor: node.processor } : {}),
        ...(node.trackIds !== undefined ? { trackIds: node.trackIds } : {}),
        ...(node.outputTrackIds !== undefined ? { outputTrackIds: node.outputTrackIds } : {}),
        outs: [...node.outs],
        fanIn: node.fanIn,
      });
    }
    return out;
  }

  /**
   * The graph as flat perf-record fields (`n3: "AudioWorkletNode(neteq-processor) ->n5 in:2"`),
   * so the topology survives Meet's post-call console wipe inside the perf
   * ring. Track ids and counts only — never participant names.
   */
  topologyFields(limit = 40): Record<string, string> {
    const fields: Record<string, string> = {};
    let n = 0;
    for (const node of this.info.values()) {
      if (n >= limit) {
        fields.topology_truncated = String(this.info.size - limit);
        break;
      }
      n += 1;
      const label = node.processor
        ? `${node.type}(${node.processor})`
        : node.trackIds
          ? `${node.type}(tracks=${node.trackIds.join("|")})`
          : node.outputTrackIds
            ? `${node.type}(mints=${node.outputTrackIds.join("|")})`
            : node.type;
      const outs = node.outs.size > 0 ? ` ->${[...node.outs].join(",")}` : "";
      fields[node.id] = `${label}${outs} in:${node.fanIn}`;
    }
    return fields;
  }
}

function constructorName(value: object): string {
  const name = (value as { constructor?: { name?: string } }).constructor?.name;
  return typeof name === "string" && name.length > 0 ? name : "unknown";
}
