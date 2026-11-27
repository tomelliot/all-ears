import {
  encodeBinaryFrame,
  INGEST_FORMAT,
  sourceLabel,
  type Platform,
} from "./protocol";

// The earsd ingest transport. Owns one WebSocket to ws://127.0.0.1:<port>/ingest
// and one piece of state: the participant → stream_id table. Lazily ingest.open
// a source on the first PCM for a new participant, stream binary frames, and
// ingest.close on leave. Reconnect with backoff; drop under back-pressure. A
// rejected open is retried (bounded — see MAX_OPEN_ATTEMPTS) rather than
// treated as the end of that participant.
//
// Every control request is stamped with a correlation `id`, and a response
// that echoes one is matched to its request by id — so a reordered, duplicated
// or unsolicited daemon response cannot desynchronise the queue. A response
// with no id (an earsd from before the field existed replies in request order
// over the single TCP-backed WebSocket) falls back to FIFO matching.

export type TransportStatus = "connecting" | "connected" | "disconnected";

// Drop the oldest queued frame once the socket's send buffer passes this, so a
// stalled socket never grows an unbounded queue (mirrors earsd's realtime drop).
const BUFFERED_AMOUNT_LIMIT = 1 << 20; // 1 MiB
const OPENING_QUEUE_LIMIT = 50; // frames buffered per participant while opening
const BASE_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 10_000;

// A rejected ingest.open is a lost race, not a verdict. earsd refuses an open
// whose identity tag names no live session, and its guard is written on the
// assumption that "the extension opens ingest only after session.start, so a
// live client simply retries" (openIngestSource, EarsDaemon.swift). The tag
// comes from the session tracker per frame and is undefined until that port's
// session is declared, so the honest client behaviour is to hold the
// participant and re-open when the answer can have changed. These three
// constants are what keeps "retry" from meaning "hammer the socket":
const MAX_OPEN_ATTEMPTS = 5; // opens per participant per distinct session tag
const OPEN_RETRY_MS = 1_000; // floor between same-tag retries (PCM arrives ~10 frames/s)
// How long a participant may sit un-opened before we call it a fault. Generous:
// the held queue is bounded either way, so waiting costs nothing but the
// frames already being lost, and a session tag that shows up at 50s still
// rescues the rest of the call.
const OPEN_HOLD_LIMIT_MS = 60_000;

type PendingRequest =
  | { kind: "open"; id: string; participantId: string }
  | { kind: "close"; id: string }
  | { kind: "attribution"; id: string }
  | { kind: "capture-failed"; id: string };

/** Per-frame provenance carried from the MAIN world all the way to earsd. */
export interface FrameStamp {
  seq: number;
  sentAt: number;
}

interface ParticipantState {
  platform: Platform;
  /** External meeting id the participant belongs to, when the tracker knows
   * it — stamped on ingest.open so the daemon links the source into the
   * session itself (membership survives a respawned service worker). */
  meetingExternalId?: string;
  streamId?: string; // set once ingest.open succeeds
  opening: boolean;
  /** Attempts exhausted or held too long: this participant's audio is being
   * discarded for the rest of the call, and giveUp() said so out loud. */
  gaveUp: boolean;
  /** ingest.opens sent for this participant, including one in flight. Reset
   * when a new session tag arrives, because the rejections so far answered a
   * question we are no longer asking. */
  attempts: number;
  /** The tag stamped on the most recent attempt. An id that differs from this
   * one (in particular undefined → defined) is the new information worth
   * spending an attempt on. */
  attemptedWith?: string;
  /** Earliest time a same-tag retry may go out; 0 until a rejection sets it. */
  retryAfter: number;
  /** Deadline after which holding this participant becomes a reported fault.
   * Infinity until the first rejection sets it. */
  holdUntil: number;
  /** The daemon's last stated reason, carried into the give-up log. */
  lastError?: string;
  /** Frames held while ingest.open is in flight, with their stamps so a queued
   * frame reaches the daemon with its original send time, not its replay time. */
  queue: Array<{ pcm: Uint8Array; stamp?: FrameStamp }>;
  dropped: number;
}

/**
 * Transport instruments, injected by the background so this module doesn't
 * depend on the collector's lifecycle. `buffered_bytes` is the one that
 * distinguishes "the extension is slow" from "the daemon is slow": if it grows,
 * PCM is queuing inside the renderer because the socket can't drain, which is a
 * different fault with a different fix from local compute cost.
 */
export interface TransportPerf {
  buffered: { set(v: number): void };
  sent: { add(n?: number): void };
  bytes: { add(n?: number): void };
  dropped: { add(n?: number): void };
  queued: { set(v: number): void };
}

export class EarsSocket {
  /** Invoked when an ingest.open succeeds — the moment a participant's source
   * actually exists on earsd (session-tracker.ts listens to attach the
   * source to its session). */
  onStreamOpened?: (participantId: string, platform: Platform) => void;

  /** Optional perf sink; unset in tests and when perf collection is off. */
  perf?: TransportPerf;

  private ws?: WebSocket;
  private status: TransportStatus = "disconnected";
  private closedByUs = false;
  private backoff = BASE_BACKOFF_MS;
  private reconnectTimer?: ReturnType<typeof setTimeout>;

  private readonly participants = new Map<string, ParticipantState>();
  private readonly pending: PendingRequest[] = []; // id-matched; FIFO for daemons that don't echo
  /** Correlation ids, unique per socket lifetime (uniqueness per connection is
   * all the protocol needs — pending is cleared on reconnect). */
  private nextRequestId = 1;

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
      console.error(`[ears][transport] refusing non-loopback ingest URL: ${this.url}`);
      return;
    }
    this.setStatus("connecting");
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      console.error("[ears][transport] WebSocket construct failed:", err);
      this.scheduleReconnect();
      return;
    }
    ws.binaryType = "arraybuffer";
    this.ws = ws;

    ws.onopen = () => {
      this.backoff = BASE_BACKOFF_MS;
      // stream_ids are per-connection; a fresh connection re-opens lazily.
      this.resetState();
      this.setStatus("connected");
    };
    ws.onmessage = (e) => this.onControlResponse(e.data);
    ws.onerror = () => console.warn("[ears][transport] ingest socket error");
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

  sendPcm(
    participantId: string,
    platform: Platform,
    pcm: Uint8Array,
    meetingExternalId?: string,
    stamp?: FrameStamp,
  ): void {
    if (this.status !== "connected" || !this.ws) return; // no buffering while down

    let st = this.participants.get(participantId);
    if (!st) {
      st = {
        platform,
        meetingExternalId,
        opening: false,
        gaveUp: false,
        attempts: 0,
        retryAfter: 0,
        holdUntil: Infinity,
        queue: [],
        dropped: 0,
      };
      this.participants.set(participantId, st);
    }
    // The tag is per-frame precisely because it arrives late: externalIdFor()
    // is undefined until the tracker has declared this port's session, so a
    // later frame is where a participant that opened too early learns the
    // answer. Never overwrite a known tag with undefined — the tracker also
    // goes quiet once the record is gone, and that is not news.
    if (meetingExternalId) st.meetingExternalId = meetingExternalId;
    if (st.gaveUp) return;

    if (st.streamId) {
      this.sendFrame(st, st.streamId, pcm, stamp);
      return;
    }
    // Not open yet: queue (bounded, drop-oldest) and open — or wait for a retry
    // that can do better than the last one.
    if (st.queue.length >= OPENING_QUEUE_LIMIT) {
      st.queue.shift();
      st.dropped++;
      this.perf?.dropped.add();
    }
    st.queue.push({ pcm, stamp });
    this.perf?.queued.set(st.queue.length);
    this.maybeOpen(participantId, st);
  }

  /**
   * Send ingest.open, or hold this participant for a retry with better odds.
   * Runs on every held frame, so every bound on the retry lives here: one open
   * in flight at a time; a fresh budget whenever the session tag changes (the
   * only event that can turn a "no live session" rejection into a yes); and
   * otherwise at most one attempt per OPEN_RETRY_MS until the budget is spent.
   * Nothing here is timer-driven — a participant that has stopped sending PCM
   * has nothing left to rescue.
   */
  private maybeOpen(participantId: string, st: ParticipantState): void {
    if (st.opening) return;
    if (st.attempts === 0) {
      this.openStream(participantId, st);
      return;
    }
    const now = Date.now();
    if (now >= st.holdUntil) {
      this.giveUp(participantId, st);
      return;
    }
    if (st.meetingExternalId !== undefined && st.meetingExternalId !== st.attemptedWith) {
      st.attempts = 0; // new tag, new question
      this.openStream(participantId, st);
      return;
    }
    if (st.attempts < MAX_OPEN_ATTEMPTS && now >= st.retryAfter) {
      // Same tag, retried anyway: session.start travels the control socket
      // while this open travels the ingest one, so the daemon can simply be a
      // beat behind a tag that is already correct.
      this.openStream(participantId, st);
    }
  }

  private openStream(participantId: string, st: ParticipantState): void {
    st.opening = true;
    st.attempts++;
    st.attemptedWith = st.meetingExternalId;
    const id = String(this.nextRequestId++);
    this.pending.push({ kind: "open", id, participantId });
    this.sendText({
      cmd: "ingest.open",
      id,
      source: sourceLabel(st.platform, participantId),
      format: INGEST_FORMAT,
      ...(st.meetingExternalId
        ? { session: { platform: st.platform, external_id: st.meetingExternalId } }
        : {}),
    });
  }

  private sendFrame(
    st: ParticipantState,
    streamId: string,
    pcm: Uint8Array,
    stamp?: FrameStamp,
  ): void {
    if (!this.ws) return;
    const buffered = this.ws.bufferedAmount;
    this.perf?.buffered.set(buffered);
    // Back-pressure: drop the freshest-past-limit frame rather than grow unbounded.
    if (buffered > BUFFERED_AMOUNT_LIMIT) {
      st.dropped++;
      this.perf?.dropped.add();
      if (st.dropped % 50 === 1) {
        console.warn(`[ears][transport] back-pressure drop for ${streamId}: ${st.dropped} frame(s)`);
      }
      return;
    }
    const frame = encodeBinaryFrame(streamId, pcm, stamp); // fresh, full-length array
    this.ws.send(frame.buffer as ArrayBuffer);
    this.perf?.sent.add();
    this.perf?.bytes.add(frame.byteLength);
  }

  /**
   * Ship a batch of attribution flight-recorder events (pre-encoded JSONL
   * lines — see attribution-log.ts) as an `ingest.attribution` text frame.
   * Best-effort by contract: with no session tag there is no session directory
   * to file the batch under, and with the socket down there is no daemon — in
   * both cases the batch is dropped here, and the in-page ring still holds the
   * events for on-demand export.
   */
  sendAttribution(events: string[], platform: Platform, meetingExternalId?: string): void {
    if (this.status !== "connected" || !this.ws || events.length === 0) return;
    if (!meetingExternalId) return;
    const id = String(this.nextRequestId++);
    this.pending.push({ kind: "attribution", id });
    this.sendText({
      cmd: "ingest.attribution",
      id,
      session: { platform, external_id: meetingExternalId },
      events,
    });
  }

  /**
   * Report a participant's capture death (`ingest.capture_failed`) so the
   * daemon records the gap in the tagged session's events.jsonl instead of
   * mistaking it for silence (issue #22). Best-effort like attribution: with
   * no session tag or the socket down the report is dropped — the
   * background's console error already said it loudly.
   */
  sendCaptureFailed(
    participantId: string,
    platform: Platform,
    reason: string,
    meetingExternalId?: string,
  ): void {
    if (this.status !== "connected" || !this.ws) return;
    if (!meetingExternalId) return;
    const id = String(this.nextRequestId++);
    this.pending.push({ kind: "capture-failed", id });
    this.sendText({
      cmd: "ingest.capture_failed",
      id,
      source: sourceLabel(platform, participantId),
      session: { platform, external_id: meetingExternalId },
      reason,
    });
  }

  participantLeft(participantId: string): void {
    const st = this.participants.get(participantId);
    this.participants.delete(participantId);
    if (!st || this.status !== "connected") return;
    if (st.streamId) {
      const id = String(this.nextRequestId++);
      this.pending.push({ kind: "close", id });
      this.sendText({ cmd: "ingest.close", id, stream_id: st.streamId });
    }
  }

  // ── Control responses (id-matched, FIFO fallback) ───────────────────────────

  private onControlResponse(data: unknown): void {
    if (typeof data !== "string") return; // binary from earsd is unexpected
    let parsed: { ok?: boolean; id?: string; data?: { stream_id?: string }; error?: string };
    try {
      parsed = JSON.parse(data);
    } catch {
      // A FIFO daemon's reply still answered one request, however garbled —
      // consume the slot so the queue stays aligned (an id-echoing daemon
      // never sends unparseable JSON in the first place).
      console.error("[ears][transport] bad control response JSON:", data);
      this.pending.shift();
      return;
    }

    let req: PendingRequest | undefined;
    if (typeof parsed.id === "string") {
      // The daemon echoed our correlation id: match by id, order-independent.
      const idx = this.pending.findIndex((p) => p.id === parsed.id);
      if (idx === -1) {
        // Unsolicited or duplicated — dropping it (rather than shifting the
        // queue) is the whole point of the id: nothing else desynchronises.
        console.warn("[ears][transport] response with unknown correlation id:", data);
        return;
      }
      req = this.pending.splice(idx, 1)[0]!;
    } else {
      // No id echoed (an earsd predating the field): replies arrive in
      // request order, so the head of the queue is the request answered.
      req = this.pending.shift();
    }
    if (!req) {
      console.warn("[ears][transport] unsolicited control response:", data);
      return;
    }

    if (req.kind === "close") return; // nothing to do on close ack
    if (req.kind === "attribution") {
      // Fire-and-forget: the events are already safe in the in-page ring.
      if (!parsed.ok) console.warn(`[ears][transport] ingest.attribution rejected: ${parsed.error ?? "unknown"}`);
      return;
    }
    if (req.kind === "capture-failed") {
      // Fire-and-forget: the failure was already logged at error level.
      if (!parsed.ok) console.warn(`[ears][transport] ingest.capture_failed rejected: ${parsed.error ?? "unknown"}`);
      return;
    }

    const st = this.participants.get(req.participantId);
    if (!st) return; // participant already left before open resolved
    st.opening = false;

    if (parsed.ok && parsed.data?.stream_id) {
      st.streamId = parsed.data.stream_id;
      const frames = st.queue;
      st.queue = [];
      for (const f of frames) this.sendFrame(st, st.streamId, f.pcm, f.stamp);
      this.onStreamOpened?.(req.participantId, st.platform);
    } else {
      // Not terminal. Keep the participant and its held frames: the usual
      // cause is a session tag the daemon can't resolve *yet*, and the next
      // frames carry the tag that fixes it (see maybeOpen for the bounds).
      st.lastError = parsed.error ?? "unknown";
      st.retryAfter = Date.now() + OPEN_RETRY_MS;
      if (st.holdUntil === Infinity) st.holdUntil = Date.now() + OPEN_HOLD_LIMIT_MS;
      console.warn(
        `[ears][transport] ingest.open rejected for ${req.participantId} ` +
          `(attempt ${st.attempts}, session tag ${st.attemptedWith ?? "none"}): ${st.lastError} — holding for a retry`,
      );
    }
  }

  /**
   * The retry budget or the hold window ran out. Drop this participant's audio
   * for the rest of the call — and say so at error level, because the failure
   * mode this guards is a recording that looks complete and is missing a
   * person. A silent drop here is indistinguishable from someone not speaking.
   */
  private giveUp(participantId: string, st: ParticipantState): void {
    st.gaveUp = true;
    const held = st.queue.length;
    st.queue = [];
    st.dropped += held;
    if (held) this.perf?.dropped.add(held);
    this.perf?.queued.set(0);
    console.error(
      `[ears][transport] giving up on ${participantId} after ${st.attempts} ingest.open attempt(s) ` +
        `over ${OPEN_HOLD_LIMIT_MS / 1000}s (session tag ${st.attemptedWith ?? "none"}, last error: ` +
        `${st.lastError ?? "unknown"}) — ${st.dropped} frame(s) dropped, this participant is NOT being recorded`,
    );
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
