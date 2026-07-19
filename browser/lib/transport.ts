import {
  encodeBinaryFrame,
  INGEST_FORMAT,
  sourceLabel,
  type ParticipantId,
  type Platform,
} from "./protocol";

// The earsd ingest transport. Owns one WebSocket to ws://127.0.0.1:<port>/ingest
// and one piece of state: the participant → stream_id table. Lazily ingest.open
// a source on the first PCM for a new participant, stream binary frames, and
// ingest.close on leave. Reconnect with backoff; drop under back-pressure.
//
// Control responses carry no correlation id — earsd replies in request order
// over the single TCP-backed WebSocket — so pending requests are matched FIFO.

export type TransportStatus = "connecting" | "connected" | "disconnected";

// Drop the oldest queued frame once the socket's send buffer passes this, so a
// stalled socket never grows an unbounded queue (mirrors earsd's realtime drop).
const BUFFERED_AMOUNT_LIMIT = 1 << 20; // 1 MiB
const OPENING_QUEUE_LIMIT = 50; // frames buffered per participant while opening
const BASE_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 10_000;

type PendingRequest = { kind: "open"; participantId: ParticipantId } | { kind: "close" };

interface ParticipantState {
  platform: Platform;
  streamId?: string; // set once ingest.open succeeds
  opening: boolean;
  failed: boolean;
  queue: Uint8Array[]; // frames held while ingest.open is in flight
  dropped: number;
}

export class EarsSocket {
  /** Invoked when an ingest.open succeeds — the moment a participant's source
   * actually exists on earsd and can be named on a session
   * (meeting-tracker.ts listens to open sessions / add sources). */
  onStreamOpened?: (participantId: ParticipantId, platform: Platform) => void;

  private ws?: WebSocket;
  private status: TransportStatus = "disconnected";
  private closedByUs = false;
  private backoff = BASE_BACKOFF_MS;
  private reconnectTimer?: ReturnType<typeof setTimeout>;

  private readonly participants = new Map<ParticipantId, ParticipantState>();
  private readonly pending: PendingRequest[] = []; // FIFO, matches responses in order

  constructor(
    private port: number,
    private readonly onStatus: (s: TransportStatus) => void = () => {},
  ) {}

  get url(): string {
    return `ws://127.0.0.1:${this.port}/ingest`;
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
    this.resetState();
    this.setStatus("disconnected");
  }

  private open(): void {
    // Loopback only — a non-127.0.0.1 host is a bug, not a config.
    if (!this.url.startsWith("ws://127.0.0.1:")) {
      console.error(`[ears] refusing non-loopback ingest URL: ${this.url}`);
      return;
    }
    this.setStatus("connecting");
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      console.error("[ears] WebSocket construct failed:", err);
      this.scheduleReconnect();
      return;
    }
    ws.binaryType = "arraybuffer";
    this.ws = ws;

    ws.onopen = () => {
      console.log(`[ears] ingest connected: ${this.url}`);
      this.backoff = BASE_BACKOFF_MS;
      // stream_ids are per-connection; a fresh connection re-opens lazily.
      this.resetState();
      this.setStatus("connected");
    };
    ws.onmessage = (e) => this.onControlResponse(e.data);
    ws.onerror = () => console.warn("[ears] ingest socket error");
    ws.onclose = () => {
      if (this.ws === ws) this.ws = undefined;
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

  // ── PCM in ────────────────────────────────────────────────────────────────

  sendPcm(participantId: ParticipantId, platform: Platform, pcm: Uint8Array): void {
    if (this.status !== "connected" || !this.ws) return; // no buffering while down

    let st = this.participants.get(participantId);
    if (!st) {
      st = { platform, opening: false, failed: false, queue: [], dropped: 0 };
      this.participants.set(participantId, st);
    }
    if (st.failed) return;

    if (st.streamId) {
      this.sendFrame(st, st.streamId, pcm);
      return;
    }
    // Not open yet: queue (bounded, drop-oldest) and kick off ingest.open once.
    if (st.queue.length >= OPENING_QUEUE_LIMIT) {
      st.queue.shift();
      st.dropped++;
    }
    st.queue.push(pcm);
    if (!st.opening) this.openStream(participantId, st);
  }

  private openStream(participantId: ParticipantId, st: ParticipantState): void {
    st.opening = true;
    this.pending.push({ kind: "open", participantId });
    this.sendText({
      cmd: "ingest.open",
      source: sourceLabel(st.platform, participantId),
      format: INGEST_FORMAT,
    });
  }

  private sendFrame(st: ParticipantState, streamId: string, pcm: Uint8Array): void {
    if (!this.ws) return;
    // Back-pressure: drop the freshest-past-limit frame rather than grow unbounded.
    if (this.ws.bufferedAmount > BUFFERED_AMOUNT_LIMIT) {
      st.dropped++;
      if (st.dropped % 50 === 1) {
        console.warn(`[ears] back-pressure drop for ${streamId}: ${st.dropped} frame(s)`);
      }
      return;
    }
    const frame = encodeBinaryFrame(streamId, pcm); // fresh, full-length array
    this.ws.send(frame.buffer as ArrayBuffer);
  }

  participantLeft(participantId: ParticipantId): void {
    const st = this.participants.get(participantId);
    this.participants.delete(participantId);
    if (!st || this.status !== "connected") return;
    if (st.streamId) {
      this.pending.push({ kind: "close" });
      this.sendText({ cmd: "ingest.close", stream_id: st.streamId });
    }
  }

  // ── Control responses (FIFO) ────────────────────────────────────────────────

  private onControlResponse(data: unknown): void {
    if (typeof data !== "string") return; // binary from earsd is unexpected
    const req = this.pending.shift();
    if (!req) {
      console.warn("[ears] unsolicited control response:", data);
      return;
    }
    let parsed: { ok?: boolean; data?: { stream_id?: string }; error?: string };
    try {
      parsed = JSON.parse(data);
    } catch {
      console.error("[ears] bad control response JSON:", data);
      return;
    }

    if (req.kind === "close") return; // nothing to do on close ack

    const st = this.participants.get(req.participantId);
    if (!st) return; // participant already left before open resolved
    st.opening = false;

    if (parsed.ok && parsed.data?.stream_id) {
      st.streamId = parsed.data.stream_id;
      const frames = st.queue;
      st.queue = [];
      for (const f of frames) this.sendFrame(st, st.streamId, f);
      this.onStreamOpened?.(req.participantId, st.platform);
    } else {
      // No per-frame retry: mark failed and drop this participant's audio.
      st.failed = true;
      st.queue = [];
      console.warn(`[ears] ingest.open failed for ${req.participantId}: ${parsed.error ?? "unknown"}`);
    }
  }

  private sendText(obj: unknown): void {
    this.ws?.send(JSON.stringify(obj));
  }

  private resetState(): void {
    this.participants.clear();
    this.pending.length = 0;
  }

  private setStatus(s: TransportStatus): void {
    if (s === this.status) return;
    this.status = s;
    this.onStatus(s);
  }
}
