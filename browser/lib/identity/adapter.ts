import type { ParticipantId, Platform } from "../protocol";

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
