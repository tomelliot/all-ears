import { defineContentScript } from "#imports";
import { browser } from "wxt/browser";
import { isMainEnvelope, type MainMessage, type Platform, type PortMessage } from "../lib/protocol";

// Isolated-world relay. The MAIN-world hook (hook.content.ts) generates PCM and
// lifecycle events and posts them across the world boundary; this script is the
// only context with chrome.runtime, so it:
//   1. publishes the worklet's extension URL to the MAIN world (via the DOM,
//      the only shared surface — window globals don't cross worlds), and
//   2. forwards PCM frames and participant-left to the background over a
//      long-lived port, tagging PCM with its platform for the source label.
export default defineContentScript({
  matches: [
    "https://meet.google.com/*",
    "https://*.zoom.us/*",
    "https://teams.microsoft.com/*",
    ...(import.meta.env.WXT_DEV_LOCALHOST ? ["http://localhost/*", "http://127.0.0.1/*"] : []),
  ],
  runAt: "document_start",
  main() {
    console.log("[ears] content relay loaded on", location.host);

    // Hand the worklet URL to the MAIN world (it has no chrome.runtime).
    document.documentElement.dataset.earsWorklet = browser.runtime.getURL("/pcm-worklet.js");

    // Dedicated PCM/lifecycle port to the background.
    const port = browser.runtime.connect({ name: "pcm" });
    // participantId → platform, learned from participant-joined (which precedes
    // the participant's first PCM), so PCM frames can carry their platform.
    const platforms = new Map<string, Platform>();

    window.addEventListener("message", (event: MessageEvent) => {
      if (event.source !== window) return; // only same-window
      if (!isMainEnvelope(event.data)) return;
      relay(event.data.msg, port, platforms);
    });
  },
});

function relay(
  msg: MainMessage,
  port: ReturnType<typeof browser.runtime.connect>,
  platforms: Map<string, Platform>,
): void {
  switch (msg.kind) {
    case "participant-joined":
      platforms.set(msg.participantId, msg.platform);
      console.log(`[ears/relay] joined ${msg.participantId} gen${msg.generation} (${msg.platform})`);
      break;
    case "participant-left":
      platforms.delete(msg.participantId);
      post(port, { type: "left", participantId: msg.participantId });
      console.log(`[ears/relay] left ${msg.participantId} gen${msg.generation}`);
      break;
    case "status":
      console.log(`[ears/relay] status: ${msg.text}`);
      break;
    case "pcm": {
      const platform = platforms.get(msg.participantId);
      if (!platform) return; // no join seen yet; drop until identity is known
      const bytes = new Uint8Array(msg.samples.buffer, msg.samples.byteOffset, msg.samples.byteLength);
      post(port, { type: "pcm", participantId: msg.participantId, platform, b64: bytesToBase64(bytes) });
      break;
    }
  }
}

function post(port: ReturnType<typeof browser.runtime.connect>, msg: PortMessage): void {
  // The port dies when the extension reloads/updates while this tab lives on
  // ("disconnected port" / "Extension context invalidated"). Swallow it — the
  // stale content script stops emitting; a tab reload re-wires to the new SW.
  try {
    port.postMessage(msg);
  } catch {
    /* port disconnected — extension context gone; ignore until tab reload */
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}
