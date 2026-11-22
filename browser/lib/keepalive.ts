import type { Platform } from "./protocol";

// Keepalive tracking for the background context (extension.md §Messaging,
// transport.md §Per-browser lifetime).
//
// Two jobs, both keyed off "is capture live" (≥1 live participant across all
// connected pcm ports):
//
//   1. chrome.alarms keepalive. Chrome's MV3 service worker suspends after
//      ~30 s idle. WebSocket *activity* resets that timer (Chrome 116+), but a
//      call where nobody talks produces no PCM frames and EarsSocket sends
//      nothing during silence — so a long quiet stretch could still suspend
//      the worker mid-call. While capture is live we keep a periodic alarm
//      whose firing both resets the idle timer and, if the worker did die,
//      respawns it. The alarm is cleared the moment the last participant
//      leaves, so an idle extension (meeting tab open but no call) schedules
//      no wakes at all. On Firefox the background page is persistent and the
//      alarm is a harmless no-op.
//
//   2. storage.session recovery state. A respawned worker re-runs its module
//      top level, which already reconnects EarsSocket and re-opens streams
//      lazily on the next PCM frame — but it has lost the in-memory fact that
//      capture was live, so without this it would also fail to re-arm the
//      keepalive alarm until audio happens to flow again. restore() reads the
//      persisted state at startup and re-arms. storage.session (not .local)
//      because this state must die with the browsing session — a fresh browser
//      start has no live ports and must not resurrect a stale alarm.
//
// Naming note: "session" in this file only ever means the chrome.storage.session
// browser API (storage scoped to the browsing session) — it is unrelated to any
// session concept of our own.
//
// Participants are tracked per-port so a closing tab (port disconnect) can
// return its still-live participants — the caller closes their ingest streams,
// otherwise a mid-call tab close would leak open streams on earsd until the
// socket next reconnects.

export const KEEPALIVE_STATE_KEY = "keepalive";
export const KEEPALIVE_ALARM = "ears-capture-keepalive";
// 30 s matches the worker's idle timeout. Chrome ≥120 honors it; older Chrome
// clamps to 1 min with a warning, which the port reconnect path (pcm-port.ts)
// covers if the worker slips through the wider gap.
export const KEEPALIVE_PERIOD_MINUTES = 0.5;

export interface KeepaliveState {
  active: boolean;
  platform?: Platform;
}

/** Tolerant deserializer: anything malformed reads as "capture not live". */
export function parseKeepaliveState(raw: unknown): KeepaliveState {
  if (typeof raw !== "object" || raw === null) return { active: false };
  const r = raw as Record<string, unknown>;
  const platform =
    r.platform === "meet" ||
    r.platform === "zoom" ||
    r.platform === "teams" ||
    r.platform === "daily" ||
    r.platform === "jitsi" ||
    r.platform === "web"
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

/** Shape of the chrome.storage.session area (a browser API, not our concept). */
export interface StorageAreaLike {
  get(key: string): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
  remove(key: string): Promise<void>;
}

export class KeepaliveTracker {
  // portId → (participantId → platform). A participant belongs to the port
  // (tab) its PCM arrives on.
  private readonly byPort = new Map<string, Map<string, Platform>>();

  constructor(
    private readonly alarms: AlarmsLike,
    private readonly storage: StorageAreaLike,
  ) {}

  /**
   * Worker (re)start: re-arm the keepalive if capture was live before the
   * respawn; make sure no stale alarm survives if it wasn't.
   */
  async restore(): Promise<void> {
    let state: KeepaliveState;
    try {
      const raw = await this.storage.get(KEEPALIVE_STATE_KEY);
      state = parseKeepaliveState(raw[KEEPALIVE_STATE_KEY]);
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
  participantActive(portId: string, participantId: string, platform: Platform): void {
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

  participantLeft(portId: string, participantId: string): void {
    const m = this.byPort.get(portId);
    if (!m?.delete(participantId)) return;
    if (this.total() === 0) this.deactivate();
  }

  /**
   * Port gone (tab closed, page navigated). Returns the participants that were
   * still live on it so the caller can ingest.close their streams.
   */
  portDisconnected(portId: string): string[] {
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
    const state: KeepaliveState = { active: true, platform };
    void Promise.resolve(this.storage.set({ [KEEPALIVE_STATE_KEY]: state })).catch(() => {});
  }

  private deactivate(): void {
    this.alarms.clear(KEEPALIVE_ALARM);
    void Promise.resolve(this.storage.remove(KEEPALIVE_STATE_KEY)).catch(() => {});
  }
}
