import { defineBackground } from "#imports";
import { browser } from "wxt/browser";
import { EarsSocket, type TransportStatus } from "../lib/transport";
import type { PortMessage } from "../lib/protocol";

// Background context: owns the one WebSocket to earsd. Accepts the "pcm" port
// from the isolated relay, decodes each frame, and hands it to the transport,
// which lazily ingest.opens a stream per participant and streams binary PCM.

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

  browser.runtime.onConnect.addListener((port) => {
    if (port.name !== "pcm") return;
    console.log("[ears] pcm port connected");
    port.onMessage.addListener((raw) => {
      const msg = raw as PortMessage;
      if (msg.type === "left") {
        socket.participantLeft(msg.participantId);
        return;
      }
      // type === "pcm"
      const pcm = base64ToBytes(msg.b64);
      socket.sendPcm(msg.participantId, msg.platform, pcm);
      const n = (counts.get(msg.participantId) ?? 0) + 1;
      counts.set(msg.participantId, n);
      if (n % 50 === 0) console.log(`[ears] forwarded ${n} frames for ${msg.participantId}`);
    });
    port.onDisconnect.addListener(() => console.log("[ears] pcm port disconnected"));
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
