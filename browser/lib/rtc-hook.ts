import { claimInstall } from "./epoch";

// The RTCPeerConnection constructor hook — the singleton part of the capture
// spine, installed exactly once per page realm (claimInstall guards it).
//
// Two things live on `window` so they survive across re-injected epochs, which
// each load a fresh module instance but share the one realm:
//
//   __earsOnTrack     the current epoch's track sink (audio-tap installs it)
//   __earsLiveTracks  our own registry of live remote audio tracks, so a new
//                     epoch can replay them and take over without dropping audio
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

interface HookWindow extends Window {
  __earsOnTrack?: TrackSink;
  __earsLiveTracks?: Map<MediaStreamTrack, TrackRecord>;
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
  hw().__earsOnTrack?.(e.track, stream, e.transceiver);
}

function onPeerConnection(pc: RTCPeerConnection): void {
  pc.addEventListener("track", dispatchTrack);

  // TEMP DIAGNOSTIC: does the browser actually receive+decode audio RTP on this
  // connection? audioLevel/totalAudioEnergy > 0 ⇒ standard decode (tappable);
  // absent/zero while someone speaks ⇒ Meet decodes encoded frames itself.
  let ticks = 0;
  const iv = setInterval(() => {
    void pc
      .getStats()
      .then((stats) => {
        stats.forEach((r: { type: string; kind?: string } & Record<string, unknown>) => {
          if (r.type === "inbound-rtp" && r.kind === "audio") {
            console.log(
              `[ears/diag] inbound-audio bytes=${r.bytesReceived} packets=${r.packetsReceived} audioLevel=${r.audioLevel} totalEnergy=${r.totalAudioEnergy} concealed=${r.concealedSamples}`,
            );
          }
        });
      })
      .catch(() => {});
    if (++ticks > 12) clearInterval(iv);
  }, 2000);

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

  console.log("[ears] RTCPeerConnection hook installed");
}
