import { claimInstall } from "./epoch";
import { bytesToBase64 } from "./attribution-log";
import { recordAttribution } from "./attribution-recorder";
import {
  inflateGzip,
  parseCollectionsMessage,
  summarizeFields,
  type CollectionsMuteEvent,
} from "./identity/meet-collections";
import { JVB_DATA_CHANNEL_LABEL, observeBridgeDataChannel } from "./identity/jitsi-colibri";
import {
  installProvenanceWraps,
  registerTrackProvenance,
  registerWebAudioTrack,
} from "./track-provenance";
import {
  installMeetEncodedAudioTee,
  noteMeetAudioTrackLive,
  teedStreamCount,
} from "./meet-encoded-tee";
import {
  energyProbeEnabled,
  installMeetWebAudioProbe,
  probeDebugState,
} from "./meet-webaudio-probe";

// The RTCPeerConnection constructor hook — the singleton part of the capture
// spine, installed exactly once per page realm (claimInstall guards it). On
// meet.google.com it also wraps RTCRtpReceiver.prototype.createEncodedStreams
// (see §Meet encoded-audio tee below) — Meet's client decodes RTP itself off
// the standard pipeline, so this is the only way to ever see real audio there.
//
// Several things live on `window` so they survive across re-injected epochs,
// which each load a fresh module instance but share the one realm:
//
//   __earsOnTrack              the current epoch's track sink (audio-tap installs it)
//   __earsLiveTracks            our own registry of live remote audio tracks, so a new
//                               epoch can replay them and take over without dropping audio
//   __earsEncodedAudioListeners the current epoch's per-track Meet encoded-audio
//                               listener (meet-encoded-tee.ts owns it, Meet only)
//
// We never enumerate getReceivers()/getTransceivers() (breaks when Zoom wraps
// tracks) and never touch transceiver.direction or SDP (the crash class). The
// hook is a passive listener on the `track` event plus an ontrack-setter wrap;
// on Jitsi pages also a pass-through createDataChannel wrap (§Jitsi bridge
// datachannel below).

export type TrackSink = (track: MediaStreamTrack, stream: MediaStream) => void;

export interface TrackRecord {
  stream: MediaStream;
}

interface HookWindow extends Window {
  __earsOnTrack?: TrackSink;
  __earsLiveTracks?: Map<MediaStreamTrack, TrackRecord>;
  __earsLivePCs?: Set<RTCPeerConnection>;
  RTCPeerConnection: typeof RTCPeerConnection;
}

function hw(): HookWindow {
  return window as unknown as HookWindow;
}

/** The shared registry of currently-live remote audio tracks. */
export function liveTracks(): Map<MediaStreamTrack, TrackRecord> {
  const g = hw();
  if (!g.__earsLiveTracks) g.__earsLiveTracks = new Map();
  return g.__earsLiveTracks;
}

/**
 * The shared registry of peer connections this realm has constructed, kept so
 * the perf collector can poll `getStats()` for inbound *video* receive quality
 * (perf-sources.ts). The hook already sees every construction; nothing else in
 * the capture path needs the connection objects themselves, which is why this
 * registry did not exist before.
 *
 * Entries are dropped when the connection closes or fails, so a long call that
 * renegotiates repeatedly doesn't accumulate dead objects.
 */
export function livePeerConnections(): Set<RTCPeerConnection> {
  const g = hw();
  if (!g.__earsLivePCs) g.__earsLivePCs = new Set();
  return g.__earsLivePCs;
}

function registerPeerConnection(pc: RTCPeerConnection): void {
  const registry = livePeerConnections();
  registry.add(pc);
  pc.addEventListener("connectionstatechange", () => {
    if (pc.connectionState === "closed" || pc.connectionState === "failed") registry.delete(pc);
  });
}

// Passive observers of remote audio streams (identity/jitsi-detect.ts uses
// this to read the stream id when a track arrives, instead of polling the
// registry). Each call is isolated: an observer can't break track dispatch.
const remoteAudioObservers = new Set<(stream: MediaStream) => void>();

/** Observe each remote audio stream as its track arrives. Returns unsubscribe. */
export function onRemoteAudioStream(cb: (stream: MediaStream) => void): () => void {
  remoteAudioObservers.add(cb);
  return () => remoteAudioObservers.delete(cb);
}

/** Point the singleton hook at the newest epoch's sink. */
export function setTrackSink(sink: TrackSink): void {
  hw().__earsOnTrack = sink;
}

function dispatchTrack(e: RTCTrackEvent): void {
  if (e.track.kind !== "audio") return;
  registerTrackProvenance(e.track.id, "remote", "ontrack");
  const stream = e.streams[0] ?? new MediaStream([e.track]);
  const record: TrackRecord = { stream };
  const registry = liveTracks();
  registry.set(e.track, record);
  // Keep the registry honest so a later epoch's replay never resurrects a dead
  // track. Deleting here is safe: the sink also handles its own onended.
  e.track.addEventListener("ended", () => registry.delete(e.track));
  if (location.host === "meet.google.com") noteMeetAudioTrackLive();
  hw().__earsOnTrack?.(e.track, stream);
  for (const cb of remoteAudioObservers) {
    try {
      cb(stream);
    } catch {
      // an observer is never allowed to affect capture or the page
    }
  }
}

function onPeerConnection(pc: RTCPeerConnection): void {
  pc.addEventListener("track", dispatchTrack);
  registerPeerConnection(pc);
  if (location.host === "meet.google.com") installMeetCollectionsTracer(pc);
  if ((window as unknown as JvbWatchWindow).__earsJvbChannelWatch) observeJvbDataChannels(pc);

  // Also wrap the ontrack *setter* so a page handler assigned after us can't
  // shadow the hook. We call our dispatch first, then the page's handler.
  const desc = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, "ontrack");
  if (desc?.set && desc.get) {
    const nativeSet = desc.set;
    const nativeGet = desc.get;
    Object.defineProperty(pc, "ontrack", {
      configurable: true,
      enumerable: true,
      get() {
        return nativeGet.call(this);
      },
      set(handler: ((e: RTCTrackEvent) => void) | null) {
        nativeSet.call(this, (e: RTCTrackEvent) => {
          dispatchTrack(e);
          return handler?.call(this, e);
        });
      },
    });
  }
}

/**
 * Install the constructor wrapper once per realm. Safe to call on every epoch;
 * only the first call wraps. Must run at document_start, before the page's
 * first `new RTCPeerConnection()` (Zoom caches the constructor at bootstrap).
 */
export function installHook(): void {
  if (!claimInstall()) return; // already wrapped in this realm

  const g = hw();
  const Original = g.RTCPeerConnection;

  function Wrapped(this: unknown, ...args: unknown[]): RTCPeerConnection {
    const pc = new (Original as unknown as new (...a: unknown[]) => RTCPeerConnection)(...args);
    onPeerConnection(pc); // register + attach track listeners
    return pc; // returning the real pc supersedes `this` — callers get a native PC
  }

  Wrapped.prototype = Original.prototype; // instanceof stays true
  Object.setPrototypeOf(Wrapped, Original); // inherit statics (generateCertificate…)
  // Stable, minification-proof marker so tests/tools can tell our wrapper from
  // the native constructor without relying on Function.name.
  Object.defineProperty(Wrapped, "__earsWrapped", { value: true, enumerable: false });
  g.RTCPeerConnection = Wrapped as unknown as typeof RTCPeerConnection;

  // Meet-only: intercept createEncodedStreams() before Meet's own client calls
  // it (~2s after connect) and diverts audio off the standard decode pipeline
  // (see specs/extension.md §Audio extraction — Meet path). Gated here, at
  // install time, on the resolved host — not through audio-tap.ts's
  // capture-epoch config, which isn't populated until after this returns.
  // Applying the tee on other platforms would double-capture where the
  // standard MediaStreamTrackProcessor path already works.
  if (location.host === "meet.google.com") installMeetEncodedAudioTee();
  if (location.host === "meet.google.com") installMeetWebAudioProbe();
  // Meet-only like the probes above: the webaudio-track seam is the sole
  // consumer (seamOrderFor), and Zoom's own track wrapping is exactly the
  // surface rtc-hook stays off (see the constraint at the top of this file).
  if (location.host === "meet.google.com") installProvenanceWraps();

  console.debug("[ears][hook] RTCPeerConnection hook installed");
}

// ── Meet collections datachannel: device-id/speaking-flag signal ───────────
//
// Narrow, reviewed exception to specs/extension.md's MUST-NOT #6 (journal
// #49-#51; see docs/specs/browser/extension.md (the collections exception))
// — decodes exactly the two fields documented there via meet-collections.ts's
// defensive parser, nothing else. Unlike installChannelTracer below (debug-
// only, investigation-scoped), this runs in production whenever the hook
// installs on meet.google.com: lib/identity/meet.ts's MeetAdapter needs this
// signal at runtime to correlate speaking activity to device ids, not just
// during investigation.
//
// Passive and best-effort. Per-message parse failures are silent (the parser
// itself never throws and returns null on any mismatch); this tracer only
// tracks aggregate seen/parsed counts so it can warn once if the channel is
// live but nothing is parsing — e.g. Meet changed the wire format — the same
// "warn once, degrade silently otherwise" shape as installMeetEncodedAudioTee
// and meet.ts's maybeWarnStructure().

export type CollectionsListener = (event: CollectionsMuteEvent) => void;

interface CollectionsWindow extends Window {
  __earsCollectionsListener?: CollectionsListener;
}

/** MeetAdapter registers here (latest-registration wins, same handoff pattern
 * as setTrackSink) to receive parsed collections events. */
export function setCollectionsListener(listener: CollectionsListener | null): void {
  const g = window as unknown as CollectionsWindow;
  if (listener) g.__earsCollectionsListener = listener;
  else delete g.__earsCollectionsListener;
}

let collectionsSeen = 0;
let collectionsParsed = 0;
let warnedCollectionsSchema = false;

function maybeWarnCollectionsSchema(): void {
  if (warnedCollectionsSchema) return;
  if (collectionsSeen < 5 || collectionsParsed > 0) return; // give it a few messages before concluding it's broken
  warnedCollectionsSchema = true;
  console.warn(
    "[ears][hook] Meet 'collections' datachannel is sending messages but none parsed as the expected " +
      "device-id/speaking-flag shape — Meet likely changed its wire format. Identity upgrade via " +
      "this path is disabled for this page load; capture still works via speaker-<n>. See lib/identity/meet-collections.ts.",
  );
}

function bufferFromMessageData(data: unknown): Promise<ArrayBuffer> | null {
  if (data instanceof ArrayBuffer) return Promise.resolve(data);
  if (data instanceof Blob) return data.arrayBuffer();
  if (ArrayBuffer.isView(data)) {
    const view = data as ArrayBufferView;
    return Promise.resolve(new Uint8Array(view.buffer, view.byteOffset, view.byteLength).slice().buffer);
  }
  return null; // string frames aren't expected on this channel; ignore rather than guess
}

function attachCollectionsLogger(ch: RTCDataChannel): void {
  ch.addEventListener("message", (ev: MessageEvent) => {
    const bufPromise = bufferFromMessageData(ev.data);
    if (!bufPromise) return;
    collectionsSeen++;
    void bufPromise
      .then(async (buf) => [buf, await parseCollectionsMessage(buf)] as const)
      .then(([buf, parsed]) => {
        if (!parsed) {
          maybeWarnCollectionsSchema();
          return;
        }
        collectionsParsed++;
        // Flight recorder: the parsed fields AND the raw payload bytes (still
        // gzip-compressed), so a wire-format drift can be re-parsed offline.
        recordAttribution({
          type: "collections-edge",
          t: Date.now(),
          deviceId: parsed.deviceId,
          micOpen: parsed.micOpen,
          rawB64: bytesToBase64(new Uint8Array(buf)),
        });
        (window as unknown as CollectionsWindow).__earsCollectionsListener?.(parsed);
      })
      .catch(() => {
        // parseCollectionsMessage already never throws; this guards the
        // promise chain itself so a malformed message can never surface as
        // an unhandled rejection in the page.
      });
  });
}

function installMeetCollectionsTracer(pc: RTCPeerConnection): void {
  pc.addEventListener("datachannel", (ev: RTCDataChannelEvent) => {
    if (ev.channel.label === "collections") attachCollectionsLogger(ev.channel);
    else if (ev.channel.label === "audioprocessor") maybeAttachAudioprocessorTee(ev.channel);
  });
}

// ── Jitsi bridge datachannel (identity, passive) ───────────────────────────
//
// On meet.jit.si the videobridge's Colibri channel is an RTCDataChannel
// labelled `JVB data channel` on the bridge peer connection, not a WebSocket
// (live call, 2026-11-22). Its messages name the local endpoint and the owner
// of each SSRC-rewriting audio slot; identity/jitsi-colibri.ts parses them.
// lib-jitsi-meet may open the channel itself (`createDataChannel`) or receive
// it from the bridge (`datachannel` event), so both are watched. The
// `createDataChannel` wrap is per connection, like the `ontrack` one: it calls
// the native method with the same arguments and returns its channel
// untouched. Observation is one added `message` listener — nothing is
// consumed, altered or re-dispatched. Enabled by hook.content.ts on `jitsi`
// and `web` pages, before any page script constructs a connection.

interface JvbWatchWindow {
  __earsJvbChannelWatch?: boolean;
}

/** Watch every peer connection constructed from now on for the Jitsi bridge
 * channel. Idempotent; call at document_start, right after installHook. */
export function watchJvbDataChannels(): void {
  (window as unknown as JvbWatchWindow).__earsJvbChannelWatch = true;
}

function maybeObserveJvbChannel(channel: RTCDataChannel | null | undefined): void {
  try {
    if (channel?.label === JVB_DATA_CHANNEL_LABEL) observeBridgeDataChannel(channel);
  } catch {
    // identity is best-effort; it never affects the page's channel
  }
}

function observeJvbDataChannels(pc: RTCPeerConnection): void {
  pc.addEventListener("datachannel", (ev: RTCDataChannelEvent) => maybeObserveJvbChannel(ev.channel));
  const native = (pc as { createDataChannel?: RTCPeerConnection["createDataChannel"] }).createDataChannel;
  if (typeof native !== "function") return;
  Object.defineProperty(pc, "createDataChannel", {
    configurable: true,
    writable: true,
    value: function createDataChannel(this: RTCPeerConnection, ...args: Parameters<RTCPeerConnection["createDataChannel"]>) {
      const channel = native.apply(this, args);
      maybeObserveJvbChannel(channel);
      return channel;
    },
  });
}

// ── Meet audioprocessor datachannel tee (debug-gated, investigation) ────────
//
// Open question from the 2026-08-05 live probes: `audioprocessor` runs at a
// steady ~2/s regardless of speech, but its payloads have never been examined
// — and meet.new now auto-joins with no pre-join screen, so every channel
// opens before injected page JS can attach. This document_start tee is the
// only remaining way to see them. Purpose: settle whether the channel carries
// per-device activity data. Unlike the collections tracer above it is
// investigation-scoped: gated on `__earsDebugAudio` (read once at channel
// open, same flag as the energy probes), records only {timestamp, byteLength}
// plus a field-number/wire-type sketch (summarizeFields — structure, never
// content), and logs one throttled summary line per window.

const AUDIOPROCESSOR_SUMMARY_MS = 10_000;
/** Backstop on per-window sample growth; ~2/s observed, so never reached. */
const AUDIOPROCESSOR_RING_MAX = 512;

export interface ChannelSample {
  t: number;
  byteLength: number;
}

/** One log line per summary window: count, size histogram, payload sketch.
 * Pure and exported for tests. */
export function formatChannelSummary(samples: readonly ChannelSample[], sniff: string | null): string {
  const buckets = { "≤64B": 0, "≤256B": 0, "≤1KB": 0, ">1KB": 0 };
  for (const s of samples) {
    if (s.byteLength <= 64) buckets["≤64B"]++;
    else if (s.byteLength <= 256) buckets["≤256B"]++;
    else if (s.byteLength <= 1024) buckets["≤1KB"]++;
    else buckets[">1KB"]++;
  }
  const sizes = Object.entries(buckets)
    .filter(([, n]) => n > 0)
    .map(([k, n]) => `${k}:${n}`)
    .join(" ");
  return `${samples.length} msgs sizes{${sizes}} fields=${sniff ?? "unsniffed"}`;
}

function maybeAttachAudioprocessorTee(ch: RTCDataChannel): void {
  try {
    if (!energyProbeEnabled()) return;
  } catch {
    return;
  }
  let samples: ChannelSample[] = [];
  let windowStart = 0;
  let sniff: string | null = null;
  let sniffPending = false;

  ch.addEventListener("message", (ev: MessageEvent) => {
    try {
      const t = Date.now();
      const data: unknown = ev.data;
      const byteLength =
        data instanceof ArrayBuffer
          ? data.byteLength
          : data instanceof Blob
            ? data.size
            : ArrayBuffer.isView(data)
              ? data.byteLength
              : typeof data === "string"
                ? data.length
                : 0;
      if (windowStart === 0) windowStart = t;
      if (samples.length < AUDIOPROCESSOR_RING_MAX) samples.push({ t, byteLength });

      // One payload sketch per window — enough to recognize the schema
      // without touching every message.
      if (sniff === null && !sniffPending) {
        const bufPromise = bufferFromMessageData(data);
        if (bufPromise) {
          sniffPending = true;
          void bufPromise
            .then(async (buf) => {
              const bytes = (await inflateGzip(buf)) ?? new Uint8Array(buf);
              sniff = summarizeFields(bytes, 2) ?? "unparsed";
            })
            .catch(() => {
              sniff = "unparsed";
            })
            .finally(() => {
              sniffPending = false;
            });
        }
      }

      if (t - windowStart >= AUDIOPROCESSOR_SUMMARY_MS) {
        console.debug(`[ears][probe][audioprocessor] ${formatChannelSummary(samples, sniff)}`);
        samples = [];
        windowStart = t;
        sniff = null; // re-sniff next window — schema may vary by message type
      }
    } catch {
      // diagnostic only — never throws into Meet's channel handling
    }
  });
}

/** Hook-layer state for the popup's debug report (see hook.content.ts). */
export function hookDebugState(): {
  liveTracks: number;
  teedAudioStreamCount: number;
  webaudio: {
    audioContexts: number;
    audioWorkletNodes: number;
    netEqWorkletNodes: number;
    trackGenerators: number;
    mediaStreamSources: number;
    mediaElementSrcObjects: number;
  };
  graph: {
    nodes: number;
    edges: number;
    overflow: number;
    bridgedNodes: number;
  };
} {
  return {
    liveTracks: liveTracks().size,
    teedAudioStreamCount: teedStreamCount(),
    ...probeDebugState(),
  };
}

