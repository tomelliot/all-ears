import { controlRequest, type Platform } from "./protocol";
import type { TransportStatus } from "./transport";

// The earsd control-plane transport. Owns one WebSocket to
// ws://127.0.0.1:<port>/control and speaks the full ControlRequest/
// ControlResponse JSON shape (no binary PCM — that's the ingest socket's job,
// transport.ts). Structured like EarsSocket: reconnect with backoff, and
// FIFO-matched request/response — control replies carry no correlation id;
// earsd replies in request order over the single TCP-backed WebSocket.

const BASE_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 10_000;

interface ControlResponseEnvelope<Data> {
  ok?: boolean;
  data?: Data;
  error?: string;
}

interface PendingRequest {
  resolve: (value: ControlResponseEnvelope<unknown>) => void;
  reject: (reason: Error) => void;
}

export class ControlSocket {
  private ws?: WebSocket;
  private status: TransportStatus = "disconnected";
  private closedByUs = false;
  private backoff = BASE_BACKOFF_MS;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private readonly pending: PendingRequest[] = []; // FIFO, matches responses in order

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
    this.rejectAllPending("earsd control socket disconnected");
    this.setStatus("disconnected");
  }

  private open(): void {
    // Loopback only — a non-127.0.0.1 host is a bug, not a config.
    if (!this.url.startsWith("ws://127.0.0.1:")) {
      console.error(`[ears] refusing non-loopback control URL: ${this.url}`);
      return;
    }
    this.setStatus("connecting");
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      console.error("[ears] control WebSocket construct failed:", err);
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      console.log(`[ears] control connected: ${this.url}`);
      this.backoff = BASE_BACKOFF_MS;
      this.setStatus("connected");
    };
    ws.onmessage = (e) => this.onControlResponse(e.data);
    ws.onerror = () => console.warn("[ears] control socket error");
    ws.onclose = () => {
      if (this.ws === ws) this.ws = undefined;
      // Anything still pending can never be answered: replies are matched by
      // order on THIS connection.
      this.rejectAllPending("earsd control socket closed");
      this.setStatus("disconnected");
      if (!this.closedByUs) this.scheduleReconnect();
    };
  }

  private scheduleReconnect(): void {
    this.reconnect(this.backoff);
    this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF_MS);
  }

  private reconnect(delay: number): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => this.open(), delay);
  }

  // ── Typed command surface (what meeting-tracker.ts consumes) ──────────────

  /** meeting.resolve → the daemon-assigned meeting UUID for this platform id. */
  async meetingResolve(platform: Platform, externalMeetingId: string): Promise<string> {
    const response = await this.request<{ meeting_id?: string }>(
      controlRequest.meetingResolve(platform, externalMeetingId),
    );
    const meetingId = response.data?.meeting_id;
    if (!response.ok || !meetingId) {
      throw new Error(`meeting.resolve failed: ${response.error ?? "no meeting_id"}`);
    }
    return meetingId;
  }

  /** session.open (trigger browser-extension) → the new daemon session id. */
  async sessionOpen(sources: readonly string[], slug: string): Promise<string> {
    const response = await this.request<{ id?: string }>(controlRequest.sessionOpen(sources, slug));
    const id = response.data?.id;
    if (!response.ok || !id) {
      throw new Error(`session.open failed: ${response.error ?? "no session id"}`);
    }
    return id;
  }

  async sessionClose(id: string): Promise<void> {
    const response = await this.request(controlRequest.sessionClose(id));
    if (!response.ok) throw new Error(`session.close failed: ${response.error ?? "unknown"}`);
  }

  async sessionAddSource(id: string, source: string): Promise<void> {
    const response = await this.request(controlRequest.sessionAddSource(id, source));
    if (!response.ok) throw new Error(`session.add_source failed: ${response.error ?? "unknown"}`);
  }

  // ── FIFO request/response plumbing ────────────────────────────────────────

  private request<Data>(body: unknown): Promise<ControlResponseEnvelope<Data>> {
    return new Promise((resolve, reject) => {
      if (this.status !== "connected" || !this.ws) {
        reject(new Error("earsd control socket not connected"));
        return;
      }
      this.pending.push({
        resolve: resolve as (value: ControlResponseEnvelope<unknown>) => void,
        reject,
      });
      this.ws.send(JSON.stringify(body));
    });
  }

  private onControlResponse(data: unknown): void {
    if (typeof data !== "string") return; // binary from earsd is unexpected
    const pending = this.pending.shift();
    if (!pending) {
      console.warn("[ears] unsolicited control response:", data);
      return;
    }
    try {
      pending.resolve(JSON.parse(data) as ControlResponseEnvelope<unknown>);
    } catch {
      pending.reject(new Error("bad control response JSON"));
    }
  }

  private rejectAllPending(reason: string): void {
    const pending = this.pending.splice(0, this.pending.length);
    for (const p of pending) p.reject(new Error(reason));
  }

  private setStatus(s: TransportStatus): void {
    if (s === this.status) return;
    this.status = s;
    this.onStatus(s);
  }
}
