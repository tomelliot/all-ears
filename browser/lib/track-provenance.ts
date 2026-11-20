import type { ProvenanceSnapshotEntry, TrackSnapshotEntry } from "./attribution-log";
import { looksLikeCaptureDevice } from "./capture-seams";
import { lineageOrigin, type GraphLineage, type GraphNodeSnapshot } from "./meet-audio-graph";

// Track provenance and the WebAudio track registry (split out of rtc-hook.ts,
// refactor R7): the realm-global bookkeeping that classifies tracks as
// local/remote by the page's own API contract, plus the registry of tracks
// Meet routes through WebAudio — the webaudio-track capture seam's supply.
// The passive wraps that FEED these registries are installed by rtc-hook.ts
// (installHook / the WebAudio probe); everything here is pure bookkeeping on
// window-global state, shared across re-injected epochs.

export interface WebAudioTrackRecord {
  track: MediaStreamTrack;
  via: string;
  registeredAt: string;
}
interface WebAudioTrackWindow extends Window {
  __earsWebAudioTracks?: Map<string, WebAudioTrackRecord>;
}

function webAudioTrackRegistry(): Map<string, WebAudioTrackRecord> {
  const g = window as unknown as WebAudioTrackWindow;
  if (!g.__earsWebAudioTracks) g.__earsWebAudioTracks = new Map();
  return g.__earsWebAudioTracks;
}

export function registerWebAudioTrack(track: MediaStreamTrack, via: string): void {
  try {
    const registry = webAudioTrackRegistry();
    if (registry.has(track.id)) return;
    classifyOnSight(track);
    registry.set(track.id, { track, via, registeredAt: new Date().toISOString() });
  } catch {
    // diagnostic only — never throws into Meet's audio path
  }
}

/**
 * Classify a track the moment it enters the WebAudio registry, so the seam
 * can never see it unjudged.
 *
 * This is the one place a webaudio-seam track is first seen, which makes it
 * the place to decide: the gUM/sender wraps below only fire when the page
 * makes those calls *while the hook is installed*, and a track that reaches
 * `createMediaStreamSource` without one of them having run would otherwise
 * enter the registry as `unknown` with nothing left to reconsider it.
 *
 * Only ever writes `local`, and only on positive evidence. A track with no
 * device settings is left unclassified rather than called `remote`: absence of
 * a `deviceId` is not evidence of remoteness, and writing a guess here would
 * poison `registerTrackProvenance`'s first-write-wins contract for the real
 * `ontrack` signal that may still arrive.
 */
function classifyOnSight(track: MediaStreamTrack): void {
  try {
    if (!looksLikeCaptureDevice(track.getSettings?.())) return;
    registerTrackProvenance(track.id, "local", "device-settings");
  } catch {
    // bookkeeping only — a track that won't report its settings stays unknown
  }
}

/**
 * Live audio tracks Meet has routed into WebAudio, newest last.
 *
 * Started as a diagnostic (is the WebAudio-side audio still per-participant?)
 * and became a capture seam once journal #105 showed these tracks carry real
 * decoded audio on builds where the RTP receiver tracks are silent decoys. The
 * `webaudio-track` seam in audio-tap.ts reads this; see capture-seams.ts.
 *
 * Ended tracks are pruned on read rather than on a `ended` listener, so the
 * registry costs nothing while nobody is asking. Returns a fresh array — the
 * caller must not hold the registry itself.
 */
export function webAudioTracks(): MediaStreamTrack[] {
  const registry = webAudioTrackRegistry();
  for (const [id, rec] of registry) {
    if (rec.track.readyState === "ended") {
      registry.delete(id);
      pruneTrackProvenance(id);
    }
  }
  classifyGraphOutputs([...registry.keys()]);
  return [...registry.values()].map((rec) => rec.track);
}


// ── Graph lineage: outputs of the page's own audio graph ────────────────────
//
// Meet mints tracks inside its WebAudio graph (MediaStreamAudioDestinationNode)
// and feeds them back into `createMediaStreamSource`. Such a track comes from
// no getUserMedia, sender or `ontrack` call and reports no capture device, so
// every other rule here leaves it unknown — yet some carry remote voices and
// some carry the user's processed microphone. On the 2026-11-19 call three of
// six were the microphone, and the transcript repeated the user under the
// other participant's name. The graph map (meet-webaudio-probe.ts) is the only
// thing that tells them apart: an output fed solely by local tracks is local.

/** The graph map, as provenance reads it. Installed by the WebAudio probe. */
export interface GraphLineageSource {
  lineageOf(trackId: string): GraphLineage | null;
  nodes(): GraphNodeSnapshot[];
}

interface GraphLineageWindow extends Window {
  __earsGraphLineage?: GraphLineageSource;
}

export function setGraphLineageSource(source: GraphLineageSource | null): void {
  const g = window as unknown as GraphLineageWindow;
  if (source) g.__earsGraphLineage = source;
  else delete g.__earsGraphLineage;
}

function graphLineageSource(): GraphLineageSource | undefined {
  try {
    return (window as unknown as GraphLineageWindow).__earsGraphLineage;
  } catch {
    return undefined;
  }
}

/** Passes over the registry per sweep: one output can feed the next, and each
 * pass settles one more link of such a chain. */
const GRAPH_CLASSIFY_MAX_PASSES = 4;

/**
 * Name as `local` every unclassified track the graph shows is fed only by
 * local tracks. Runs on each registry read, so a track adopted before the page
 * finished wiring its graph is named on a later sweep and retired then
 * (`seamTracksToRetire`). Only ever writes `local`, on positive evidence.
 */
function classifyGraphOutputs(ids: string[]): void {
  try {
    const source = graphLineageSource();
    if (!source) return;
    const originOf = (id: string): TrackOrigin | undefined => provenanceRegistry().get(id)?.origin;
    for (let pass = 0; pass < GRAPH_CLASSIFY_MAX_PASSES; pass += 1) {
      let changed = false;
      for (const id of ids) {
        if (provenanceRegistry().has(id)) continue;
        if (lineageOrigin(source.lineageOf(id), originOf) !== "local") continue;
        registerTrackProvenance(id, "local", "graph");
        changed = true;
      }
      if (!changed) return;
    }
  } catch {
    // bookkeeping only — a track the graph cannot place stays unknown
  }
}


// ── Track provenance: local/remote lineage for the webaudio seam ────────────
//
// The webaudio-track seam self-discovers anonymous tracks, and Meet's WebAudio
// graph carries the user's own outgoing audio alongside remote participants —
// on the 2026-08-05 call three of six adopted tracks were the local mic, so
// every utterance landed in the transcript four times. Provenance classifies a
// track from the page's own API contract, never from signal analysis: a track
// handed out by getUserMedia/getDisplayMedia or handed to a sender is local by
// construction; a track delivered by `ontrack` is remote; a clone inherits its
// parent; a track that reports a capture device in getSettings() is local
// (`classifyOnSight`, the signal that survives when the hook installed too late
// to witness any of the above); a track minted by the page's audio graph from
// local tracks alone is local (`classifyGraphOutputs`). Everything else stays unknown — and unknown
// ADOPTS (capture-seams.ts policy): a wrongly dropped remote track is
// unrecoverable data loss, a missed local one only a transcript-quality bug, so
// classification can only fail safe.
//
// Classification is a picture that only improves, never a one-shot decision:
// a track can arrive unclassified and be named local later, when the page
// hands it to a sender. `seamTracksToRetire` is what acts on that — the
// 2026-08-06 call adopted the local mic as unknown and, because provenance was
// read once at adoption, kept capturing the user for the whole 42 minutes.
//
// Realm-global like __earsLiveTracks, so re-injected epochs share one lineage.
// Reads and writes never enumerate getSenders()/getReceivers() — only the
// page's own calls are observed (the constraint at the top of this file).

export type TrackOrigin = "local" | "remote";

export interface TrackProvenanceRecord {
  origin: TrackOrigin;
  /** The API that established it: gum, display-media, sender, replaceTrack, ontrack, clone. */
  via: string;
  /** Lineage root — the original this track was (transitively) cloned from. */
  rootId: string;
  /** Registration order; clone-dedup keeps the earliest-registered per root. */
  seq: number;
}

interface ProvenanceWindow extends Window {
  __earsTrackProvenance?: Map<string, TrackProvenanceRecord>;
  __earsTrackProvenanceSeq?: number;
}

/** Leak backstop only — entries are pruned with the webaudio registry sweep,
 * but gUM/sender tracks the sweep never sees would otherwise accrue forever
 * on a page that mints tracks pathologically. Oldest evict first. */
export const PROVENANCE_MAX_ENTRIES = 512;

function provenanceRegistry(): Map<string, TrackProvenanceRecord> {
  const g = window as unknown as ProvenanceWindow;
  if (!g.__earsTrackProvenance) g.__earsTrackProvenance = new Map();
  return g.__earsTrackProvenance;
}

/** First write wins: an id's origin never flips (a remote track looped back
 * into a sender is still remote content). Bookkeeping only — never throws. */
export function registerTrackProvenance(
  id: string,
  origin: TrackOrigin,
  via: string,
  rootId: string = id,
): void {
  try {
    const registry = provenanceRegistry();
    if (registry.has(id)) return;
    while (registry.size >= PROVENANCE_MAX_ENTRIES) {
      const oldest = registry.keys().next().value;
      if (oldest === undefined) break;
      registry.delete(oldest);
    }
    const g = window as unknown as ProvenanceWindow;
    const seq = (g.__earsTrackProvenanceSeq = (g.__earsTrackProvenanceSeq ?? 0) + 1);
    registry.set(id, { origin, via, rootId, seq });
  } catch {
    // bookkeeping only — never throws into the page
  }
}

export function trackProvenance(id: string): TrackProvenanceRecord | undefined {
  try {
    return provenanceRegistry().get(id);
  } catch {
    return undefined;
  }
}

/**
 * Every WebAudio-registry track and every provenance record, as plain data —
 * the popup's "Send track snapshot" diagnostic (hook.content.ts).
 *
 * Read-only: `getSettings()`, `label` and the registries, the same reads
 * `classifyOnSight` already makes. No sender or receiver is enumerated and no
 * track is cloned or touched. `captureIds` maps a registry track id to the
 * capture handle recording it (audio-tap's `sourceTrackId`).
 */
export function trackSnapshot(captureIds: ReadonlyMap<string, string> = new Map()): {
  tracks: TrackSnapshotEntry[];
  provenance: ProvenanceSnapshotEntry[];
  graph: GraphNodeSnapshot[];
} {
  const lineageSource = graphLineageSource();
  const tracks: TrackSnapshotEntry[] = [];
  for (const [id, rec] of webAudioTrackRegistry()) {
    try {
      const track = rec.track;
      const record = trackProvenance(id);
      const captureId = captureIds.get(id);
      let settings: Record<string, unknown> = {};
      try {
        settings = { ...(track.getSettings?.() as Record<string, unknown> | undefined) };
      } catch {
        // a track that won't report settings still appears, with none
      }
      tracks.push({
        trackId: id,
        via: rec.via,
        registeredAt: rec.registeredAt,
        readyState: String(track.readyState),
        muted: track.muted === true,
        enabled: track.enabled === true,
        label: String(track.label ?? ""),
        constructorName: String(track.constructor?.name ?? ""),
        settings,
        ...(record ? { origin: record.origin, provenanceVia: record.via, rootId: record.rootId } : {}),
        ...(captureId ? { captureId } : {}),
        ...graphRootsOf(lineageSource, id),
      });
    } catch {
      // diagnostic only — one unreadable track must not hide the rest
    }
  }
  const provenance: ProvenanceSnapshotEntry[] = [];
  try {
    for (const [trackId, r] of provenanceRegistry()) {
      provenance.push({ trackId, origin: r.origin, via: r.via, rootId: r.rootId, seq: r.seq });
    }
  } catch {
    // diagnostic only
  }
  let graph: GraphNodeSnapshot[] = [];
  try {
    graph = lineageSource?.nodes() ?? [];
  } catch {
    // diagnostic only
  }
  return { tracks, provenance, graph };
}

/** The graph roots feeding `id`, labelled; undefined when no graph output
 * owns the track. Recorded with every adoption (audio-tap.ts). */
export function trackGraphRoots(id: string): string[] | undefined {
  return graphRootsOf(graphLineageSource(), id).graphRoots;
}

/** The graph roots feeding a track, labelled for the snapshot — track ids and
 * node types only. Absent when no graph output owns the track. */
function graphRootsOf(source: GraphLineageSource | undefined, id: string): { graphRoots?: string[] } {
  try {
    const lineage = source?.lineageOf(id);
    if (!lineage) return {};
    return {
      graphRoots: lineage.roots.map((root) =>
        root.processor
          ? `${root.type}(${root.processor})`
          : root.trackIds
            ? `${root.type}(tracks=${root.trackIds.join("|")})`
            : root.type,
      ),
    };
  } catch {
    return {};
  }
}

/** Drop an ended track's entry unless a live entry still claims it as root —
 * the root id is what keeps that root's later clones deduplicated. */
function pruneTrackProvenance(id: string): void {
  try {
    const registry = provenanceRegistry();
    const record = registry.get(id);
    if (!record) return;
    for (const other of registry.values()) {
      if (other !== record && other.rootId === id) return;
    }
    registry.delete(id);
  } catch {
    // bookkeeping only
  }
}

/**
 * Passive provenance wraps (installHook, once per realm, Meet only). Every
 * wrap is pass-through: the native call always runs first, its result returns
 * untouched, and bookkeeping failures never surface into the page.
 */
export function installProvenanceWraps(): void {
  try {
    const w = window as unknown as {
      navigator?: { mediaDevices?: Record<string, unknown> };
      MediaDevices?: { prototype?: Record<string, unknown> };
      MediaStreamTrack?: { prototype?: Record<string, unknown> };
      RTCRtpSender?: { prototype?: Record<string, unknown> };
      RTCPeerConnection?: { prototype?: Record<string, unknown> };
    };

    const registerStreamAudio = (value: unknown, via: string): void => {
      const tracks =
        (value as { getAudioTracks?: () => Array<{ id?: string }> } | null)?.getAudioTracks?.() ?? [];
      for (const track of tracks) {
        if (typeof track?.id === "string") registerTrackProvenance(track.id, "local", via);
      }
    };

    // getUserMedia / getDisplayMedia — the local roots. Wrap the prototype
    // when the platform exposes it (survives the page caching
    // navigator.mediaDevices), the instance otherwise.
    const wrapCapture = (holder: Record<string, unknown> | undefined, method: string, via: string): boolean => {
      const native = holder?.[method];
      if (!holder || typeof native !== "function") return false;
      holder[method] = function (this: unknown, ...args: unknown[]): unknown {
        const result = (native as (...a: unknown[]) => unknown).apply(this, args);
        try {
          void (result as Promise<unknown> | null)?.then?.(
            (stream) => registerStreamAudio(stream, via),
            () => {}, // the page's own copy of the rejection is untouched
          );
        } catch {
          // bookkeeping only
        }
        return result;
      };
      return true;
    };
    const mdProto = w.MediaDevices?.prototype;
    if (!wrapCapture(mdProto, "getUserMedia", "gum")) {
      wrapCapture(w.navigator?.mediaDevices, "getUserMedia", "gum");
    }
    if (!wrapCapture(mdProto, "getDisplayMedia", "display-media")) {
      wrapCapture(w.navigator?.mediaDevices, "getDisplayMedia", "display-media");
    }

    // Outgoing by construction: any audio track the page hands to a sender.
    // Observation of the page's own calls — getSenders() is never invoked.
    const wrapSenderArg = (holder: Record<string, unknown> | undefined, method: string, via: string): void => {
      const native = holder?.[method];
      if (!holder || typeof native !== "function") return;
      holder[method] = function (this: unknown, ...args: unknown[]): unknown {
        const result = (native as (...a: unknown[]) => unknown).apply(this, args);
        try {
          // addTransceiver's first arg may be a kind string — the guard skips it.
          const track = args[0] as { id?: string; kind?: string } | null;
          if (track && typeof track.id === "string" && track.kind === "audio") {
            registerTrackProvenance(track.id, "local", via);
          }
        } catch {
          // bookkeeping only
        }
        return result;
      };
    };
    const pcProto = w.RTCPeerConnection?.prototype;
    wrapSenderArg(pcProto, "addTrack", "sender");
    wrapSenderArg(pcProto, "addTransceiver", "sender");
    wrapSenderArg(w.RTCRtpSender?.prototype, "replaceTrack", "replaceTrack");

    // Lineage: a clone inherits origin and root, which is what makes "three
    // clones of one mic" one capture decision instead of three. A clone of an
    // unregistered parent stays unknown.
    const trackProto = w.MediaStreamTrack?.prototype;
    const nativeClone = trackProto?.clone;
    if (trackProto && typeof nativeClone === "function") {
      trackProto.clone = function (this: { id?: string }, ...args: unknown[]): unknown {
        const result = (nativeClone as (...a: unknown[]) => unknown).apply(this, args);
        try {
          const parent = typeof this?.id === "string" ? trackProvenance(this.id) : undefined;
          const cloneId = (result as { id?: string } | null)?.id;
          if (parent && typeof cloneId === "string") {
            registerTrackProvenance(cloneId, parent.origin, "clone", parent.rootId);
          }
        } catch {
          // bookkeeping only
        }
        return result;
      };
    }
  } catch (err) {
    console.debug("[ears][hook] provenance wraps failed to install (non-fatal):", err);
  }
}

