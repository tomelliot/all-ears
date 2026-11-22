import type { Platform, RosterEntry } from "../protocol";

// Identity is the fragile, platform-specific part — quarantined behind this one
// interface. The capture spine (hook, tap, transport) never branches on platform.

/**
 * The platform's own stable id for a participant (a Meet device path, a Zoom
 * node id). Adapters only ever speak platform ids: the track-scoped source
 * handles (`t<n>`) are minted by the capture layer (audio-tap.ts), never by
 * an adapter, and a platform id never becomes a source id — it reaches the
 * daemon as an attendee upsert linking the handle's source (R3).
 */
export type PlatformParticipantId = string;

export interface PlatformAdapter {
  readonly platform: Platform;
  /** Best-effort platform id for a remote track at admission. null → the
   * source simply stays anonymous until (unless) a later identity confirms;
   * audio is captured under the track handle either way. */
  identify(track: MediaStreamTrack, stream: MediaStream): PlatformParticipantId | null;
  /** Optional: human label for a participant id, for logs/UI. */
  displayName?(id: PlatformParticipantId): string | undefined;
  /**
   * Optional: called by audio-tap.ts whenever a track's decoded audio crosses
   * into or out of "speaking" (peak over threshold). Adapters that don't use
   * this signal simply omit it — audio-tap.ts calls it unconditionally, best-
   * effort, and never lets an adapter throw back into the capture path.
   */
  onTrackSpeaking?(track: MediaStreamTrack, speaking: boolean): void;
  /**
   * Optional: called by audio-tap.ts when a remote track fires its "unmute"
   * event — the platform resumed sending RTP for it. On Meet this pairs with
   * the collections channel's per-device mic-open edge (the only per-device
   * event that channel still carries — see meet-collections.ts, 2026-07-24
   * re-interpretation) to correlate a track to a device id. Same best-effort
   * contract as onTrackSpeaking.
   */
  onTrackUnmute?(track: MediaStreamTrack): void;
  /**
   * Optional: a platform-DOM speaking indicator fired for `deviceId` at `at`
   * (ms). On Meet this is the tile speaking-ring burst (meet-speaking-dom.ts)
   * — the only per-turn per-device signal on current builds — and pairs with
   * decoded-audio onsets to correlate a track to a device id. Same best-effort
   * contract as onTrackSpeaking.
   */
  onDeviceSpeaking?(deviceId: string, at: number): void;
  /**
   * Optional: register a callback for a platform identity that confirmed
   * asynchronously for a captured track (Meet's speaking-onset correlation).
   * Carries the track id rather than the track object because nothing needs
   * the object any more: the pipeline is never restarted for an identity —
   * audio-tap.ts translates the track id to the source handle its audio is
   * recorded under and forwards an attendee upsert linking the two
   * (`participant-identified`). May fire at any point in the track's life,
   * including after it ended.
   */
  onIdentity?(cb: (trackId: string, id: PlatformParticipantId) => void): void;
  /**
   * Optional: register a callback for a captured track that now carries a
   * different person than the one it was identified as — a Jitsi
   * SSRC-rewriting slot the bridge gave to a new sender. A source binds one
   * person (the daemon's RosterReconciler keeps the first claim on a source),
   * so audio-tap.ts ends the track's current source and continues the same
   * live pipeline under a fresh handle, then calls `identify()` again to name
   * the new sender. Same best-effort contract as onTrackSpeaking.
   */
  onTrackReassigned?(cb: (trackId: string) => void): void;
  /**
   * Optional: register a callback for batches of resolved participant identities
   * (id → display name) read from the platform's own roster/UI, independent of
   * whether each id has been tied to a captured track. audio-tap.ts forwards
   * these to the daemon so names land on the meeting roster even for
   * participants whose track never correlated to a stable id (issue #23). Only
   * newly-resolved or changed entries are delivered (the adapter dedupes).
   */
  onRoster?(cb: (entries: RosterEntry[]) => void): void;
  /**
   * Optional: prompt the adapter to re-scan its identity source (e.g. Meet's
   * participant tiles) and emit any newly-resolved names via onRoster. Called
   * periodically by the capture reconciler so the roster is harvested even for
   * participants who never trigger identify()/onTrackSpeaking (a silent
   * participant whose name only lives in the DOM).
   */
  pollIdentities?(): void;
  /** Optional teardown of observers. */
  dispose?(): void;
}

/** Adapters register here; selectAdapter picks by hostname. */
type AdapterFactory = () => PlatformAdapter;
const registry: Array<{ match: (host: string) => boolean; make: AdapterFactory }> = [];

export function registerAdapter(match: (host: string) => boolean, make: AdapterFactory): void {
  registry.push({ match, make });
}

/**
 * Select the adapter for a hostname. Returns null on an unknown host — the
 * caller then uses the universal speaker-<n> fallback, so audio still flows.
 */
export function selectAdapter(host: string): PlatformAdapter | null {
  const entry = registry.find((r) => r.match(host));
  return entry ? entry.make() : null;
}
