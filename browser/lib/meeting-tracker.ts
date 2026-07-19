import { sourceLabel, type ParticipantId, type Platform } from "./protocol";

// Background-side meeting lifecycle, parallel to session-state.ts's
// SessionTracker (which owns the worker keepalive; this owns the daemon-facing
// meeting/session marking). Keyed by externalMeetingId, one record per live
// meeting:
//
//   meeting-started  → meeting.resolve (daemon-owned UUID) → session.open with
//                      the participant sources already confirmed open on earsd,
//                      slug = the meeting UUID, trigger = browser-extension
//   stream opened    → session.add_source (sources that appear mid-call would
//                      otherwise be excluded from that session's transcription)
//   pause            → session.close; resume → a fresh session.open under the
//                      same meeting UUID (audio ingest is untouched — sessions
//                      are metadata over the ring buffer, never a capture gate)
//   meeting-ended /  → session.close (+ a time-boxed "transcribing" badge
//   port gone /        state — optimistic, real transcription progress is not
//   last leaver        observable today; see the plan's scope note)
//
// Re-entry needs no dedup here: meeting.resolve is a persisted daemon-side
// lookup, so rejoining resolves to the SAME meeting UUID and simply opens a
// second, distinct session sharing it — exactly the wanted semantics.

/** What the meeting layer contributes to the popup badge. */
export type MeetingState = "idle" | "recording" | "paused" | "transcribing";

/** The full badge vocabulary: transport status (which wins while there's a
 * connection problem) plus the meeting states above. */
export type BadgeState =
  | "disconnected"
  | "connecting"
  | "connected"
  | "recording"
  | "paused"
  | "transcribing";

/** The control-plane surface MeetingTracker consumes — ControlSocket
 * (control-transport.ts) in production, a recording fake in tests. */
export interface MeetingControl {
  meetingResolve(platform: Platform, externalMeetingId: string): Promise<string>;
  sessionOpen(sources: readonly string[], slug: string): Promise<string>;
  sessionClose(id: string): Promise<void>;
  sessionAddSource(id: string, source: string): Promise<void>;
}

/** Injectable timers so tests control the "transcribing" hold window. */
export interface TimersLike {
  set(fn: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

/** How long the optimistic "transcribing" badge state holds after a meeting
 * ends before falling back to idle/connected. */
export const TRANSCRIBING_HOLD_MS = 8_000;

interface MeetingRecord {
  portId: string;
  platform: Platform;
  externalMeetingId: string;
  /** Daemon-assigned meeting UUID, once meeting.resolve lands. */
  meetingId?: string;
  /** The currently-open daemon session, if any (absent while paused). */
  sessionId?: string;
  /** A session.open is in flight. */
  opening: boolean;
  paused: boolean;
  ended: boolean;
  /** Source labels confirmed open on earsd (ingest.open succeeded). */
  openSources: Set<string>;
  /** Source labels already on the current session's descriptor. */
  sessionSources: Set<string>;
  participants: Set<ParticipantId>;
}

export class MeetingTracker {
  private readonly meetings = new Map<string, MeetingRecord>();
  private transcribing = false;
  private transcribingHandle: unknown;
  private lastState: MeetingState = "idle";

  constructor(
    private readonly control: MeetingControl,
    private readonly onState: (s: MeetingState) => void = () => {},
    private readonly timers: TimersLike = {
      set: (fn, ms) => setTimeout(fn, ms),
      clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
    },
    private readonly transcribingHoldMs = TRANSCRIBING_HOLD_MS,
  ) {}

  get state(): MeetingState {
    for (const m of this.meetings.values()) {
      if (m.ended) continue;
      return m.paused ? "paused" : "recording";
    }
    return this.transcribing ? "transcribing" : "idle";
  }

  /** True while any meeting is live (drives the popup's pause-toggle row). */
  get meetingActive(): boolean {
    for (const m of this.meetings.values()) if (!m.ended) return true;
    return false;
  }

  get paused(): boolean {
    return this.state === "paused";
  }

  /** meeting-started from a tab: resolve the daemon meeting UUID, then open a
   * session as soon as at least one participant source is open on earsd. */
  meetingStarted(portId: string, platform: Platform, externalMeetingId: string): void {
    const existing = this.meetings.get(externalMeetingId);
    if (existing && !existing.ended) return; // duplicate start — already tracked
    const record: MeetingRecord = {
      portId,
      platform,
      externalMeetingId,
      opening: false,
      paused: false,
      ended: false,
      openSources: new Set(),
      sessionSources: new Set(),
      participants: new Set(),
    };
    this.meetings.set(externalMeetingId, record);
    this.emitState();

    void this.control
      .meetingResolve(platform, externalMeetingId)
      .then((meetingId) => {
        if (record.ended) return;
        record.meetingId = meetingId;
        console.log(`[ears] meeting ${externalMeetingId} resolved to ${meetingId}`);
        void this.maybeOpenSession(record);
      })
      .catch((err) => {
        console.warn(`[ears] meeting.resolve failed for ${externalMeetingId}:`, err);
      });
  }

  /** meeting-ended from the tab (capture toggled off, call teardown). */
  meetingEnded(externalMeetingId: string): void {
    const record = this.meetings.get(externalMeetingId);
    if (record) this.endMeeting(record);
  }

  /** An ingest stream for this participant is confirmed open on earsd, so its
   * source can be named on a session. */
  streamOpened(portId: string, platform: Platform, participantId: ParticipantId): void {
    const record = this.findRecord(portId, platform);
    if (!record) return;
    record.participants.add(participantId);
    const label = sourceLabel(platform, participantId);
    if (record.openSources.has(label)) return;
    record.openSources.add(label);

    if (record.sessionId && !record.sessionSources.has(label)) {
      record.sessionSources.add(label);
      const sessionId = record.sessionId;
      void this.control.sessionAddSource(sessionId, label).catch((err) => {
        console.warn(`[ears] session.add_source(${label}) failed:`, err);
      });
      return;
    }
    void this.maybeOpenSession(record);
  }

  /** A participant left; when the last one goes, the call is over. */
  participantLeft(portId: string, participantId: ParticipantId): void {
    for (const record of this.meetings.values()) {
      if (record.portId !== portId || record.ended) continue;
      if (!record.participants.delete(participantId)) continue;
      record.openSources.delete(sourceLabel(record.platform, participantId));
      if (record.participants.size === 0) this.endMeeting(record);
    }
  }

  /** The tab's port went away (closed / navigated) — end its meetings. */
  portDisconnected(portId: string): void {
    for (const record of this.meetings.values()) {
      if (record.portId === portId && !record.ended) this.endMeeting(record);
    }
  }

  /**
   * The popup's pause toggle. Pause = close the current session (the paused
   * span is simply never covered by any session, so transcription never sees
   * it); resume = open a fresh session under the same meeting UUID. Capture
   * and PCM ingest are untouched throughout.
   */
  async setPaused(paused: boolean): Promise<void> {
    for (const record of this.meetings.values()) {
      if (record.ended || record.paused === paused) continue;
      record.paused = paused;
      if (paused) {
        const sessionId = record.sessionId;
        record.sessionId = undefined;
        record.sessionSources = new Set();
        if (sessionId) {
          try {
            await this.control.sessionClose(sessionId);
          } catch (err) {
            console.warn(`[ears] session.close(${sessionId}) on pause failed:`, err);
          }
        }
      } else {
        await this.maybeOpenSession(record);
      }
    }
    this.emitState();
  }

  private findRecord(portId: string, platform: Platform): MeetingRecord | undefined {
    for (const record of this.meetings.values()) {
      if (!record.ended && record.portId === portId && record.platform === platform) return record;
    }
    return undefined;
  }

  private async maybeOpenSession(record: MeetingRecord): Promise<void> {
    if (
      !record.meetingId ||
      record.sessionId ||
      record.opening ||
      record.paused ||
      record.ended ||
      record.openSources.size === 0
    ) {
      return;
    }
    record.opening = true;
    const sources = [...record.openSources];
    try {
      const sessionId = await this.control.sessionOpen(sources, record.meetingId);
      record.opening = false;
      if (record.ended || record.paused) {
        // Ended/paused while the open was in flight — close it right back.
        void this.control.sessionClose(sessionId).catch(() => {});
        return;
      }
      record.sessionId = sessionId;
      record.sessionSources = new Set(sources);
      console.log(`[ears] session ${sessionId} opened for meeting ${record.meetingId}`);
      // Sources that opened while session.open was in flight still need adding.
      for (const label of record.openSources) {
        if (!record.sessionSources.has(label)) {
          record.sessionSources.add(label);
          void this.control.sessionAddSource(sessionId, label).catch((err) => {
            console.warn(`[ears] session.add_source(${label}) failed:`, err);
          });
        }
      }
    } catch (err) {
      record.opening = false;
      console.warn(`[ears] session.open for meeting ${record.meetingId} failed:`, err);
    }
    this.emitState();
  }

  private endMeeting(record: MeetingRecord): void {
    if (record.ended) return;
    record.ended = true;
    this.meetings.delete(record.externalMeetingId);
    const sessionId = record.sessionId;
    record.sessionId = undefined;
    if (sessionId) {
      void this.control.sessionClose(sessionId).catch((err) => {
        console.warn(`[ears] session.close(${sessionId}) failed:`, err);
      });
      this.startTranscribingHold();
    }
    this.emitState();
  }

  /** Optimistic, time-boxed "transcribing" — real progress isn't observable
   * today (the transcribe process has no channel back to the daemon). */
  private startTranscribingHold(): void {
    this.transcribing = true;
    if (this.transcribingHandle) this.timers.clear(this.transcribingHandle);
    this.transcribingHandle = this.timers.set(() => {
      this.transcribing = false;
      this.transcribingHandle = undefined;
      this.emitState();
    }, this.transcribingHoldMs);
  }

  private emitState(): void {
    const state = this.state;
    if (state === this.lastState) return;
    this.lastState = state;
    this.onState(state);
  }
}
