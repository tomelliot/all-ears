// Pure temporal correlator: pairs a track's decoded-audio speaking onsets
// with a Meet collections device id's speaking onsets (journal #50 — the two
// land within tens of milliseconds of each other, in either order). No DOM,
// no WebRTC, no wall-clock reads — callers pass timestamps in, which keeps
// this a tier-0 unit per docs/engineering-practices.md (deterministic, no
// Date.now() inside).
//
// Matching rule (implementation prompt Task 2): when a device onset and
// exactly one live track's audio onset fall within the correlation window of
// each other, that pairing is a candidate. Ambiguous windows (zero or
// multiple candidates) are left unconsumed — the events "expire" via history
// pruning rather than being forced into a guess.
//
// Confidence rule (Task 4): a pairing must repeat across several separate
// turns before it's trusted. A single coincidence is not enough — MeetAdapter
// checks `confirmations` against its threshold before acting on a match.

export interface CorrelatorMatch {
  trackKey: string;
  deviceId: string;
  /** Consecutive turns this exact (trackKey, deviceId) pairing has matched. */
  confirmations: number;
}

interface OnsetEvent {
  key: string;
  at: number;
}

const DEFAULT_WINDOW_MS = 200;
const DEFAULT_HISTORY_MS = 3000;

export class SpeakingCorrelator {
  private audioOnsets: OnsetEvent[] = [];
  private deviceOnsets: OnsetEvent[] = [];
  // deviceId → the one candidate track currently accumulating confirmations.
  // A pairing that stops repeating (a different track matches the same
  // deviceId later) resets to the new candidate rather than averaging across
  // both — conservative, since a stable participant shouldn't switch tracks
  // while its old one is still live.
  private candidates = new Map<string, { trackKey: string; count: number }>();

  constructor(
    private readonly windowMs: number = DEFAULT_WINDOW_MS,
    private readonly historyMs: number = DEFAULT_HISTORY_MS,
  ) {}

  /** Record a track's audio crossing into "speaking" at `at` (caller-supplied ms timestamp). */
  recordAudioOnset(trackKey: string, at: number): CorrelatorMatch | null {
    this.prune(at);
    this.audioOnsets.push({ key: trackKey, at });
    return this.tryMatch();
  }

  /** Record a device id's collections-channel turn-start at `at`. */
  recordDeviceOnset(deviceId: string, at: number): CorrelatorMatch | null {
    this.prune(at);
    this.deviceOnsets.push({ key: deviceId, at });
    return this.tryMatch();
  }

  private prune(now: number): void {
    this.audioOnsets = this.audioOnsets.filter((e) => now - e.at <= this.historyMs);
    this.deviceOnsets = this.deviceOnsets.filter((e) => now - e.at <= this.historyMs);
  }

  private tryMatch(): CorrelatorMatch | null {
    for (const device of this.deviceOnsets) {
      const candidates = this.audioOnsets.filter((a) => Math.abs(a.at - device.at) <= this.windowMs);
      if (candidates.length !== 1) continue; // no signal, or ambiguous — leave both pending
      const audio = candidates[0]!;
      this.deviceOnsets = this.deviceOnsets.filter((e) => e !== device);
      this.audioOnsets = this.audioOnsets.filter((e) => e !== audio);
      return this.confirm(audio.key, device.key);
    }
    return null;
  }

  private confirm(trackKey: string, deviceId: string): CorrelatorMatch {
    const existing = this.candidates.get(deviceId);
    const count = existing && existing.trackKey === trackKey ? existing.count + 1 : 1;
    this.candidates.set(deviceId, { trackKey, count });
    return { trackKey, deviceId, confirmations: count };
  }
}
