import {
  sourceLabel,
  type AttendeeUpsert,
  type EventFrame,
  type MeetingWire,
  type ParticipantId,
  type Platform,
  type RosterEntry,
  type SnapshotWire,
} from "./protocol";

// Background-side meeting signal forwarder. The daemon owns the meeting
// state machine in protocol v2 (docs/specs/control-protocol.md);
// this class just translates what the tabs' DOM layers observe into the
// daemon's meeting verbs:
//
//   meeting-started      → meeting.start (idempotent on platform+external id)
//   participant joined   → meeting.attendee upsert (display name)
//   ingest stream opened → meeting.attendee upsert (source link)
//   participant left     → meeting.attendee upsert (left timestamp)
//   popup pause toggle   → meeting.pause / meeting.resume (marks, never capture)
//   meeting-ended / port → meeting.end
//   job events           → the "transcribing" badge (real pipeline state,
//                          not a guessed timer)
//
// Recovery is re-declaration: after service-worker eviction or a daemon
// restart, the transport's onReady fires with a fresh snapshot and this
// tracker re-declares every meeting its records (rebuilt from the DOM's
// signals) say are live — meeting.start converges instead of duplicating.

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
  meetingStart(platform: Platform, externalMeetingId: string): Promise<MeetingWire>;
  meetingEnd(meeting: string): Promise<MeetingWire>;
  meetingPause(meeting: string): Promise<MeetingWire>;
  meetingResume(meeting: string): Promise<MeetingWire>;
  meetingAttendee(meeting: string, attendee: AttendeeUpsert): Promise<MeetingWire>;
}

/**
 * A participant/stream signal that arrived on a port before its meeting.start
 * was declared (the linkage race — the DOM's participant-joined / ingest
 * stream-opened events can beat the Meet meeting-id resolution). Buffered
 * per-port and replayed onto the record once meetingStarted lands, instead of
 * being silently dropped (which stranded the meeting with no attendees and no
 * browser:* source, so the daemon never classified it as a browser meeting).
 */
type PendingPortEvent =
  | { kind: "joined"; platform: Platform; participantId: ParticipantId; displayName?: string }
  | { kind: "stream"; platform: Platform; participantId: ParticipantId }
  | { kind: "roster"; platform: Platform; entries: RosterEntry[] }
  | { kind: "renamed"; platform: Platform; fromId: ParticipantId; toId: ParticipantId };

// Guard against unbounded growth if a port never declares a meeting (e.g. a
// non-meeting tab that still opens a pcm port). Far above any real pre-declare
// burst; oldest events drop first.
const MAX_PENDING_PER_PORT = 256;

interface MeetingRecord {
  portId: string;
  platform: Platform;
  externalMeetingId: string;
  /** Daemon-assigned meeting UUID, once meeting.start lands. */
  meetingId?: string;
  /** A meeting.start is in flight. */
  starting: boolean;
  paused: boolean;
  ended: boolean;
  /** Attendee upserts observed before the meeting id was known. */
  pendingAttendees: AttendeeUpsert[];
  participants: Set<ParticipantId>;
}

export class MeetingTracker {
  private readonly meetings = new Map<string, MeetingRecord>();
  /** Live transcribe jobs, from `job` telemetry events. */
  private readonly activeJobs = new Set<string>();
  /** portId → signals seen before that port's meeting was declared. Drained
   * by meetingStarted, dropped by portDisconnected. */
  private readonly pendingByPort = new Map<string, PendingPortEvent[]>();
  private lastState: MeetingState = "idle";

  constructor(
    private readonly control: MeetingControl,
    private readonly onState: (s: MeetingState) => void = () => {},
    /** Injectable wall clock for the roster's `left` timestamps. */
    private readonly nowISO: () => string = () => new Date().toISOString(),
  ) {}

  get state(): MeetingState {
    for (const m of this.meetings.values()) {
      if (m.ended) continue;
      return m.paused ? "paused" : "recording";
    }
    return this.activeJobs.size > 0 ? "transcribing" : "idle";
  }

  /** True while any meeting is live (drives the popup's pause-toggle row). */
  get meetingActive(): boolean {
    for (const m of this.meetings.values()) if (!m.ended) return true;
    return false;
  }

  get paused(): boolean {
    return this.state === "paused";
  }

  /** The live meeting's external id for this tab's port — the membership tag
   * the transport stamps on ingest.open, so the daemon can link the source
   * into the meeting itself (grace-policy safety net for lost worker state). */
  externalIdFor(portId: string, platform: Platform): string | undefined {
    return this.findRecord(portId, platform)?.externalMeetingId;
  }

  /** meeting-started from a tab: declare it to the daemon. */
  meetingStarted(portId: string, platform: Platform, externalMeetingId: string): void {
    const existing = this.meetings.get(externalMeetingId);
    if (existing && !existing.ended) return; // duplicate start — already tracked
    const record: MeetingRecord = {
      portId,
      platform,
      externalMeetingId,
      starting: false,
      paused: false,
      ended: false,
      pendingAttendees: [],
      participants: new Set(),
    };
    this.meetings.set(externalMeetingId, record);
    this.declare(record);
    this.drainPending(portId, record);
    this.emitState();
  }

  /** meeting-ended from the tab (capture toggled off, call teardown). */
  meetingEnded(externalMeetingId: string): void {
    const record = this.meetings.get(externalMeetingId);
    if (record) this.endMeeting(record);
  }

  /** A participant's identity (with display name, when known) from the
   * tab's DOM layer — upserted onto the daemon meeting's roster. */
  participantJoined(
    portId: string,
    platform: Platform,
    participantId: ParticipantId,
    displayName?: string,
  ): void {
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "joined", platform, participantId, displayName });
      return;
    }
    this.applyJoined(record, participantId, displayName);
  }

  /**
   * Resolved participant names from the platform roster (id → display name),
   * independent of capture. Upserts each onto the daemon meeting's attendee
   * roster so names land even for a participant whose track never correlated to
   * this id — unlike participantJoined, a roster entry is identity only and does
   * NOT enrol the id as a capture participant (it must not keep the meeting
   * alive or gate its end). See issue #23.
   */
  rosterUpdate(portId: string, platform: Platform, entries: RosterEntry[]): void {
    if (entries.length === 0) return;
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "roster", platform, entries });
      return;
    }
    this.applyRoster(record, entries);
  }

  /**
   * A late identity join from the tab (see protocol.ts "participant-renamed"):
   * `fromId`'s track died before its identity upgrade could restart the
   * pipeline, so the audio already recorded stays under `fromId`'s source.
   * Attach that source to the *named* `toId` attendee so name and source land
   * on one roster row — which is what the transcript's speaker-name map keys
   * on. Identity only: `toId` is not enrolled as a capture participant.
   */
  participantRenamed(
    portId: string,
    platform: Platform,
    fromId: ParticipantId,
    toId: ParticipantId,
  ): void {
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "renamed", platform, fromId, toId });
      return;
    }
    this.applyRename(record, platform, fromId, toId);
  }

  /** An ingest stream for this participant is confirmed open on earsd — link
   * the attendee to their per-participant source (which downstream feeds the
   * transcript's speaker-name map). */
  streamOpened(portId: string, platform: Platform, participantId: ParticipantId): void {
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "stream", platform, participantId });
      return;
    }
    this.applyStream(record, platform, participantId);
  }

  private applyJoined(record: MeetingRecord, participantId: ParticipantId, displayName?: string): void {
    record.participants.add(participantId);
    this.upsertAttendee(record, {
      id: participantId,
      ...(displayName ? { display_name: displayName } : {}),
    });
  }

  private applyStream(record: MeetingRecord, platform: Platform, participantId: ParticipantId): void {
    record.participants.add(participantId);
    this.upsertAttendee(record, {
      id: participantId,
      source: sourceLabel(platform, participantId),
    });
  }

  private applyRename(
    record: MeetingRecord,
    platform: Platform,
    fromId: ParticipantId,
    toId: ParticipantId,
  ): void {
    this.upsertAttendee(record, {
      id: toId,
      source: sourceLabel(platform, fromId),
    });
  }

  private applyRoster(record: MeetingRecord, entries: RosterEntry[]): void {
    for (const entry of entries) {
      if (!entry.displayName) continue; // never upsert an empty name (issue #23)
      // Identity only — deliberately NOT added to record.participants, so a
      // named-but-never-captured attendee can't keep the meeting from ending.
      this.upsertAttendee(record, { id: entry.participantId, display_name: entry.displayName });
    }
  }

  private enqueuePending(portId: string, event: PendingPortEvent): void {
    const queue = this.pendingByPort.get(portId) ?? [];
    queue.push(event);
    while (queue.length > MAX_PENDING_PER_PORT) queue.shift();
    this.pendingByPort.set(portId, queue);
  }

  /** Replay signals buffered before this port's meeting was declared. */
  private drainPending(portId: string, record: MeetingRecord): void {
    const queue = this.pendingByPort.get(portId);
    if (!queue) return;
    this.pendingByPort.delete(portId);
    for (const event of queue) {
      if (event.platform !== record.platform) continue; // different platform on the same port — not this meeting
      if (event.kind === "joined") this.applyJoined(record, event.participantId, event.displayName);
      else if (event.kind === "roster") this.applyRoster(record, event.entries);
      else if (event.kind === "renamed") this.applyRename(record, event.platform, event.fromId, event.toId);
      else this.applyStream(record, event.platform, event.participantId);
    }
  }

  /** A participant left; when the last one goes, the call is over. */
  participantLeft(portId: string, participantId: ParticipantId): void {
    for (const record of this.meetings.values()) {
      if (record.portId !== portId || record.ended) continue;
      if (!record.participants.delete(participantId)) continue;
      this.upsertAttendee(record, { id: participantId, left: this.nowISO() });
      if (record.participants.size === 0) this.endMeeting(record);
    }
  }

  /** The tab's port went away (closed / navigated) — end its meetings and
   * drop any signals still buffered against a meeting that never declared. */
  portDisconnected(portId: string): void {
    this.pendingByPort.delete(portId);
    for (const record of this.meetings.values()) {
      if (record.portId === portId && !record.ended) this.endMeeting(record);
    }
  }

  /**
   * The popup's pause toggle → meeting.pause / meeting.resume. Pausing
   * closes the meeting's open transcription mark on the daemon; capture and
   * PCM ingest are untouched throughout (marks, never capture control).
   */
  async setPaused(paused: boolean): Promise<void> {
    for (const record of this.meetings.values()) {
      if (record.ended || record.paused === paused) continue;
      record.paused = paused;
      if (!record.meetingId) continue; // declared state applies once start lands
      try {
        const meeting = paused
          ? await this.control.meetingPause(record.meetingId)
          : await this.control.meetingResume(record.meetingId);
        record.paused = meeting.state === "paused";
      } catch (err) {
        console.warn(`[ears][meeting] meeting.${paused ? "pause" : "resume"} failed:`, err);
      }
    }
    this.emitState();
  }

  /** A `job` telemetry event — real transcription progress for the badge. */
  jobEvent(frame: EventFrame): void {
    if (frame.event !== "job") return;
    const params = frame.params as { job?: string; kind?: string; state?: string };
    if (params.kind !== "transcribe" || !params.job) return;
    if (params.state === "done" || params.state === "failed") {
      this.activeJobs.delete(params.job);
    } else {
      this.activeJobs.add(params.job);
    }
    this.emitState();
  }

  /**
   * The transport (re)connected: hello + subscribe landed and `snapshot` is
   * fresh. Re-declare every meeting this tracker believes is live —
   * meeting.start is idempotent on identity, so this converges after
   * service-worker eviction and daemon restart alike.
   */
  onReady(snapshot: SnapshotWire, _bootChanged: boolean): void {
    for (const meeting of snapshot.meetings) {
      // Adopt daemon-side pause state for meetings we're re-syncing with.
      const record = meeting.identity
        ? this.meetings.get(meeting.identity.external_id)
        : undefined;
      if (record && !record.ended) {
        record.meetingId = meeting.id;
        record.paused = meeting.state === "paused";
      }
    }
    for (const record of this.meetings.values()) {
      if (!record.ended) this.declare(record);
    }
    this.emitState();
  }

  private findRecord(portId: string, platform: Platform): MeetingRecord | undefined {
    for (const record of this.meetings.values()) {
      if (!record.ended && record.portId === portId && record.platform === platform) return record;
    }
    return undefined;
  }

  /** meeting.start (idempotent), then flush queued attendee upserts. */
  private declare(record: MeetingRecord): void {
    if (record.starting) return;
    record.starting = true;
    void this.control
      .meetingStart(record.platform, record.externalMeetingId)
      .then((meeting) => {
        record.starting = false;
        if (record.ended) {
          // Ended while the start was in flight — end it right back.
          void this.control.meetingEnd(meeting.id).catch(() => {});
          return;
        }
        const wantPaused = record.paused;
        record.meetingId = meeting.id;
        console.debug(`[ears][meeting] meeting ${record.externalMeetingId} → ${meeting.id}`);
        // The popup may have toggled pause before the id was known; apply
        // it now. Otherwise adopt the daemon's state (idempotent re-declare
        // of an already-paused meeting stays paused).
        const daemonPaused = meeting.state === "paused";
        if (wantPaused && !daemonPaused) {
          void this.control.meetingPause(meeting.id).catch(() => {});
        } else {
          record.paused = daemonPaused;
        }
        const queued = record.pendingAttendees.splice(0, record.pendingAttendees.length);
        for (const attendee of queued) this.upsertAttendee(record, attendee);
        this.emitState();
      })
      .catch((err) => {
        record.starting = false;
        console.warn(`[ears][meeting] meeting.start failed for ${record.externalMeetingId}:`, err);
      });
  }

  private upsertAttendee(record: MeetingRecord, attendee: AttendeeUpsert): void {
    if (record.ended) return;
    if (!record.meetingId) {
      record.pendingAttendees.push(attendee);
      return;
    }
    const meetingId = record.meetingId;
    void this.control.meetingAttendee(meetingId, attendee).catch((err) => {
      console.warn(`[ears][meeting] meeting.attendee(${attendee.id}) failed:`, err);
    });
  }

  private endMeeting(record: MeetingRecord): void {
    if (record.ended) return;
    record.ended = true;
    this.meetings.delete(record.externalMeetingId);
    if (record.meetingId) {
      void this.control.meetingEnd(record.meetingId).catch((err) => {
        console.warn(`[ears][meeting] meeting.end(${record.meetingId}) failed:`, err);
      });
    }
    // No meetingId yet: declare() notices `ended` when the start lands and
    // ends it then. If the start never landed at all, the daemon's
    // ingest-idle grace ends the meeting server-side.
    this.emitState();
  }

  private emitState(): void {
    const state = this.state;
    if (state === this.lastState) return;
    this.lastState = state;
    this.onState(state);
  }
}
