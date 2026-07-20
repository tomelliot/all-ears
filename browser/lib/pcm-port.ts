import type { PortMessage } from "./protocol";

// The isolated relay's long-lived "pcm" port, hardened against the receiving
// end disappearing. Chrome's MV3 service worker can suspend (which severs
// every runtime port) and respawn; Firefox's persistent background page makes
// this moot but the same code runs there unchanged.
//
// Reconnect policy is LAZY — reconnect on the next post(), not eagerly in
// onDisconnect. Eager reconnect would put every idle meeting tab (site open,
// no call, no PCM flowing) into a wake-the-worker → idle-out → disconnect →
// reconnect loop every ~30 s, burning battery for nothing. Lazily, an idle
// tab lets the worker sleep; the first frame after a respawn calls
// runtime.connect(), which itself wakes the worker, and messages posted on the
// fresh port are queued and delivered once its onConnect runs. Frames sent in
// the instant of disconnection are dropped, consistent with the drop-oldest
// policy everywhere else in this pipeline.
//
// runtime.connect() THROWING (as opposed to the port later disconnecting)
// means the extension context itself is gone — reload/update while the tab
// lives on. That's permanent for this document: stop trying, stay silent, a
// tab reload re-wires to the new worker (same behavior the old inline
// try/catch had).

export interface PortLike {
  postMessage(msg: unknown): void;
  onDisconnect: { addListener(cb: () => void): void };
}

export class ReconnectingPort {
  private port: PortLike | null = null;
  private dead = false;
  private everConnected = false;

  /**
   * `onReconnect` fires when a *fresh* port replaces a severed one (never on
   * the first connection) — before the message that triggered the reconnect
   * is posted. A respawned service worker starts with empty in-memory state,
   * so this is where the relay replays the lifecycle facts the new worker
   * missed (live meeting, current participants); without it the worker can
   * forward PCM but never knows which meeting it belongs to, and has nothing
   * to end when the tab goes away. Replayed messages use the provided `post`
   * (raw, no re-entrant reconnect) and are delivered in order ahead of the
   * triggering message.
   */
  constructor(
    private readonly connect: () => PortLike,
    private readonly onReconnect?: (post: (msg: PortMessage) => void) => void,
  ) {}

  /** Send, transparently reconnecting once if the port went away. */
  post(msg: PortMessage): boolean {
    if (this.dead) return false;
    const port = this.port ?? this.reconnect();
    if (!port) return false;
    try {
      port.postMessage(msg);
      return true;
    } catch {
      // Port died since we last used it and onDisconnect hasn't told us yet.
      this.port = null;
      const fresh = this.reconnect();
      if (!fresh) return false;
      try {
        fresh.postMessage(msg);
        return true;
      } catch {
        this.port = null;
        return false;
      }
    }
  }

  private reconnect(): PortLike | null {
    try {
      const port = this.connect();
      port.onDisconnect.addListener(() => {
        if (this.port === port) this.port = null;
      });
      this.port = port;
      const isRespawn = this.everConnected;
      this.everConnected = true;
      if (isRespawn && this.onReconnect) {
        this.onReconnect((msg) => {
          try {
            port.postMessage(msg);
          } catch {
            // Port died mid-replay; the next post() reconnects and replays again.
          }
        });
      }
      return port;
    } catch {
      this.dead = true;
      return null;
    }
  }
}
