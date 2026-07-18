import { beforeEach, describe, expect, it } from "vitest";
import { ReconnectingPort, type PortLike } from "./pcm-port";
import type { PortMessage } from "./protocol";

class FakePort implements PortLike {
  static instances: FakePort[] = [];
  sent: unknown[] = [];
  broken = false;
  private disconnectListeners: (() => void)[] = [];

  constructor() {
    FakePort.instances.push(this);
  }

  postMessage(msg: unknown): void {
    if (this.broken) throw new Error("Attempting to use a disconnected port object");
    this.sent.push(msg);
  }

  onDisconnect = {
    addListener: (cb: () => void) => this.disconnectListeners.push(cb),
  };

  /** Simulate the service worker going away: port breaks, then onDisconnect fires. */
  disconnect(): void {
    this.broken = true;
    for (const cb of this.disconnectListeners) cb();
  }
}

const MSG: PortMessage = { type: "left", participantId: "alice" };

describe("ReconnectingPort", () => {
  beforeEach(() => {
    FakePort.instances = [];
  });

  it("connects lazily on the first post and reuses the port after", () => {
    const port = new ReconnectingPort(() => new FakePort());
    expect(FakePort.instances).toHaveLength(0); // nothing until data flows

    expect(port.post(MSG)).toBe(true);
    expect(port.post(MSG)).toBe(true);
    expect(FakePort.instances).toHaveLength(1);
    expect(FakePort.instances[0]!.sent).toHaveLength(2);
  });

  it("reconnects on the next post after an observed disconnect (SW respawn)", () => {
    const port = new ReconnectingPort(() => new FakePort());
    port.post(MSG);
    FakePort.instances[0]!.disconnect();
    expect(FakePort.instances).toHaveLength(1); // lazy: no eager reconnect loop

    expect(port.post(MSG)).toBe(true);
    expect(FakePort.instances).toHaveLength(2);
    expect(FakePort.instances[1]!.sent).toEqual([MSG]);
  });

  it("retries once on an unannounced dead port (postMessage throws)", () => {
    const port = new ReconnectingPort(() => new FakePort());
    port.post(MSG);
    FakePort.instances[0]!.broken = true; // died without onDisconnect yet

    expect(port.post(MSG)).toBe(true);
    expect(FakePort.instances).toHaveLength(2);
    expect(FakePort.instances[1]!.sent).toEqual([MSG]);
  });

  it("gives up for good when connect() throws (extension context invalidated)", () => {
    let attempts = 0;
    const port = new ReconnectingPort(() => {
      attempts++;
      throw new Error("Extension context invalidated.");
    });

    expect(port.post(MSG)).toBe(false);
    expect(port.post(MSG)).toBe(false);
    expect(attempts).toBe(1); // permanent: no retry storm from a dead context
  });

  it("drops the frame (returns false) when the immediate retry also fails", () => {
    let n = 0;
    const port = new ReconnectingPort(() => {
      const p = new FakePort();
      if (n++ > 0) p.broken = true; // reconnected port is also dead
      return p;
    });
    port.post(MSG);
    FakePort.instances[0]!.broken = true;

    expect(port.post(MSG)).toBe(false);
    // Next post tries again from scratch rather than staying wedged.
    expect(port.post(MSG)).toBe(false);
    expect(FakePort.instances.length).toBeGreaterThanOrEqual(3);
  });
});
