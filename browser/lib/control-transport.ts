import {
  controlRequest,
  type AttendeeUpsert,
  type EventFrame,
  type HelloResult,
  type MeetingWire,
  type Platform,
  type RequestId,
  type ResponseFrame,
  type SnapshotWire,
  type WireError,
  PROTOCOL_VERSION,
} from "./protocol";
import type { TransportStatus } from "./transport";

// The earsd control-plane transport, speaking control protocol v2. Owns one
// WebSocket to ws://127.0.0.1:<port>/control (no binary PCM — that's the
// ingest socket's job, transport.ts). Structured like EarsSocket: reconnect
// with backoff. Requests carry client-chosen ids and resolve out of a
// pending id→resolver map, so out-of-order completion is fine and a
// disconnect fails every pending request instead of stranding them.
//
// On every (re)connect the transport performs the mandatory `hello`
// handshake and re-subscribes to the live feed, then invokes `onReady` with
// the fresh snapshot — the MeetingTracker's cue to re-declare whatever the
// DOM says is live (meeting.start is idempotent, so recovery is just
// re-declaration).

const BASE_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 10_000;

/** What this client tells the daemon it is, in `hello`. */
export const CLIENT_NAME = "browser-extension/0.1.0";

interface PendingRequest {
  resolve: (frame: ResponseFrame) => void;
  reject: (reason: Error) => void;
}

export class ControlError extends Error {
  constructor(public readonly wire: WireError) {
    super(`[${wire.code}] ${wire.message}`);
  }
}

export class ControlSocket {
  private ws?: WebSocket;
  private status: TransportStatus = "disconnected";
  private closedByUs = false;
  private backoff = BASE_BACKOFF_MS;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private nextId = 0;
  private readonly pending = new Map<RequestId, PendingRequest>();
  private ready = false;
  private lastBootId?: string;

  /** Fresh snapshot after every successful hello+subscribe; `bootChanged`
   * is true when the daemon restarted since the previous connection. */
  onReady: (snapshot: SnapshotWire, bootChanged: boolean) => void = () => {};
  /** Every notification frame received while subscribed. */
  onEvent: (frame: EventFrame) => void = () => {};

  constructor(
    private port: number,
    private readonly onStatus: (s: TransportStatus) => void = () => {},
  ) {}

  get url(): string {
    return `ws://127.0.0.1:${this.port}/control`;
  }

  connect(): void {
    this.closedByUs = false;
    this.open();
  }

  /** Change the target port (from options) and reconnect. */
  setPort(port: number): void {
    if (port === this.port) return;
    this.port = port;
    if (!this.closedByUs) this.reconnect(0);
  }

  disconnect(): void {
    this.closedByUs = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.ws?.close();
    this.ws = undefined;
    this.ready = false;
    this.rejectAllPending("earsd control socket disconnected");
    this.setStatus("disconnected");
  }

  private open(): void {
    // Loopback only — a non-127.0.0.1 host is a bug, not a config.
    if (!this.url.startsWith("ws://127.0.0.1:")) {
      console.error(`[ears][control] refusing non-loopback control URL: ${this.url}`);
      return;
    }
    this.setStatus("connecting");
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      console.error("[ears][control] control WebSocket construct failed:", err);
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      console.debug(`[ears][control] control connected: ${this.url}`);
      this.backoff = BASE_BACKOFF_MS;
      void this.handshake();
    };
    ws.onmessage = (e) => this.onFrame(e.data);
    ws.onerror = () => console.warn("[ears][control] control socket error");
    ws.onclose = () => {
      if (this.ws === ws) this.ws = undefined;
      this.ready = false;
      this.rejectAllPending("earsd control socket closed");
      this.setStatus("disconnected");
      if (!this.closedByUs) this.scheduleReconnect();
    };
  }

  /** hello → subscribe → snapshot → onReady. Runs on every (re)connect. */
  private async handshake(): Promise<void> {
    try {
      const hello = (await this.request(
        (id) => controlRequest.hello(id, CLIENT_NAME),
        true,
      )) as HelloResult;
      if (hello.protocol !== PROTOCOL_VERSION) {
        console.error(`[ears][control] daemon speaks protocol ${hello.protocol}, expected v2 — giving up`);
        return;
      }
      const bootChanged = this.lastBootId !== undefined && this.lastBootId !== hello.boot_id;
      this.lastBootId = hello.boot_id;
      // State events (meeting/session/source) are always delivered; the
      // filter names the telemetry we care about (job progress).
      const snapshot = (await this.request(
        (id) => controlRequest.subscribe(id, ["job"]),
        true,
      )) as SnapshotWire;
      this.ready = true;
      this.setStatus("connected");
      this.onReady(snapshot, bootChanged);
    } catch (err) {
      console.warn("[ears][control] control handshake failed:", err);
      this.ws?.close();
    }
  }

  // ── Typed command surface (what meeting-tracker.ts consumes) ──────────────

  /** meeting.start (idempotent on platform+external id) → the meeting. */
  async meetingStart(platform: Platform, externalMeetingId: string): Promise<MeetingWire> {
    return (await this.request((id) =>
      controlRequest.meetingStart(id, platform, externalMeetingId),
    )) as MeetingWire;
  }

  async meetingEnd(meeting: string): Promise<MeetingWire> {
    return (await this.request((id) => controlRequest.meetingEnd(id, meeting))) as MeetingWire;
  }

  async meetingPause(meeting: string): Promise<MeetingWire> {
    return (await this.request((id) => controlRequest.meetingPause(id, meeting))) as MeetingWire;
  }

  async meetingResume(meeting: string): Promise<MeetingWire> {
    return (await this.request((id) => controlRequest.meetingResume(id, meeting))) as MeetingWire;
  }

  /** meeting.attendee upsert (roster + optional source link). */
  async meetingAttendee(meeting: string, attendee: AttendeeUpsert): Promise<MeetingWire> {
    return (await this.request((id) =>
      controlRequest.meetingAttendee(id, meeting, attendee),
    )) as MeetingWire;
  }

  // ── id-correlated request/response plumbing ───────────────────────────────

  /**
   * Sends one request frame (built with a fresh id) and resolves its
   * correlated response's `result`, or rejects with a ControlError carrying
   * the wire error. `duringHandshake` lets hello/subscribe through before
   * `ready` flips.
   */
  private request(
    build: (id: RequestId) => unknown,
    duringHandshake = false,
  ): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN || (!this.ready && !duringHandshake)) {
        reject(new Error("earsd control socket not connected"));
        return;
      }
      const id = ++this.nextId;
      this.pending.set(id, {
        resolve: (frame) => {
          if (frame.error) reject(new ControlError(frame.error));
          else resolve(frame.result);
        },
        reject,
      });
      this.ws.send(JSON.stringify(build(id)));
    });
  }

  private onFrame(data: unknown): void {
    if (typeof data !== "string") return; // binary from earsd is unexpected
    let frame: ResponseFrame | EventFrame;
    try {
      frame = JSON.parse(data) as ResponseFrame | EventFrame;
    } catch {
      console.warn("[ears][control] bad control frame JSON");
      return;
    }
    if ("id" in frame && frame.id !== undefined && frame.id !== null) {
      const pending = this.pending.get(frame.id);
      if (!pending) {
        console.warn("[ears][control] response for unknown request id:", frame.id);
        return;
      }
      this.pending.delete(frame.id);
      pending.resolve(frame);
      return;
    }
    if ("event" in frame) {
      this.onEvent(frame);
    }
  }

  private scheduleReconnect(): void {
    this.reconnect(this.backoff);
    this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF_MS);
  }

  private reconnect(delay: number): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => this.open(), delay);
  }

  private rejectAllPending(reason: string): void {
    const pending = [...this.pending.values()];
    this.pending.clear();
    for (const p of pending) p.reject(new Error(reason));
  }

  private setStatus(s: TransportStatus): void {
    if (s === this.status) return;
    this.status = s;
    this.onStatus(s);
  }
}
