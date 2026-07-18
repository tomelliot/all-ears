import { defineBackground } from "#imports";
import { browser } from "wxt/browser";
import { EarsSocket, type TransportStatus } from "../lib/transport";
import { KEEPALIVE_ALARM, SessionTracker } from "../lib/session-state";
import type { PortMessage } from "../lib/protocol";

// Background context: owns the one WebSocket to earsd. Accepts the "pcm" port
// from the isolated relay, decodes each frame, and hands it to the transport,
// which lazily ingest.opens a stream per participant and streams binary PCM.
//
// Chrome runs this as a suspendable MV3 service worker; Firefox as a
// persistent background page. Everything here is written for the weaker
// (Chrome) guarantee: SessionTracker keeps a chrome.alarms keepalive armed
// only while a capture session is active (silence produces no socket traffic,
// so WebSocket-activity keepalive alone can't be relied on), and persists the
// session flag to storage.session so a respawned worker re-arms it. The rest
// of respawn recovery is free: this module's top level reconnects EarsSocket,
// streams re-open lazily on the next PCM frame, and the content relay
// re-establishes its port on the next post (pcm-port.ts).

const DEFAULT_PORT = 47811;
const PORT_STORAGE_KEY = "earsdPort";

export default defineBackground(() => {
  console.log("[ears] background loaded");

  let status: TransportStatus = "disconnected";
  const socket = new EarsSocket(DEFAULT_PORT, (s) => {
    status = s;
    console.log(`[ears] transport status: ${s}`);
    // Best-effort: tell any open popup. Ignored if none is listening.
    browser.runtime.sendMessage({ kind: "status", status: s }).catch(() => {});
  });

  const tracker = new SessionTracker(browser.alarms, browser.storage.session);
  // Respawn path: re-arm the keepalive if a session was active when the old
  // worker died (and clear any stale alarm if not).
  void tracker.restore();

  // The alarm's job is done by firing: the event resets the worker's idle
  // timer (or respawns a dead worker, whose top level then reconnects).
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === KEEPALIVE_ALARM) console.log("[ears] keepalive tick");
  });

  // Apply the configured port, then connect.
  browser.storage.local
    .get(PORT_STORAGE_KEY)
    .then((v) => {
      const p = Number((v as Record<string, unknown>)[PORT_STORAGE_KEY]);
      if (Number.isInteger(p) && p > 0) socket.setPort(p);
      socket.connect();
    })
    .catch(() => socket.connect());

  // React to a port change from the options/popup UI.
  browser.storage.local.onChanged?.addListener?.((changes) => {
    const c = changes[PORT_STORAGE_KEY];
    if (c && Number.isInteger(Number(c.newValue))) socket.setPort(Number(c.newValue));
  });

  const counts = new Map<string, number>();
  let nextPortId = 0;

  browser.runtime.onConnect.addListener((port) => {
    if (port.name !== "pcm") return;
    const portId = `pcm-${nextPortId++}`;
    console.log(`[ears] pcm port connected (${portId})`);
    port.onMessage.addListener((raw) => {
      const msg = raw as PortMessage;
      if (msg.type === "left") {
        tracker.participantLeft(portId, msg.participantId);
        socket.participantLeft(msg.participantId);
        return;
      }
      // type === "pcm"
      tracker.participantActive(portId, msg.participantId, msg.platform);
      const pcm = base64ToBytes(msg.b64);
      socket.sendPcm(msg.participantId, msg.platform, pcm);
      const n = (counts.get(msg.participantId) ?? 0) + 1;
      counts.set(msg.participantId, n);
      if (n % 50 === 0) console.log(`[ears] forwarded ${n} frames for ${msg.participantId}`);
    });
    port.onDisconnect.addListener(() => {
      // Tab closed / navigated away mid-call: close its participants' streams
      // now rather than leaking them on earsd until the socket reconnects.
      const orphaned = tracker.portDisconnected(portId);
      for (const id of orphaned) socket.participantLeft(id);
      console.log(
        `[ears] pcm port disconnected (${portId})` +
          (orphaned.length ? ` — closed ${orphaned.length} orphaned stream(s)` : ""),
      );
    });
  });

  // Let the popup query current status.
  browser.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if ((msg as { kind?: string }).kind === "get-status") {
      sendResponse({ status });
      return true;
    }
    return undefined;
  });
});

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
