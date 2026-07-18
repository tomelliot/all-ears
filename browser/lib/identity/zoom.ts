import { registerAdapter, type PlatformAdapter } from "./adapter";
import type { ParticipantId } from "../protocol";

// Zoom identity (Phase 5). Strongest of the three: the participant id is
// intrinsic to the track, parsed from the MSID/stream id — stable across
// mute/unmute and re-subscription, no active-speaker guessing.
//
// Zoom encodes the sender's node id in the stream id as leading digits before
// a "+", with "+CS+" marking the per-participant audio stream. The low 10 bits
// vary per stream/segment, so masking them off (`>> 10 << 10`) yields the
// stable per-participant id (attendee-labs' documented algorithm).

/**
 * Parse a stable Zoom participant id from a stream/MSID, or null if the id
 * isn't a per-participant Zoom audio stream. Exported for unit tests.
 */
export function parseZoomParticipantId(msid: string | null | undefined): ParticipantId | null {
  if (!msid) return null;
  let decoded: string;
  try {
    decoded = decodeURIComponent(msid);
  } catch {
    decoded = msid;
  }
  // Gate: only the per-participant audio streams carry the "+CS+" marker.
  if (!decoded.includes("+CS+")) return null;
  const m = decoded.match(/^(\d+)\+/);
  if (!m) return null;
  const node = Number(m[1]);
  if (!Number.isFinite(node)) return null;
  // Mask the low 10 bits (per-stream churn) to get the stable participant node.
  const participantNode = (node >> 10) << 10;
  return `zoom-${participantNode}`;
}

class ZoomAdapter implements PlatformAdapter {
  readonly platform = "zoom" as const;

  identify(track: MediaStreamTrack, stream: MediaStream): ParticipantId | null {
    // The MSID rides the stream id; fall back to the track's own id.
    return parseZoomParticipantId(stream.id) ?? parseZoomParticipantId(track.id);
  }
}

registerAdapter((host) => host.endsWith("zoom.us"), () => new ZoomAdapter());
