// Why a receiver track that unmuted never gave the tap a frame.
//
// Live case (2026-10-14, Teams light client, meeting-ID join): `mainAudio-N`
// unmuted, was admitted, and produced no frame for 24 minutes while the far end
// was audible. The same track shape recorded fine on 2026-08-25. Without the
// receiver's stats the possible causes look identical from the tap:
//
//   - RTP audio arrives and decodes on this receiver → our frame source is broken
//   - RTP arrives but nothing decodes → an encoded transform is eating it
//   - RTP audio arrives on a *different* receiver → we tapped the wrong track
//   - no inbound RTP audio anywhere → the far end is not WebRTC media at all
//     (Zoom's DataChannel shape, see zoom-capture-is-one-sided)
//
// Read-only: getStats() and getReceivers() only. Never throws into capture.

/** One inbound-rtp audio stream, reduced to the counters that separate the cases. */
export interface InboundAudio {
  packetsReceived: number;
  bytesReceived: number;
  totalSamplesReceived: number;
  concealedSamples: number;
  audioLevel: number | null;
  codec: string | null;
}

export interface SilentDiagnosis {
  /** Live peer connections at diagnosis time. */
  peerConnections: number;
  /** A receiver whose `.track` is this track was found. */
  receiverFound: boolean;
  /** That receiver has an encoded transform (`receiver.transform`) set. */
  receiverTransform: boolean;
  /** This track's inbound-rtp stats, or null when the receiver has none. */
  self: InboundAudio | null;
  /** Inbound-rtp audio streams on all *other* receivers. */
  others: InboundAudio[];
  /** Media elements whose srcObject holds this track. */
  elementsWithTrack: number;
  trackMuted: boolean;
  trackReadyState: string;
  verdict: string;
}

/** The structural slices of the WebRTC objects read here, so tests can fake them. */
export interface ReceiverLike {
  track: { id: string } | null;
  transform?: unknown;
  getStats(): Promise<Iterable<[string, Record<string, unknown>]> | Map<string, Record<string, unknown>>>;
}
export interface PeerConnectionLike {
  getReceivers(): ReceiverLike[];
}
export interface TrackLike {
  id: string;
  muted: boolean;
  readyState: string;
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/** Inbound-rtp audio entries in one stats report, with their codec resolved. */
export function inboundAudioFromStats(entries: Iterable<[string, Record<string, unknown>]>): InboundAudio[] {
  const byId = new Map(entries);
  const out: InboundAudio[] = [];
  for (const s of byId.values()) {
    if (s.type !== "inbound-rtp" || s.kind !== "audio") continue;
    const codec = typeof s.codecId === "string" ? byId.get(s.codecId) : undefined;
    out.push({
      packetsReceived: num(s.packetsReceived),
      bytesReceived: num(s.bytesReceived),
      totalSamplesReceived: num(s.totalSamplesReceived),
      concealedSamples: num(s.concealedSamples),
      audioLevel: typeof s.audioLevel === "number" ? s.audioLevel : null,
      codec: typeof codec?.mimeType === "string" ? codec.mimeType : null,
    });
  }
  return out;
}

/** The one-line cause, from the counters alone. */
export function silentVerdict(d: Omit<SilentDiagnosis, "verdict">): string {
  const othersFlowing = d.others.some((o) => o.packetsReceived > 0);
  if (d.peerConnections === 0) return "no live peer connection";
  if (!d.receiverFound) {
    return othersFlowing
      ? "track is on no live receiver; RTP audio arrives on another receiver — tapped the wrong track"
      : "track is on no live receiver, and no inbound RTP audio anywhere";
  }
  const self = d.self;
  if (!self || self.packetsReceived === 0) {
    if (othersFlowing) return "no RTP on this receiver; RTP audio arrives on another receiver — tapped the wrong track";
    return "no inbound RTP audio on any receiver — far end is not delivered as WebRTC media (DataChannel/WebTransport?)";
  }
  if (self.totalSamplesReceived === 0) {
    return d.receiverTransform
      ? "RTP arrives but nothing decodes — receiver has an encoded transform consuming it"
      : "RTP arrives but nothing decodes";
  }
  return "receiver decodes audio but the tap got no frames — frame source is broken";
}

export async function diagnoseSilentTrack(
  track: TrackLike,
  pcs: Iterable<PeerConnectionLike>,
  elements: Iterable<{ srcObject: unknown }>,
): Promise<SilentDiagnosis> {
  let peerConnections = 0;
  let receiverFound = false;
  let receiverTransform = false;
  let self: InboundAudio | null = null;
  const others: InboundAudio[] = [];

  for (const pc of pcs) {
    peerConnections++;
    for (const r of pc.getReceivers()) {
      let stats: InboundAudio[];
      try {
        const report = await r.getStats();
        stats = inboundAudioFromStats(report instanceof Map ? report.entries() : report);
      } catch {
        stats = [];
      }
      if (r.track?.id === track.id) {
        receiverFound = true;
        receiverTransform = r.transform != null;
        self = stats[0] ?? null;
      } else {
        others.push(...stats);
      }
    }
  }

  let elementsWithTrack = 0;
  for (const el of elements) {
    const stream = el.srcObject as { getTracks?: () => { id: string }[] } | null;
    if (stream?.getTracks?.().some((t) => t.id === track.id)) elementsWithTrack++;
  }

  const partial = {
    peerConnections,
    receiverFound,
    receiverTransform,
    self,
    others,
    elementsWithTrack,
    trackMuted: track.muted,
    trackReadyState: track.readyState,
  };
  return { ...partial, verdict: silentVerdict(partial) };
}
