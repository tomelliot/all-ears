import { claimInstall } from "./epoch";
import {
  debugDecodeStructure,
  inflateGzip,
  parseCollectionsMessage,
  type CollectionsMuteEvent,
} from "./identity/meet-collections";

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
//                               listener (audio-tap installs it, Meet only)
//
// We never enumerate getReceivers()/getTransceivers() (breaks when Zoom wraps
// tracks) and never touch transceiver.direction or SDP (the crash class). The
// hook is a passive listener on the `track` event plus an ontrack-setter wrap.

export type TrackSink = (
  track: MediaStreamTrack,
  stream: MediaStream,
  transceiver: RTCRtpTransceiver,
) => void;

export interface TrackRecord {
  stream: MediaStream;
  transceiver: RTCRtpTransceiver;
}

/** The raw pre-decode RTP frame shape delivered by createEncodedStreams()'s readable. */
export interface EncodedAudioFrameLike {
  readonly data: ArrayBuffer;
  readonly timestamp: number;
}

export type EncodedAudioListener = (frame: EncodedAudioFrameLike) => void;

interface HookWindow extends Window {
  __earsOnTrack?: TrackSink;
  __earsLiveTracks?: Map<MediaStreamTrack, TrackRecord>;
  __earsEncodedAudioListeners?: Map<MediaStreamTrack, EncodedAudioListener>;
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

/** Point the singleton hook at the newest epoch's sink. */
export function setTrackSink(sink: TrackSink): void {
  hw().__earsOnTrack = sink;
}

function dispatchTrack(e: RTCTrackEvent): void {
  if (e.track.kind !== "audio") return;
  const stream = e.streams[0] ?? new MediaStream([e.track]);
  const record: TrackRecord = { stream, transceiver: e.transceiver };
  const registry = liveTracks();
  registry.set(e.track, record);
  // Keep the registry honest so a later epoch's replay never resurrects a dead
  // track. Deleting here is safe: the sink also handles its own onended.
  e.track.addEventListener("ended", () => registry.delete(e.track));
  if (location.host === "meet.google.com") noteMeetAudioTrackLive();
  hw().__earsOnTrack?.(e.track, stream, e.transceiver);
}

function onPeerConnection(pc: RTCPeerConnection): void {
  pc.addEventListener("track", dispatchTrack);
  if (location.host === "meet.google.com") installMeetCollectionsTracer(pc);
  if (location.host === "meet.google.com" && debugChannelsEnabled()) installChannelTracer(pc);

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
  if (location.host === "meet.google.com") installMeetTransformProbe();
  if (location.host === "meet.google.com") installMeetWebAudioProbe();
  if (location.host === "meet.google.com" && debugChannelsEnabled()) installNetworkTracer();

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
      "this path is disabled for this session; capture still works via speaker-<n>. See lib/identity/meet-collections.ts.",
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
      .then((buf) => parseCollectionsMessage(buf))
      .then((parsed) => {
        if (!parsed) {
          maybeWarnCollectionsSchema();
          return;
        }
        collectionsParsed++;
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
    if (ev.channel.label !== "collections") return;
    attachCollectionsLogger(ev.channel);
  });
}

// ── Network/datachannel tracer (debug-only, investigation-scoped) ──────────
//
// meet-speaking-indicator-correlation prompt, Task 2: check whether Meet's
// active-speaker tile animation is server-pushed (WS/datachannel frames) or
// purely client-computed from local audio energy. Decoding payload bytes of
// Meet's private channels (including "collections") is normally prohibited
// by extension.md MUST-NOT #6 — that constraint is scoped to what SHIPS, and
// is explicitly relaxed for this investigation only (see the prompt's Task 2
// note). This tracer is off by default and gated behind its own flag; it must
// never be enabled outside a deliberate investigation session, and nothing
// here should be treated as an implementation to ship un-reviewed.
//
// Purely passive: observes datachannel creation/messages and WebSocket frames,
// never mutates them. Enable per-tab from DevTools console:
//   localStorage.setItem("__earsDebugChannels", "1")   // then reload the tab
//   localStorage.removeItem("__earsDebugChannels")     // to turn back off

function debugChannelsEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugChannels") === "1";
  } catch {
    return false;
  }
}

interface NetLogEntry {
  t: number;
  iso: string;
  kind: "ws" | "datachannel";
  label?: string;
  url?: string;
  preview: string;
  /** Full raw bytes (capped at 8KB) for offline decode — the hex in `preview` truncates at 200B. */
  bytes?: number[];
}
interface NetLogWindow extends Window {
  __earsNetLog?: NetLogEntry[];
}
function netLog(): NetLogEntry[] {
  const g = window as unknown as NetLogWindow;
  if (!g.__earsNetLog) g.__earsNetLog = [];
  return g.__earsNetLog;
}

function bufferPreview(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf).slice(0, 200);
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join(" ");
  let text = "";
  try {
    text = new TextDecoder("utf-8", { fatal: false }).decode(bytes).replace(/[^\x20-\x7e]/g, ".");
  } catch {
    text = "";
  }
  return `${buf.byteLength}b hex[${hex}]${buf.byteLength > 200 ? "…" : ""} text="${text}"`;
}

/** Full raw bytes (capped at 8KB) for offline decode, e.g. gzip+protobuf inspection. */
function rawBytes(buf: ArrayBuffer): number[] {
  return Array.from(new Uint8Array(buf).slice(0, 8192));
}

function previewPayload(data: unknown): string {
  try {
    if (typeof data === "string") {
      return data.length > 300 ? `${data.slice(0, 300)}…(+${data.length - 300}b)` : data;
    }
    if (data instanceof ArrayBuffer) return bufferPreview(data);
    if (ArrayBuffer.isView(data)) {
      const view = data as ArrayBufferView;
      const bytes = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
      return bufferPreview(bytes.slice().buffer);
    }
  } catch {
    // fall through to String(data) below
  }
  return String(data);
}

/**
 * Debug-only (__earsDebugChannels): print the full recursive field structure
 * of a "collections" message, not just the two production paths. Built
 * during live verification of the collections identity-upgrade feature,
 * where it found that journal #49's originally-documented speaking-flag path
 * was missing a nesting level (see meet-collections.ts's header comment and
 * docs/specs/browser/extension.md) — kept in the extension so the
 * next schema drift doesn't need an ad-hoc page-injected decoder again.
 * Never used by production parsing; a decode failure here is just a log line.
 */
async function logCollectionsStructure(buf: ArrayBuffer): Promise<void> {
  const inflated = await inflateGzip(buf);
  if (!inflated) {
    console.debug("[ears][debug][net] collections message: not gzip, or failed to inflate");
    return;
  }
  const lines = debugDecodeStructure(inflated);
  console.debug(`[ears][debug][net] collections decoded structure (${inflated.length}B):\n${lines.join("\n")}`);
}

function attachChannelLogger(ch: RTCDataChannel): void {
  ch.addEventListener("message", (ev: MessageEvent) => {
    const t = Date.now();
    if (ev.data instanceof Blob) {
      void ev.data.arrayBuffer().then((buf) => {
        const preview = bufferPreview(buf);
        console.debug(`[ears][debug][net] DC[${ch.label}] ${preview}`);
        netLog().push({ t, iso: new Date(t).toISOString(), kind: "datachannel", label: ch.label, preview, bytes: rawBytes(buf) });
        if (ch.label === "collections") void logCollectionsStructure(buf);
      });
      return;
    }
    const preview = previewPayload(ev.data);
    console.debug(`[ears][debug][net] DC[${ch.label}] ${preview}`);
    const entry: NetLogEntry = { t, iso: new Date(t).toISOString(), kind: "datachannel", label: ch.label, preview };
    let buf: ArrayBuffer | null = null;
    if (ev.data instanceof ArrayBuffer) buf = ev.data;
    else if (ArrayBuffer.isView(ev.data)) {
      const view = ev.data as ArrayBufferView;
      buf = new Uint8Array(view.buffer, view.byteOffset, view.byteLength).slice().buffer;
    }
    if (buf) {
      entry.bytes = rawBytes(buf);
      if (ch.label === "collections") void logCollectionsStructure(buf);
    }
    netLog().push(entry);
  });
}

function installChannelTracer(pc: RTCPeerConnection): void {
  pc.addEventListener("datachannel", (ev: RTCDataChannelEvent) => {
    const ch = ev.channel;
    console.debug(
      `[ears][debug][net] datachannel (remote) label="${ch.label}" id=${ch.id} protocol="${ch.protocol}" ordered=${ch.ordered}`,
    );
    attachChannelLogger(ch);
  });
  const nativeCreate = pc.createDataChannel.bind(pc);
  pc.createDataChannel = ((label: string, opts?: RTCDataChannelInit) => {
    const ch = nativeCreate(label, opts);
    console.debug(`[ears][debug][net] datachannel (local) label="${ch.label}" id=${ch.id}`);
    attachChannelLogger(ch);
    return ch;
  }) as typeof pc.createDataChannel;
}

function installNetworkTracer(): void {
  const Native = window.WebSocket;
  if (!Native) return;
  function Wrapped(this: unknown, url: string | URL, protocols?: string | string[]): WebSocket {
    const ws = protocols === undefined ? new Native(url) : new Native(url, protocols);
    console.debug(`[ears][debug][net] WebSocket open → ${url}`);
    ws.addEventListener("message", (ev: MessageEvent) => {
      const t = Date.now();
      if (ev.data instanceof Blob) {
        void ev.data.arrayBuffer().then((buf) => {
          const preview = bufferPreview(buf);
          console.debug(`[ears][debug][net] WS ← ${url} ${preview}`);
          netLog().push({ t, iso: new Date(t).toISOString(), kind: "ws", url: String(url), preview, bytes: rawBytes(buf) });
        });
        return;
      }
      const preview = previewPayload(ev.data);
      console.debug(`[ears][debug][net] WS ← ${url} ${preview}`);
      const entry: NetLogEntry = { t, iso: new Date(t).toISOString(), kind: "ws", url: String(url), preview };
      if (ev.data instanceof ArrayBuffer) entry.bytes = rawBytes(ev.data);
      else if (ArrayBuffer.isView(ev.data)) {
        const view = ev.data as ArrayBufferView;
        entry.bytes = rawBytes(new Uint8Array(view.buffer, view.byteOffset, view.byteLength).slice().buffer);
      }
      netLog().push(entry);
    });
    ws.addEventListener("close", () => console.debug(`[ears][debug][net] WebSocket closed → ${url}`));
    return ws;
  }
  Wrapped.prototype = Native.prototype;
  Object.setPrototypeOf(Wrapped, Native);
  window.WebSocket = Wrapped as unknown as typeof WebSocket;
  console.debug("[ears][debug][net] WebSocket tracer installed");
}

// ── Meet encoded-audio tee ───────────────────────────────────────────────
//
// Empirically confirmed (journal #28–#31): Meet's client calls
// receiver.createEncodedStreams() on every audio receiver and decodes the RTP
// itself, so no MediaStreamTrack-based mechanism ever receives a frame for a
// Meet remote participant. The fix: intercept the same call, .tee() the
// readable so Meet's own playback branch is untouched, and read our branch
// independently.
//
// One persistent read loop per tee'd track, started here and never torn down
// across epochs — a ReadableStream reader can't be handed off between epochs
// without cancelling it, and cancelling a tee'd branch closes that branch
// permanently (Meet calls createEncodedStreams() once per receiver, so a
// closed branch would mean no audio for the rest of the call). Instead, raw
// frames dispatch to whichever epoch's listener is currently registered —
// exactly the same latest-wins handoff setTrackSink already uses for track
// events. With no listener registered, frames are simply dropped, never
// buffered.

interface EncodedStreamsResult {
  readable: ReadableStream<EncodedAudioFrameLike>;
  writable: WritableStream<EncodedAudioFrameLike>;
}

interface EncodedStreamsReceiver {
  readonly track: MediaStreamTrack | null;
  createEncodedStreams(): EncodedStreamsResult;
}

function encodedAudioListeners(): Map<MediaStreamTrack, EncodedAudioListener> {
  const g = hw();
  if (!g.__earsEncodedAudioListeners) g.__earsEncodedAudioListeners = new Map();
  return g.__earsEncodedAudioListeners;
}

/**
 * Meet only: (re)subscribe to raw pre-decode Opus frames for `track`. Pass
 * `null` to unsubscribe. Only the latest subscriber receives frames.
 */
export function setEncodedAudioListener(
  track: MediaStreamTrack,
  listener: EncodedAudioListener | null,
): void {
  if (listener) encodedAudioListeners().set(track, listener);
  else encodedAudioListeners().delete(track);
}

async function pumpEncodedAudio(
  track: MediaStreamTrack,
  readable: ReadableStream<EncodedAudioFrameLike>,
): Promise<void> {
  const reader = readable.getReader();
  track.addEventListener("ended", () => void reader.cancel().catch(() => {}), { once: true });
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return;
      encodedAudioListeners().get(track)?.(value);
    }
  } catch (err) {
    console.error(`[ears][hook] encoded-audio tee read error for track ${track.id}:`, err);
  }
}

// Diagnostic for the silent-capture failure (journal #72): count how many audio
// receivers Meet actually routed through our createEncodedStreams wrap. If audio
// tracks go live but this stays zero, Meet never called our hook and every
// participant records silence for the whole call — surface it loudly, once.
let teedAudioStreamCount = 0;
let teeWatchdogArmed = false;
const TEE_WATCHDOG_MS = 6_000;

// Probe findings (set by installMeetTransformProbe), surfaced in the tee
// watchdog so a single guaranteed-visible `[ears][hook]` line names the encoded-frame
// API Meet actually used this call — no separate probe line to hunt for.
let probeScriptTransformApiPresent = false;
let probeCreateEncodedStreamsPresent = false;
let probeScriptTransformCtorCount = 0;
let probeAudioTransformSetCount = 0;
// WebAudio / decoded-output probe counters (journal #75) — where Meet's audio
// actually surfaces once it bypasses every encoded-frame API.
let probeAudioContextCount = 0;
let probeAudioWorkletNodeCount = 0;
let probeTrackGeneratorCount = 0;
let probeMediaStreamSourceCount = 0;
let probeMediaElementSrcObjectCount = 0;

/** Hook-layer state for the popup's debug report (see hook.content.ts). */
export function hookDebugState(): {
  liveTracks: number;
  teedAudioStreamCount: number;
  probe: {
    createEncodedStreamsPresent: boolean;
    scriptTransformApiPresent: boolean;
    scriptTransformCtorCount: number;
    audioTransformSetCount: number;
  };
  webaudio: {
    audioContexts: number;
    audioWorkletNodes: number;
    trackGenerators: number;
    mediaStreamSources: number;
    mediaElementSrcObjects: number;
  };
} {
  return {
    liveTracks: liveTracks().size,
    teedAudioStreamCount,
    probe: {
      createEncodedStreamsPresent: probeCreateEncodedStreamsPresent,
      scriptTransformApiPresent: probeScriptTransformApiPresent,
      scriptTransformCtorCount: probeScriptTransformCtorCount,
      audioTransformSetCount: probeAudioTransformSetCount,
    },
    webaudio: {
      audioContexts: probeAudioContextCount,
      audioWorkletNodes: probeAudioWorkletNodeCount,
      trackGenerators: probeTrackGeneratorCount,
      mediaStreamSources: probeMediaStreamSourceCount,
      mediaElementSrcObjects: probeMediaElementSrcObjectCount,
    },
  };
}

function noteMeetAudioTrackLive(): void {
  if (teeWatchdogArmed) return;
  teeWatchdogArmed = true;
  setTimeout(() => {
    if (teedAudioStreamCount > 0) return;
    console.error(
      "[ears][capture] ⚠ Meet audio capture is SILENT: audio tracks are live but Meet never called our " +
        "createEncodedStreams hook (0 streams tee'd). Meet likely changed its audio pipeline " +
        "(e.g. RTCRtpScriptTransform), or the receivers predate the hook. No participant audio " +
        "will be captured this call — reload the tab to re-arm. (journal #72)",
    );
    console.error(
      `[ears][probe] Meet audio API probe — createEncodedStreams:${probeCreateEncodedStreamsPresent ? "present" : "absent"}` +
        ` RTCRtpScriptTransform:${probeScriptTransformApiPresent ? "present" : "absent"}` +
        ` · scriptTransform ctor×${probeScriptTransformCtorCount}` +
        ` · audio receiver.transform set×${probeAudioTransformSetCount}` +
        " — the fix hooks whichever Meet actually used (journal #73)",
    );
  }, TEE_WATCHDOG_MS);
}

function installMeetEncodedAudioTee(): void {
  const proto = (window as unknown as { RTCRtpReceiver?: { prototype: EncodedStreamsReceiver } })
    .RTCRtpReceiver?.prototype;
  const native = proto?.createEncodedStreams;
  if (!proto || typeof native !== "function") {
    // MUST-NOT #13: surface this rather than silently reporting a working
    // capture that will actually record zero audio for every participant.
    console.error(
      "[ears][hook] RTCRtpReceiver.createEncodedStreams unavailable on meet.google.com — Meet audio capture will not work",
    );
    return;
  }

  proto.createEncodedStreams = function (this: EncodedStreamsReceiver, ...args: unknown[]): EncodedStreamsResult {
    const streams = (native as (...a: unknown[]) => EncodedStreamsResult).apply(this, args);
    const track = this.track;
    if (!track || track.kind !== "audio") return streams; // video: pass through untouched
    const [ours, theirs] = streams.readable.tee();
    teedAudioStreamCount += 1;
    void pumpEncodedAudio(track, ours);
    console.debug(`[ears][hook] tee'd encoded audio stream for track ${track.id} (${teedAudioStreamCount} total)`);
    return { readable: theirs, writable: streams.writable };
  };

  console.debug("[ears][hook] RTCRtpReceiver.createEncodedStreams hook installed (meet.google.com)");
}

// Temporary diagnostic (journal #73): Meet stopped calling createEncodedStreams,
// and the loaded modules (loadNetEqSabWrapper — SharedArrayBuffer WASM NetEQ)
// point at RTCRtpScriptTransform, the worker-based successor. This probe reports
// which encoded-frame API Meet actually uses on this build and logs where it
// routes audio — WITHOUT changing behaviour (every wrap passes straight through)
// so the real capture fix knows exactly what to hook. Remove once the fix lands.
function installMeetTransformProbe(): void {
  try {
    const w = window as unknown as {
      RTCRtpScriptTransform?: new (...a: unknown[]) => object;
      RTCRtpReceiver?: { prototype: object };
    };
    const proto = w.RTCRtpReceiver?.prototype;
    const hasScriptTransform = typeof w.RTCRtpScriptTransform === "function";
    const hasCreateEncodedStreams =
      !!proto && typeof (proto as { createEncodedStreams?: unknown }).createEncodedStreams === "function";
    const hasTransformAccessor = !!proto && !!Object.getOwnPropertyDescriptor(proto, "transform")?.set;
    probeScriptTransformApiPresent = hasScriptTransform;
    probeCreateEncodedStreamsPresent = hasCreateEncodedStreams;
    // Bracket-tree tag: filter `[ears][probe]` for just this, `[ears]` for all.
    console.debug(
      `[ears][probe] Meet audio APIs on this build — RTCRtpScriptTransform:${hasScriptTransform} ` +
        `receiver.transform:${hasTransformAccessor} createEncodedStreams:${hasCreateEncodedStreams}`,
    );

    // Log every RTCRtpScriptTransform construction — the options name Meet's
    // decode topology (which worker, what role). Pass-through constructor.
    if (hasScriptTransform) {
      const Native = w.RTCRtpScriptTransform!;
      const Wrapped = function (this: unknown, ...args: unknown[]): object {
        probeScriptTransformCtorCount += 1;
        console.debug("[ears][probe] new RTCRtpScriptTransform — options:", args[1]);
        return new Native(...args);
      } as unknown as new (...a: unknown[]) => object;
      Wrapped.prototype = Native.prototype;
      Object.setPrototypeOf(Wrapped, Native);
      w.RTCRtpScriptTransform = Wrapped;
    }

    // Log when Meet assigns a transform to an audio receiver — the exact seam
    // the real fix will tee encoded Opus from. Pass-through setter.
    if (proto) {
      const desc = Object.getOwnPropertyDescriptor(proto, "transform");
      if (desc?.set && desc.get) {
        const nativeSet = desc.set;
        const nativeGet = desc.get;
        Object.defineProperty(proto, "transform", {
          configurable: true,
          enumerable: desc.enumerable ?? true,
          get(): unknown {
            return nativeGet.call(this);
          },
          set(value: unknown): void {
            const kind = (this as { track?: MediaStreamTrack }).track?.kind ?? "?";
            if (kind === "audio") probeAudioTransformSetCount += 1;
            const name = (value as { constructor?: { name?: string } })?.constructor?.name ?? String(value);
            console.debug(`[ears][probe] receiver.transform set on a ${kind} receiver → ${name}`);
            nativeSet.call(this, value);
          },
        });
      }
    }
  } catch (err) {
    console.debug("[ears][probe] transform probe failed to install (non-fatal):", err);
  }
}

// WebAudio / decoded-output probe (journal #75). Meet uses no JS encoded-frame
// tap, so its decoded participant audio must surface later — through WebAudio
// nodes, a MediaStreamTrackGenerator, or a media element. This maps that graph
// (pass-through, diagnostic only) to answer the one question that decides
// feasibility: does Meet keep ONE node/generator PER participant (per-participant
// capture still possible), or mix everything into one (only blended audio left)?
// Filter the console by `[ears][probe][webaudio]`.
function installMeetWebAudioProbe(): void {
  try {
    const w = window as unknown as Record<string, unknown>;

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
    wrapCtor(
      "AudioWorkletNode",
      (a) => `processor="${String(a[1])}" ch=${(a[2] as { channelCount?: number })?.channelCount ?? "?"}`,
      () => (probeAudioWorkletNodeCount += 1),
    );
    // Audio generators are the leading candidate output of Meet's post-RTP
    // pipeline (2026-07-24 drift capture): register each constructed audio
    // generator (it IS a MediaStreamTrack) so a live session can reach the
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
        return native.apply(this, args);
      };
    }

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
//      capture session the track objects were unreachable (only their ids had
//      been logged), which blocked measuring them; this registry closes that gap.
//   2. Per-track energy fingerprints (`[ears][probe][webaudio] energy …`),
//      gated by the same `__earsDebugAudio` localStorage flag as audio-tap's
//      instrumentation: a throttled peak log per registered track, which
//      answers THE feasibility question — is the WebAudio-side audio still
//      per-participant (re-tappable), or already mixed?

interface WebAudioTrackRecord {
  track: MediaStreamTrack;
  via: string;
  registeredAt: string;
}
interface WebAudioTrackWindow extends Window {
  __earsWebAudioTracks?: Map<string, WebAudioTrackRecord>;
}

/** Native (unwrapped) createMediaStreamSource, captured by the probe so the
 * energy monitor never re-enters its own wrap. */
let nativeCreateMediaStreamSource: ((...a: unknown[]) => unknown) | null = null;
/** Lazy shared context for energy monitoring — one per page, only ever built
 * when the debug flag is on and a track gets monitored. */
let energyProbeContext: AudioContext | null = null;
let monitoredTrackCount = 0;
const ENERGY_PROBE_MAX_TRACKS = 16;
const ENERGY_PROBE_INTERVAL_MS = 5_000;

function webAudioTrackRegistry(): Map<string, WebAudioTrackRecord> {
  const g = window as unknown as WebAudioTrackWindow;
  if (!g.__earsWebAudioTracks) g.__earsWebAudioTracks = new Map();
  return g.__earsWebAudioTracks;
}

function registerWebAudioTrack(track: MediaStreamTrack, via: string): void {
  try {
    const registry = webAudioTrackRegistry();
    if (registry.has(track.id)) return;
    registry.set(track.id, { track, via, registeredAt: new Date().toISOString() });
  } catch {
    // diagnostic only — never throws into Meet's audio path
  }
}

function energyProbeEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugAudio") === "1";
  } catch {
    return false;
  }
}

/** Attach a throttled peak meter to `track`, logging only while it carries
 * signal. Diagnostic only, `__earsDebugAudio`-gated, capped at
 * ENERGY_PROBE_MAX_TRACKS so a tile-heavy call can't build unbounded graph. */
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
