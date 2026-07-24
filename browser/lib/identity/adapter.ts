import type { ParticipantId, Platform, RosterEntry } from "../protocol";

// Identity is the fragile, platform-specific part — quarantined behind this one
// interface. The capture spine (hook, tap, transport) never branches on platform.

export interface PlatformAdapter {
  readonly platform: Platform;
  /** Best-effort stable id for a remote track. null → caller assigns speaker-<n>. */
  identify(
    track: MediaStreamTrack,
    stream: MediaStream,
    transceiver: RTCRtpTransceiver,
  ): ParticipantId | null;
  /** Optional: human label for a participant id, for logs/UI. */
  displayName?(id: ParticipantId): string | undefined;
  /**
   * Optional: called by audio-tap.ts whenever a track's decoded audio crosses
   * into or out of "speaking" (peak over threshold). Adapters that don't use
   * this signal simply omit it — audio-tap.ts calls it unconditionally, best-
   * effort, and never lets an adapter throw back into the capture path.
   */
  onTrackSpeaking?(track: MediaStreamTrack, speaking: boolean): void;
  /**
   * Optional: register a callback for a later, asynchronous identity upgrade
   * — an id resolved after identify() already returned null (or a fallback)
   * for that track at +track time. At most one upgrade per track is expected;
   * audio-tap.ts restarts that track's pipeline as a new segment under the
   * upgraded id (see audio-tap.ts's handleIdentityUpgrade for why a rename-
   * in-place wasn't used).
   */
  onIdentify?(cb: (track: MediaStreamTrack, id: ParticipantId) => void): void;
  /**
   * Optional: register a callback for an identity that confirmed *after* its
   * track already ended — too late for onIdentify's pipeline restart. Carries
   * the dead track's id (the adapter may no longer hold the track object) and
   * the confirmed participant id. audio-tap.ts translates the track id back to
   * the fallback participant id it captured under and tells the daemon the two
   * are the same person, so already-recorded audio still gets a named speaker.
   */
  onRename?(cb: (trackId: string, id: ParticipantId) => void): void;
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
