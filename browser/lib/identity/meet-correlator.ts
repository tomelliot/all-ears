// Pure temporal correlator: pairs a track's decoded-audio speaking onsets
// with a Meet collections device id's speaking onsets (journal #50 — the two
// land within tens of milliseconds of each other, in either order). No DOM,
// no WebRTC, no wall-clock reads — callers pass timestamps in, which keeps
// this a tier-0 unit per docs/engineering-practices.md (deterministic, no
// Date.now() inside).
//
// Matching rule (implementation prompt Task 2): when a device onset and one
// live track's audio onset(s) fall within the correlation window of each
// other, that pairing is a candidate. Ambiguity is judged by *distinct
// tracks*, not raw event count: a single track routinely emits an onset
// cluster (3+ speaking-starts within ~300ms, observed live) for one spoken
// turn, and all of those are the same unambiguous speaker — they must not
// count as competing candidates. Only when onsets from two *different* tracks
// fall in the window is the pairing genuinely ambiguous and left unconsumed —
// those events "expire" via history pruning rather than being forced into a
// guess. A leading-edge debounce further collapses each track's onset cluster
// so the burst can't dominate the history window during overlapping talk.
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
// Leading-edge debounce for a single track's audio onsets. The hook's speech
// detector emits rapid onset clusters (3+ within ~300ms) at the start of one
// spoken turn; feeding every one to the correlator inflates the history window
// and, during overlapping talk, raises the chance a *second* track's onset
// coincides with the burst. Ignoring same-track onsets within 1s of that
// track's last accepted onset collapses each turn to a single onset without
// dropping a genuinely new turn (turns are seconds apart).
const DEFAULT_DEBOUNCE_MS = 1000;

export class SpeakingCorrelator {
  private audioOnsets: OnsetEvent[] = [];
  private deviceOnsets: OnsetEvent[] = [];
  // deviceId → the one candidate track currently accumulating confirmations.
  // A pairing that stops repeating (a different track matches the same
  // deviceId later) resets to the new candidate rather than averaging across
  // both — conservative, since a stable participant shouldn't switch tracks
  // while its old one is still live.
  private candidates = new Map<string, { trackKey: string; count: number }>();
  /** trackKey → its last *accepted* (non-debounced) audio-onset timestamp. */
  private lastAudioOnset = new Map<string, number>();

  constructor(
    private readonly windowMs: number = DEFAULT_WINDOW_MS,
    private readonly historyMs: number = DEFAULT_HISTORY_MS,
    private readonly debounceMs: number = DEFAULT_DEBOUNCE_MS,
  ) {}

  /** Record a track's audio crossing into "speaking" at `at` (caller-supplied ms timestamp). */
  recordAudioOnset(trackKey: string, at: number): CorrelatorMatch | null {
    const prev = this.lastAudioOnset.get(trackKey);
    if (prev !== undefined && at - prev < this.debounceMs) return null; // same-track cluster — collapse
    this.lastAudioOnset.set(trackKey, at);
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
      if (candidates.length === 0) continue; // no signal — leave the device onset pending
      // Ambiguity is per-track, not per-event: N onsets from one track are one
      // speaker (an onset cluster), so still an unambiguous match. Two or more
      // *distinct* tracks in the window is the only genuinely ambiguous case.
      const trackKey = candidates[0]!.key;
      if (candidates.some((c) => c.key !== trackKey)) continue; // 2+ tracks — leave both pending
      this.deviceOnsets = this.deviceOnsets.filter((e) => e !== device);
      // Consume every matched onset from that track (the whole cluster) so a
      // later device onset can't re-pair with a leftover from this turn.
      const matched = new Set(candidates);
      this.audioOnsets = this.audioOnsets.filter((e) => !matched.has(e));
      return this.confirm(trackKey, device.key);
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
