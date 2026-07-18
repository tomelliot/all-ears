import type { ParticipantId, Platform } from "./protocol";

// Capture-session tracking for the background context (extension.md
// §Messaging, transport.md §Per-browser lifetime).
//
// Two jobs, both keyed off "is a capture session active" (≥1 live participant
// across all connected pcm ports):
//
//   1. chrome.alarms keepalive. Chrome's MV3 service worker suspends after
//      ~30 s idle. WebSocket *activity* resets that timer (Chrome 116+), but a
//      call where nobody talks produces no PCM frames and EarsSocket sends
//      nothing during silence — so a long quiet stretch could still suspend
//      the worker mid-call. While a session is active we keep a periodic alarm
//      whose firing both resets the idle timer and, if the worker did die,
//      respawns it. The alarm is cleared the moment the last participant
//      leaves, so an idle extension (meeting tab open but no call) schedules
//      no wakes at all. On Firefox the background page is persistent and the
//      alarm is a harmless no-op.
//
//   2. storage.session recovery state. A respawned worker re-runs its module
//      top level, which already reconnects EarsSocket and re-opens streams
//      lazily on the next PCM frame — but it has lost the in-memory fact that
//      a session was active, so without this it would also fail to re-arm the
//      keepalive alarm until audio happens to flow again. restore() reads the
//      persisted state at startup and re-arms. storage.session (not .local)
//      because this state must die with the browsing session — a fresh browser
//      start has no live ports and must not resurrect a stale alarm.
//
// Participants are tracked per-port so a closing tab (port disconnect) can
// return its still-live participants — the caller closes their ingest streams,
// otherwise a mid-call tab close would leak open streams on earsd until the
// socket next reconnects.

export const SESSION_STATE_KEY = "captureSession";
export const KEEPALIVE_ALARM = "ears-capture-keepalive";
// 30 s matches the worker's idle timeout. Chrome ≥120 honors it; older Chrome
// clamps to 1 min with a warning, which the port reconnect path (pcm-port.ts)
// covers if the worker slips through the wider gap.
export const KEEPALIVE_PERIOD_MINUTES = 0.5;

export interface CaptureSessionState {
  active: boolean;
  platform?: Platform;
}

/** Tolerant deserializer: anything malformed reads as "no active session". */
export function parseSessionState(raw: unknown): CaptureSessionState {
  if (typeof raw !== "object" || raw === null) return { active: false };
  const r = raw as Record<string, unknown>;
  const platform =
    r.platform === "meet" || r.platform === "zoom" || r.platform === "teams"
      ? (r.platform as Platform)
      : undefined;
  return { active: r.active === true, ...(platform ? { platform } : {}) };
}

// Minimal shapes of the two browser APIs we depend on, so tests can fake them
// as plain objects (same pattern as transport.test.ts's FakeWebSocket).
export interface AlarmsLike {
  create(name: string, info: { periodInMinutes: number }): unknown;
  clear(name: string): unknown;
}

export interface SessionAreaLike {
  get(key: string): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
  remove(key: string): Promise<void>;
}

export class SessionTracker {
  // portId → (participantId → platform). A participant belongs to the port
  // (tab) its PCM arrives on.
  private readonly byPort = new Map<string, Map<ParticipantId, Platform>>();

  constructor(
    private readonly alarms: AlarmsLike,
    private readonly session: SessionAreaLike,
  ) {}

  /**
   * Worker (re)start: re-arm the keepalive if a session was active before the
   * respawn; make sure no stale alarm survives if it wasn't.
   */
  async restore(): Promise<void> {
    let state: CaptureSessionState;
    try {
      const raw = await this.session.get(SESSION_STATE_KEY);
      state = parseSessionState(raw[SESSION_STATE_KEY]);
    } catch {
      state = { active: false };
    }
    if (state.active) {
      this.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: KEEPALIVE_PERIOD_MINUTES });
    } else {
      this.alarms.clear(KEEPALIVE_ALARM);
    }
  }

  /** First PCM (or explicit join) seen for a participant on a port. */
  participantActive(portId: string, participantId: ParticipantId, platform: Platform): void {
    let m = this.byPort.get(portId);
    if (!m) {
      m = new Map();
      this.byPort.set(portId, m);
    }
    if (m.has(participantId)) return;
    const wasIdle = this.total() === 0;
    m.set(participantId, platform);
    if (wasIdle) this.activate(platform);
  }

  participantLeft(portId: string, participantId: ParticipantId): void {
    const m = this.byPort.get(portId);
    if (!m?.delete(participantId)) return;
    if (this.total() === 0) this.deactivate();
  }

  /**
   * Port gone (tab closed, page navigated). Returns the participants that were
   * still live on it so the caller can ingest.close their streams.
   */
  portDisconnected(portId: string): ParticipantId[] {
    const m = this.byPort.get(portId);
    this.byPort.delete(portId);
    const ids = m ? [...m.keys()] : [];
    if (ids.length > 0 && this.total() === 0) this.deactivate();
    return ids;
  }

  private total(): number {
    let n = 0;
    for (const m of this.byPort.values()) n += m.size;
    return n;
  }

  private activate(platform: Platform): void {
    this.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: KEEPALIVE_PERIOD_MINUTES });
    const state: CaptureSessionState = { active: true, platform };
    void Promise.resolve(this.session.set({ [SESSION_STATE_KEY]: state })).catch(() => {});
  }

  private deactivate(): void {
    this.alarms.clear(KEEPALIVE_ALARM);
    void Promise.resolve(this.session.remove(SESSION_STATE_KEY)).catch(() => {});
  }
}
