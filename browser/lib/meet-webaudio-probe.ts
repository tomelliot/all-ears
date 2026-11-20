import { AudioGraphRegistry, GRAPH_MAX_NODES } from "./meet-audio-graph";
import { registerWebAudioTrack, setGraphLineageSource } from "./track-provenance";

// The Meet WebAudio probe and audio-graph bridge (split out of rtc-hook.ts,
// refactor R7). Two jobs share the constructor wraps installed here:
//
//   1. Production sensing: every track Meet routes into WebAudio
//      (createMediaStreamSource inputs, audio MediaStreamTrackGenerator
//      outputs) is registered with track-provenance.ts's registry — the
//      webaudio-track capture seam's supply. This part is NOT debug-gated.
//      So is the audio-graph map (meet-audio-graph.ts): it is what tells a
//      graph output carrying the user's own microphone from one carrying
//      remote voices, and provenance reads it on every seam sweep.
//   2. Investigation surfaces, all flag-gated: the graph topology emitter and
//      per-track energy meters (__earsDebugAudio), and the downstream capture
//      bridge (__earsGraphBridge). rtc-hook.ts's audioprocessor tee shares the
//      same __earsDebugAudio flag via energyProbeEnabled.
//
// Installed once per realm by rtc-hook.ts's installHook (Meet only).

// WebAudio / decoded-output probe counters (journal #75) — where Meet's audio
// actually surfaces once it bypasses every encoded-frame API.
let probeAudioContextCount = 0;
let probeAudioWorkletNodeCount = 0;
let probeNetEqWorkletCount = 0;
let probeTrackGeneratorCount = 0;
let probeMediaStreamSourceCount = 0;
let probeMediaElementSrcObjectCount = 0;

// WebAudio / decoded-output probe (journal #75). Meet uses no JS encoded-frame
// tap, so its decoded participant audio must surface later — through WebAudio
// nodes, a MediaStreamTrackGenerator, or a media element. This maps that graph
// (pass-through, diagnostic only) to answer the one question that decides
// feasibility: does Meet keep ONE node/generator PER participant (per-participant
// capture still possible), or mix everything into one (only blended audio left)?
// Filter the console by `[ears][probe][webaudio]`.
export function installMeetWebAudioProbe(): void {
  try {
    const w = window as unknown as Record<string, unknown>;

    // Record the arm in the debug log: which probes this page load actually
    // ran is the first thing to know when reading a bug report.
    console.debug(
      `[ears][probe] audio probes — debugAudio:${energyProbeEnabled()} bridge:${graphBridgeEnabled()}`,
    );

    const streamTracks = (v: unknown): string => {
      const s = v as { getAudioTracks?: () => Array<{ id: string }> } | null;
      const ids = s?.getAudioTracks?.().map((t) => t.id) ?? null;
      return ids ? `[${ids.join(",")}]` : String(v);
    };

    // Pass-through constructor wrap: log each construction + count it.
    const wrapCtor = (name: string, label: (args: unknown[]) => string, tick: () => void): void => {
      const Native = w[name];
      if (typeof Native !== "function") return;
      const N = Native as new (...a: unknown[]) => object;
      const Wrapped = function (this: unknown, ...args: unknown[]): object {
        tick();
        console.debug(`[ears][probe][webaudio] new ${name} — ${label(args)}`);
        return new N(...args);
      } as unknown as new (...a: unknown[]) => object;
      Wrapped.prototype = N.prototype;
      Object.setPrototypeOf(Wrapped, N);
      w[name] = Wrapped;
    };

    wrapCtor(
      "AudioContext",
      (a) => `sampleRate=${(a[0] as { sampleRate?: number })?.sampleRate ?? "default"}`,
      () => (probeAudioContextCount += 1),
    );
    wrapCtor("webkitAudioContext", () => "webkit", () => (probeAudioContextCount += 1));
    // AudioWorkletNode gets a dedicated wrap (not wrapCtor) because the
    // bridge needs the constructed INSTANCE: neteq-processor nodes are the
    // playout end of Meet's WASM decode pipeline, and the edges Meet gives
    // them name the one safe tap point for decoded audio. Pass-through: the
    // native node is always constructed and returned; all bookkeeping is
    // flag-gated and try/caught.
    {
      const Native = w.AudioWorkletNode;
      if (typeof Native === "function") {
        const N = Native as new (...a: unknown[]) => object;
        const Wrapped = function (this: unknown, ...args: unknown[]): object {
          probeAudioWorkletNodeCount += 1;
          const processor = String(args[1]);
          console.debug(
            `[ears][probe][webaudio] new AudioWorkletNode — processor="${processor}" ch=${(args[2] as { channelCount?: number })?.channelCount ?? "?"}`,
          );
          const instance = new N(...args);
          try {
            if (processor === "neteq-processor") {
              probeNetEqWorkletCount += 1;
              // Remembered so the connect wrap can spot neteq→X edges. NEVER
              // branch off this node itself: an extra output edge on Meet's
              // neteq worklet trips a Chromium CHECK on the realtime audio
              // thread and kills the renderer (journal #93). The bridge taps
              // the NATIVE node downstream instead — see tapNetEqDownstream.
              netEqWorklets.add(instance);
            }
            meetGraph().noteWorklet(instance, processor);
            if (energyProbeEnabled()) ensureGraphTimer();
          } catch {
            // diagnostic only — never throws into Meet's audio path
          }
          return instance;
        } as unknown as new (...a: unknown[]) => object;
        Wrapped.prototype = N.prototype;
        Object.setPrototypeOf(Wrapped, N);
        w.AudioWorkletNode = Wrapped;
      }
    }
    // Audio generators are the leading candidate output of Meet's post-RTP
    // pipeline (2026-07-24 drift capture): register each constructed audio
    // generator (it IS a MediaStreamTrack) so a live debugging run can reach the
    // object, and fingerprint its energy when the debug flag is on.
    {
      const Native = w.MediaStreamTrackGenerator;
      if (typeof Native === "function") {
        const N = Native as new (...a: unknown[]) => object;
        const Wrapped = function (this: unknown, ...args: unknown[]): object {
          probeTrackGeneratorCount += 1;
          const kind = (args[0] as { kind?: string })?.kind ?? String(args[0]);
          console.debug(`[ears][probe][webaudio] new MediaStreamTrackGenerator — kind=${kind}`);
          const instance = new N(...args);
          if (kind === "audio") {
            const track = instance as unknown as MediaStreamTrack;
            registerWebAudioTrack(track, "generator");
            monitorTrackEnergy(track, "generator");
            // An audio generator IS a MediaStreamTrack — the zero-new-code
            // capture path. Record its appearance in the perf ring (the console
            // dies with Meet's post-call redirect) and, when the bridge flag is
            // on, feed it straight into the existing pipeline.
            try {
              if (energyProbeEnabled()) {
                graphEmit("meet_graph_generator", { kind: "audio", track: track.id ?? "?" });
              }
              if (graphBridgeEnabled()) bridgeTrack(track, "graphgen");
            } catch {
              // diagnostic only
            }
          }
          return instance;
        } as unknown as new (...a: unknown[]) => object;
        Wrapped.prototype = N.prototype;
        Object.setPrototypeOf(Wrapped, N);
        w.MediaStreamTrackGenerator = Wrapped;
      }
    }

    // createMediaStreamSource tells us which stream (→ which participant) Meet
    // routes into WebAudio, if any. Pass-through method wrap on the prototype.
    // Each audio track fed in is registered + energy-fingerprinted: on the
    // drift-affected build the RTP receiver tracks are silent decoys, and
    // whatever Meet hands to WebAudio here is where decoded participant audio
    // actually lives — energy-per-track answers whether it's still
    // per-participant (re-tappable) or already mixed.
    const acProto = (w.AudioContext as { prototype?: Record<string, unknown> } | undefined)?.prototype;
    const orig = acProto?.createMediaStreamSource;
    if (acProto && typeof orig === "function") {
      const native = orig as (...a: unknown[]) => unknown;
      nativeCreateMediaStreamSource = native;
      acProto.createMediaStreamSource = function (this: unknown, ...args: unknown[]): unknown {
        probeMediaStreamSourceCount += 1;
        console.debug(`[ears][probe][webaudio] createMediaStreamSource(audioTracks=${streamTracks(args[0])})`);
        const tracks = (args[0] as { getAudioTracks?: () => MediaStreamTrack[] } | null)?.getAudioTracks?.() ?? [];
        for (const track of tracks) {
          registerWebAudioTrack(track, "createMediaStreamSource");
          monitorTrackEnergy(track, "createMediaStreamSource");
        }
        const node = native.apply(this, args);
        // Register the RESULT node with the track ids feeding it: node →
        // participant cannot join on track id (these ids never match any hooked
        // receiver), so the graph records them for the offline unmute-edge join
        // instead. Ids only — never names.
        try {
          if (node !== null && typeof node === "object") {
            meetGraph().noteSource(node, tracks.map((t) => t.id));
          }
        } catch {
          // diagnostic only
        }
        return node;
      };
    }

    // ── Graph mapping: AudioNode.connect / disconnect (journal #76) ─────────
    // The connect topology is what tells a per-participant graph from a mixer:
    // N neteq nodes fanning into one destination is tappable per node; one
    // neteq node fed by everything is already mixed. Pass-through: the native
    // call ALWAYS runs (first, so a bookkeeping bug can't break Meet's audio),
    // its result is returned untouched, and bookkeeping is flag-gated.
    const nodeProto = (w.AudioNode as { prototype?: Record<string, unknown> } | undefined)
      ?.prototype;
    const nativeConnect = nodeProto?.connect;
    if (nodeProto && typeof nativeConnect === "function") {
      const native = nativeConnect as (...a: unknown[]) => unknown;
      nativeAudioNodeConnect = native;
      nodeProto.connect = function (this: object, ...args: unknown[]): unknown {
        const result = native.apply(this, args);
        try {
          noteGraphEnds(this, args[0]);
          meetGraph().noteConnect(this, args[0]);
          if (energyProbeEnabled()) ensureGraphTimer();
          // Meet wiring a neteq worklet into its own graph names the one safe
          // tap point for that participant's decoded audio: the NATIVE node
          // downstream. Branch the capture bridge off that, never the worklet.
          if (graphBridgeEnabled() && netEqWorklets.has(this)) {
            tapNetEqDownstream(args[0]);
          }
        } catch {
          // diagnostic only
        }
        return result;
      };
    }
    const nativeDisconnect = nodeProto?.disconnect;
    if (nodeProto && typeof nativeDisconnect === "function") {
      const native = nativeDisconnect as (...a: unknown[]) => unknown;
      nativeAudioNodeDisconnect = native;
      nodeProto.disconnect = function (this: object, ...args: unknown[]): unknown {
        const result = native.apply(this, args);
        try {
          meetGraph().noteDisconnect(this, args[0]);
        } catch {
          // diagnostic only
        }
        return result;
      };
    }

    // Provenance asks the graph where an output track's audio comes from.
    // Realm-global, so a re-injected epoch reads the map these wraps feed.
    setGraphLineageSource({
      lineageOf: (trackId) => meetGraph().lineageOf(trackId),
      nodes: () => meetGraph().snapshot(GRAPH_MAX_NODES),
    });

    // media.srcObject = stream — the other way decoded audio reaches output.
    const meProto = (w.HTMLMediaElement as { prototype?: object } | undefined)?.prototype;
    const desc = meProto && Object.getOwnPropertyDescriptor(meProto, "srcObject");
    if (meProto && desc?.set && desc.get) {
      const nset = desc.set;
      const nget = desc.get;
      Object.defineProperty(meProto, "srcObject", {
        configurable: true,
        enumerable: desc.enumerable ?? true,
        get(): unknown {
          return nget.call(this);
        },
        set(value: unknown): void {
          if (value) {
            probeMediaElementSrcObjectCount += 1;
            console.debug(`[ears][probe][webaudio] media.srcObject = audioTracks=${streamTracks(value)}`);
          }
          nset.call(this, value);
        },
      });
    }
  } catch (err) {
    console.debug("[ears][probe][webaudio] probe failed to install (non-fatal):", err);
  }
}

// ── Re-tap investigation: WebAudio track registry + energy fingerprint ──────
//
// 2026-07-24 (dev/captures/2026-07-24-meet-collections-drift.md): Meet migrated
// call audio off the RTCRtpReceiver path mid-call — receiver tracks stayed
// live-but-silent while playback ran through a page-side NetEQ AudioWorklet fed
// from tracks the hook never saw. The next instrumented call needs two things
// this section provides:
//
//   1. `window.__earsWebAudioTracks` — the actual MediaStreamTrack objects Meet
//      routes through WebAudio (createMediaStreamSource inputs, audio
//      MediaStreamTrackGenerator outputs), keyed by track id. During the live
//      capture run the track objects were unreachable (only their ids had
//      been logged), which blocked measuring them; this registry closes that gap.
//   2. Per-track energy fingerprints (`[ears][probe][webaudio] energy …`),
//      gated by the same `__earsDebugAudio` localStorage flag as audio-tap's
//      instrumentation: a throttled peak log per registered track, which
//      answers THE feasibility question — is the WebAudio-side audio still
//      per-participant (re-tappable), or already mixed?

/** Native (unwrapped) createMediaStreamSource, captured by the probe so the
 * energy monitor never re-enters its own wrap. */
let nativeCreateMediaStreamSource: ((...a: unknown[]) => unknown) | null = null;
/** Lazy shared context for energy monitoring — one per page, only ever built
 * when the debug flag is on and a track gets monitored. */
let energyProbeContext: AudioContext | null = null;
let monitoredTrackCount = 0;
const ENERGY_PROBE_MAX_TRACKS = 16;
const ENERGY_PROBE_INTERVAL_MS = 5_000;

export function energyProbeEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugAudio") === "1";
  } catch {
    return false;
  }
}

/** Attach a throttled peak meter to `track`, logging only while it carries
 * signal. Diagnostic only, `__earsDebugAudio`-gated, capped at
 * ENERGY_PROBE_MAX_TRACKS so a tile-heavy call can't build unbounded graph.
 * The meter lives in the probe's OWN AudioContext — it never adds an edge to
 * Meet's graph, which is what makes it safe (journal #90, arm 2). */
function monitorTrackEnergy(track: MediaStreamTrack, via: string): void {
  try {
    if (!energyProbeEnabled() || !nativeCreateMediaStreamSource) return;
    if (monitoredTrackCount >= ENERGY_PROBE_MAX_TRACKS) return;
    monitoredTrackCount += 1;

    if (!energyProbeContext) {
      const Ctor = (window as unknown as { AudioContext?: typeof AudioContext }).AudioContext;
      if (!Ctor) return;
      energyProbeContext = new Ctor();
    }
    const ctx = energyProbeContext;
    const source = nativeCreateMediaStreamSource.call(ctx, new MediaStream([track])) as MediaStreamAudioSourceNode;
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 2048;
    source.connect(analyser); // analyser has no output connection — no playback
    const buf = new Float32Array(analyser.fftSize);

    const timer = setInterval(() => {
      if (track.readyState === "ended") {
        clearInterval(timer);
        try {
          source.disconnect();
        } catch {
          // already gone
        }
        console.debug(`[ears][probe][webaudio] energy via=${via} track=${track.id} — track ended, meter off`);
        return;
      }
      analyser.getFloatTimeDomainData(buf);
      let peak = 0;
      for (let i = 0; i < buf.length; i++) {
        const a = Math.abs(buf[i]!);
        if (a > peak) peak = a;
      }
      // Silent samples are the common case — only signal is worth a line.
      if (peak > 0.001) {
        console.debug(
          `[ears][probe][webaudio] energy via=${via} track=${track.id} peak=${peak.toFixed(4)} (AUDIO)`,
        );
      }
    }, ENERGY_PROBE_INTERVAL_MS);
  } catch (err) {
    console.debug("[ears][probe][webaudio] energy meter failed to attach (non-fatal):", err);
  }
}


// ── Meet audio-graph probe: topology map + downstream capture bridge ────────
//
// Meet's participant audio lives downstream of a WASM NetEQ decode (journal
// #75): decoded PCM surfaces only through AudioWorkletNode("neteq-processor"),
// so no encoded-frame or receiver-track hook ever sees it. Two pieces recover
// it, both built around one hard constraint — adding an output edge to Meet's
// neteq worklet trips a Chromium CHECK on the realtime audio thread and kills
// the renderer (journal #93, #96). Nothing here ever connects anything to a
// worklet:
//
//   1. Topology map (`__earsDebugAudio`): pure-JS bookkeeping fed by the
//      pass-through connect/disconnect wraps, emitted through the perf ring so
//      it survives Meet's post-call redirect. Cannot touch the render graph.
//   2. Capture bridge (`__earsGraphBridge`): when Meet connects a neteq
//      worklet to a NATIVE node, branch THAT node into a
//      MediaStreamAudioDestinationNode and feed its stream to the real capture
//      pipeline as `graphtap-<n>`. The worklet keeps exactly the edges Meet
//      gave it; the extra edge sits on the native node, which is ordinary
//      graph work. If Meet's graph is per-participant the daemon records
//      separate streams; if it is mixed, the recordings prove that instead.
//      Audio-kind MediaStreamTrackGenerators bridge directly (`graphgen-<n>`)
//      — they already are tracks and involve no graph mutation at all.
//
// The MAIN world has no extension APIs and audio-tap/perf-main must not be
// imported here (audio-tap already imports this module), so the perf emitter
// and the bridge's pipeline entry are injected by hook.content.ts via
// setMeetGraphSinks — same realm-singleton pattern as __earsOnTrack.

/** Cap on bridged nodes/tracks — each one is a full capture pipeline. */
export const GRAPH_BRIDGE_MAX_NODES = 8;
/** Topology/summary emission cadence (summary every tick, topology every 2nd). */
const GRAPH_SUMMARY_INTERVAL_MS = 15_000;

export interface MeetGraphSinks {
  /** Ship one perf record (routed to mainPerf().emit by hook.content.ts). */
  emitPerf: (metric: string, fields: Record<string, number | string>) => void;
  /** Feed a bridged stream into the real capture pipeline (__devCaptureStream). */
  bridgeStream: (stream: MediaStream, participantId: string) => void;
}

interface GraphSinksWindow extends Window {
  __earsGraphSinks?: MeetGraphSinks;
}

/** Inject the perf emitter + bridge entry (hook.content.ts, once per realm).
 * Stored on `window` so re-injected epochs reach the live wraps' sinks. */
export function setMeetGraphSinks(sinks: MeetGraphSinks | null): void {
  const g = window as unknown as GraphSinksWindow;
  if (sinks) g.__earsGraphSinks = sinks;
  else delete g.__earsGraphSinks;
}

function graphEmit(metric: string, fields: Record<string, number | string>): void {
  try {
    (window as unknown as GraphSinksWindow).__earsGraphSinks?.emitPerf(metric, fields);
  } catch {
    // diagnostic only
  }
}

let graphRegistry: AudioGraphRegistry | null = null;

function meetGraph(): AudioGraphRegistry {
  if (!graphRegistry) graphRegistry = new AudioGraphRegistry();
  return graphRegistry;
}

/**
 * Record the track ids at either end of an edge the page is making: the
 * stream a source node reads, and the stream a destination node mints.
 *
 * Read at connect time off the nodes themselves (`mediaStream`, `stream` —
 * passive getters), so both the factory methods and the `new …Node(ctx)`
 * constructors are covered without wrapping either. The output ids are what
 * joins the graph to the WebAudio track registry: Meet feeds a destination's
 * stream back into `createMediaStreamSource`, and that is the track the
 * webaudio seam is offered.
 */
function noteGraphEnds(from: object, to: unknown): void {
  const ids = (stream: unknown): string[] | null => {
    const tracks = (stream as { getAudioTracks?: () => Array<{ id?: unknown }> } | null | undefined)
      ?.getAudioTracks?.();
    if (!Array.isArray(tracks)) return null;
    return tracks.map((t) => t?.id).filter((id): id is string => typeof id === "string");
  };
  try {
    if (!meetGraph().hasSourceTracks(from)) {
      const input = ids((from as { mediaStream?: unknown }).mediaStream);
      if (input) meetGraph().noteSource(from, input);
    }
  } catch {
    // bookkeeping only
  }
  try {
    if (typeof to === "object" && to !== null) {
      const output = ids((to as { stream?: unknown }).stream);
      if (output) meetGraph().noteDestination(to, output);
    }
  } catch {
    // bookkeeping only
  }
}

function graphBridgeEnabled(): boolean {
  try {
    return localStorage.getItem("__earsGraphBridge") === "1";
  } catch {
    return false;
  }
}

/** Every neteq-processor worklet Meet has constructed. Membership is the
 * connect wrap's cue that the edge's TARGET is a decoded-audio tap point. */
let netEqWorklets = new WeakSet<object>();

/** Native nodes already bridged (or ruled untappable) — Meet reconnects and
 * N neteq worklets can share one mixer, and each target is tapped once. */
let tappedTargets = new WeakSet<object>();

/** Live taps, kept so capture-off can sever the branches: an idle extension
 * must not keep Meet's graph pulled (an output edge keeps a node processing,
 * and processing propagates upstream to the worklets feeding it). Bounded by
 * GRAPH_BRIDGE_MAX_NODES. */
let bridgeTaps: Array<{ target: object; dest: AudioNode }> = [];

let bridgedNodeCount = 0;

/** Native (unwrapped) AudioNode.prototype.connect, captured by the probe so
 * the bridge's own branches never pollute the graph map. */
let nativeAudioNodeConnect: ((...a: unknown[]) => unknown) | null = null;

/** Native (unwrapped) AudioNode.prototype.disconnect, used to sever the
 * bridge's own branches without touching the graph bookkeeping. */
let nativeAudioNodeDisconnect: ((...a: unknown[]) => unknown) | null = null;

/** False only when the node reports zero outputs — nothing to branch off. An
 * unknown shape reads as connectable; the attach is try/caught regardless. */
function hasAudioOutput(node: object): boolean {
  const outputs = (node as { numberOfOutputs?: number }).numberOfOutputs;
  return typeof outputs !== "number" || outputs > 0;
}

/**
 * Meet just connected a neteq worklet to `target`. Branch `target` into the
 * capture pipeline — never the worklet itself (the renderer-fatal edge,
 * journal #93). One tap per target: if all N worklets feed one mixer this
 * yields a single `graphtap-1` carrying the mix; if each feeds its own native
 * node it yields one stream per participant. Either recording answers the
 * per-participant-vs-mixed question with ground truth.
 */
function tapNetEqDownstream(target: unknown): void {
  try {
    if (bridgedNodeCount >= GRAPH_BRIDGE_MAX_NODES) return;
    if (typeof target !== "object" || target === null) return;
    if (tappedTargets.has(target)) return;
    const ctx = (target as { context?: BaseAudioContext }).context;
    if (!ctx || typeof (ctx as AudioContext).createMediaStreamDestination !== "function") {
      return; // an AudioParam or non-node destination — not a tap point
    }
    tappedTargets.add(target);
    if (!hasAudioOutput(target)) {
      // neteq feeds a sink-shaped node (the context destination, or a
      // zero-output worklet) directly: there is no native node to branch off,
      // and per-participant capture needs a different seam on this build.
      // Recorded so a post-call read of the perf ring says so explicitly.
      graphEmit("meet_graph_bridge", { node: meetGraph().idOf(target) ?? "?", kind: "untappable-sink" });
      console.debug("[ears][probe][graph] neteq output feeds a sink-shaped node — no native tap point");
      return;
    }
    const dest = (ctx as AudioContext).createMediaStreamDestination();
    const connect = nativeAudioNodeConnect ?? (target as AudioNode).connect;
    connect.call(target, dest);
    bridgedNodeCount += 1;
    bridgeTaps.push({ target, dest });
    const participantId = `graphtap-${bridgedNodeCount}`;
    const id = meetGraph().idOf(target) ?? "?";
    (window as unknown as GraphSinksWindow).__earsGraphSinks?.bridgeStream(dest.stream, participantId);
    graphEmit("meet_graph_bridge", { node: id, kind: "downstream-tap", participant: participantId });
    console.debug(`[ears][probe][graph] bridged neteq downstream ${id} → ${participantId}`);
  } catch (err) {
    console.debug("[ears][probe][graph] downstream tap failed (non-fatal):", err);
  }
}

/** Bridge a bare audio track (MediaStreamTrackGenerator output) — it already
 * IS a MediaStreamTrack, so no graph mutation is involved at all. */
function bridgeTrack(track: MediaStreamTrack, prefix: string): void {
  try {
    if (bridgedNodeCount >= GRAPH_BRIDGE_MAX_NODES) return;
    bridgedNodeCount += 1;
    const participantId = `${prefix}-${bridgedNodeCount}`;
    (window as unknown as GraphSinksWindow).__earsGraphSinks?.bridgeStream(
      new MediaStream([track]),
      participantId,
    );
    graphEmit("meet_graph_bridge", { node: "generator", kind: "generator", participant: participantId });
    console.debug(`[ears][probe][graph] bridged audio generator → ${participantId}`);
  } catch (err) {
    console.debug("[ears][probe][graph] generator bridge failed (non-fatal):", err);
  }
}

let graphTimer: ReturnType<typeof setInterval> | null = null;
let graphTick = 0;

/** Start the topology/summary emitter (idempotent). Pure bookkeeping reads —
 * the timer never touches the audio graph, so it cannot crash a call. */
function ensureGraphTimer(): void {
  if (graphTimer) return;
  graphTimer = setInterval(() => {
    try {
      graphTick += 1;
      emitGraphSummary();
      if (graphTick % 2 === 0) emitGraphTopology();
    } catch {
      // diagnostic only
    }
  }, GRAPH_SUMMARY_INTERVAL_MS);
}

function emitGraphSummary(): void {
  const counts = meetGraph().counts();
  graphEmit("meet_graph_summary", {
    neteq_nodes: probeNetEqWorkletCount,
    graph_nodes: counts.nodes,
    graph_edges: counts.edges,
    graph_overflow: counts.overflow,
    bridged: bridgedNodeCount,
  });
  console.debug(
    `[ears][probe][graph] neteq=${probeNetEqWorkletCount} nodes=${counts.nodes} ` +
      `edges=${counts.edges} bridged=${bridgedNodeCount}`,
  );
}

function emitGraphTopology(): void {
  const fields = meetGraph().topologyFields();
  if (Object.keys(fields).length > 0) graphEmit("meet_graph_topology", fields);
}

/**
 * Sever every bridge branch and stop the emitter. Called when capture is
 * switched off: an idle extension must not keep Meet's graph pulled. Bridging
 * re-arms on the next neteq connect Meet makes (already-tapped targets stay
 * retired for the page's lifetime — new calls build new nodes).
 */
export function stopMeetGraphProbe(): void {
  for (const { target, dest } of bridgeTaps.splice(0)) {
    try {
      const disconnect = nativeAudioNodeDisconnect ?? (target as AudioNode).disconnect;
      disconnect.call(target, dest);
    } catch {
      // node already torn down by the page — the branch went with it
    }
  }
  if (graphTimer) {
    clearInterval(graphTimer);
    graphTimer = null;
  }
}

/** Test seam: drop the graph probe's realm state so each test starts clean.
 * (The wraps themselves stay installed — claimInstall owns that lifecycle.) */
export function __resetMeetGraphProbe(): void {
  stopMeetGraphProbe();
  graphRegistry = null;
  graphTick = 0;
  bridgedNodeCount = 0;
  probeNetEqWorkletCount = 0;
  probeAudioWorkletNodeCount = 0;
  netEqWorklets = new WeakSet();
  tappedTargets = new WeakSet();
}

/** Probe-layer state for rtc-hook.ts's hookDebugState aggregate. */
export function probeDebugState(): {
  webaudio: {
    audioContexts: number;
    audioWorkletNodes: number;
    netEqWorkletNodes: number;
    trackGenerators: number;
    mediaStreamSources: number;
    mediaElementSrcObjects: number;
  };
  graph: { nodes: number; edges: number; overflow: number; bridgedNodes: number };
} {
  const graphCounts = graphRegistry?.counts() ?? { nodes: 0, edges: 0, overflow: 0 };
  return {
    webaudio: {
      audioContexts: probeAudioContextCount,
      audioWorkletNodes: probeAudioWorkletNodeCount,
      netEqWorkletNodes: probeNetEqWorkletCount,
      trackGenerators: probeTrackGeneratorCount,
      mediaStreamSources: probeMediaStreamSourceCount,
      mediaElementSrcObjects: probeMediaElementSrcObjectCount,
    },
    graph: { ...graphCounts, bridgedNodes: bridgedNodeCount },
  };
}
