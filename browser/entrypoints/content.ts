import { defineContentScript } from "#imports";
import { browser } from "wxt/browser";
import { CAPTURE_ENABLED_KEY, resolveCaptureToggleState } from "../lib/capture-toggle";
import { ReconnectingPort } from "../lib/pcm-port";
import {
  isMainEnvelope,
  postToMain,
  type MainMessage,
  type Platform,
} from "../lib/protocol";

// Isolated-world relay. The MAIN-world hook (hook.content.ts) generates PCM and
// lifecycle events and posts them across the world boundary; this script is the
// only context with chrome.runtime, so it:
//   1. publishes the worklet's extension URL to the MAIN world (via the DOM,
//      the only shared surface — window globals don't cross worlds),
//   2. reads the capture toggle from storage.local and mirrors it (and every
//      later change) into the MAIN world as a `capture-state` control message —
//      the MAIN world has no storage access of its own, and
//   3. forwards PCM frames and participant-left to the background over a
//      long-lived port (lazily reconnected if the service worker respawns —
//      see pcm-port.ts), tagging PCM with its platform for the source label.
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

    // Mirror the persisted capture toggle into the MAIN world, now and on
    // every change. postMessage delivery is async, so even though both content
    // scripts run at document_start, the hook's listener is registered by the
    // time the initial state arrives.
    const publishToggle = (raw: unknown) =>
      postToMain({ kind: "capture-state", enabled: resolveCaptureToggleState(raw) });
    browser.storage.local
      .get(CAPTURE_ENABLED_KEY)
      .then((v) => publishToggle((v as Record<string, unknown>)[CAPTURE_ENABLED_KEY]))
      .catch(() => publishToggle(undefined)); // unreadable ⇒ default (on)
    browser.storage.local.onChanged?.addListener?.((changes) => {
      const c = changes[CAPTURE_ENABLED_KEY];
      if (c) publishToggle(c.newValue);
    });

    // Lifecycle facts this document knows, mirrored from the hook's messages:
    // the live meeting and current participants. This is the durable copy of
    // what the MV3 service worker holds only in memory — the worker can be
    // evicted mid-call and respawn empty, so the relay replays these to every
    // fresh port (see ReconnectingPort's onReconnect).
    const state: RelayState = { participants: new Map(), liveMeeting: null };

    // Dedicated PCM/lifecycle port to the background.
    const port = new ReconnectingPort(
      () => browser.runtime.connect({ name: "pcm" }),
      (post) => {
        if (state.liveMeeting) post({ type: "meeting-started", ...state.liveMeeting });
        for (const [participantId, p] of state.participants) {
          post({
            type: "joined",
            participantId,
            platform: p.platform,
            ...(p.displayName ? { displayName: p.displayName } : {}),
          });
        }
        console.log(
          `[ears/relay] replayed to respawned worker: ` +
            `meeting=${state.liveMeeting?.externalMeetingId ?? "none"}, ` +
            `${state.participants.size} participant(s)`,
        );
      },
    );

    window.addEventListener("message", (event: MessageEvent) => {
      if (event.source !== window) return; // only same-window
      if (!isMainEnvelope(event.data)) return;
      relay(event.data.msg, port, state);
    });
  },
});

interface RelayState {
  // participantId → identity, learned from participant-joined (which precedes
  // the participant's first PCM), so PCM frames can carry their platform and
  // reconnect replays can re-teach the roster.
  participants: Map<string, { platform: Platform; displayName?: string }>;
  liveMeeting: { platform: Platform; externalMeetingId: string } | null;
}

function relay(msg: MainMessage, port: ReconnectingPort, state: RelayState): void {
  switch (msg.kind) {
    case "participant-joined":
      state.participants.set(msg.participantId, {
        platform: msg.platform,
        ...(msg.displayName ? { displayName: msg.displayName } : {}),
      });
      // Forward identity (display name included) so the background can
      // upsert the daemon meeting's attendee roster.
      port.post({
        type: "joined",
        participantId: msg.participantId,
        platform: msg.platform,
        ...(msg.displayName ? { displayName: msg.displayName } : {}),
      });
      console.log(`[ears/relay] joined ${msg.participantId} gen${msg.generation} (${msg.platform})`);
      break;
    case "participant-left":
      state.participants.delete(msg.participantId);
      port.post({ type: "left", participantId: msg.participantId });
      console.log(`[ears/relay] left ${msg.participantId} gen${msg.generation}`);
      break;
    case "status":
      console.log(`[ears/relay] status: ${msg.text}`);
      break;
    case "meeting-started":
      state.liveMeeting = { platform: msg.platform, externalMeetingId: msg.externalMeetingId };
      port.post({
        type: "meeting-started",
        platform: msg.platform,
        externalMeetingId: msg.externalMeetingId,
      });
      console.log(`[ears/relay] meeting started: ${msg.platform}/${msg.externalMeetingId}`);
      break;
    case "meeting-ended":
      state.liveMeeting = null;
      port.post({
        type: "meeting-ended",
        platform: msg.platform,
        externalMeetingId: msg.externalMeetingId,
      });
      console.log(`[ears/relay] meeting ended: ${msg.platform}/${msg.externalMeetingId}`);
      break;
    case "pcm": {
      const platform = state.participants.get(msg.participantId)?.platform;
      if (!platform) return; // no join seen yet; drop until identity is known
      const bytes = new Uint8Array(msg.samples.buffer, msg.samples.byteOffset, msg.samples.byteLength);
      port.post({ type: "pcm", participantId: msg.participantId, platform, b64: bytesToBase64(bytes) });
      break;
    }
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
