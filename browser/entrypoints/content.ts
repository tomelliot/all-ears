import { defineContentScript } from "#imports";
import { browser } from "wxt/browser";
import {
  CAPTURE_ENABLED_KEY,
  DEBUG_LOG_KEY,
  DEBUG_REPORT_KEY,
  resolveCaptureToggleState,
} from "../lib/capture-toggle";
import { createBatcher, installConsoleTap } from "../lib/debug-log";
import { ReconnectingPort } from "../lib/pcm-port";
import {
  isMainEnvelope,
  postToMain,
  type MainMessage,
  type Platform,
  type RosterEntry,
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
    console.debug("[ears][relay] content relay loaded on", location.host);

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
    // Debug logging: tap this isolated world's console straight to the
    // background store, and mirror the flag into the MAIN world (which can't
    // read storage) so the hook taps too. Entries are batched to one message
    // per second rather than one per line.
    const relayLog = createBatcher((entries) =>
      browser.runtime.sendMessage({ kind: "log-batch", entries }).catch(() => {}),
    );
    let relayUntap: (() => void) | null = null;
    const setDebugLogging = (on: boolean): void => {
      postToMain({ kind: "debug-log-state", enabled: on });
      if (on && !relayUntap) {
        relayUntap = installConsoleTap("relay", (e) => relayLog.push(e));
      } else if (!on && relayUntap) {
        relayUntap();
        relayUntap = null;
        relayLog.flush();
      }
    };
    browser.storage.local
      .get(DEBUG_LOG_KEY)
      .then((v) => setDebugLogging((v as Record<string, unknown>)[DEBUG_LOG_KEY] === true))
      .catch(() => {});

    browser.storage.local.onChanged?.addListener?.((changes) => {
      const c = changes[CAPTURE_ENABLED_KEY];
      if (c) publishToggle(c.newValue);
      // The popup's "Report state" button writes a fresh nonce here; nudge the
      // MAIN world to dump its state to this tab's console.
      if (changes[DEBUG_REPORT_KEY]) postToMain({ kind: "report-state" });
      const dl = changes[DEBUG_LOG_KEY];
      if (dl) setDebugLogging(dl.newValue === true);
    });

    // Lifecycle facts this document knows, mirrored from the hook's messages:
    // the live meeting and current participants. This is the durable copy of
    // what the MV3 service worker holds only in memory — the worker can be
    // evicted mid-call and respawn empty, so the relay replays these to every
    // fresh port (see ReconnectingPort's onReconnect).
    const state: RelayState = { participants: new Map(), roster: new Map(), renames: new Map(), liveMeeting: null };

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
        // Roster names dedupe in the MAIN world (only deltas are ever sent), so
        // a respawned worker would otherwise miss every already-emitted name
        // until Meet changed one. Replay the full accumulated roster here.
        for (const [platform, entries] of groupRosterByPlatform(state.roster)) {
          post({ type: "roster", platform, entries });
        }
        // Renames are one-shot deltas like roster names; replay them too so a
        // respawned worker still joins dead-track sources to named attendees.
        for (const [fromId, r] of state.renames) {
          post({ type: "renamed", platform: r.platform, fromId, toId: r.toId });
        }
        console.debug(
          `[ears][relay] replayed to respawned worker: ` +
            `meeting=${state.liveMeeting?.externalMeetingId ?? "none"}, ` +
            `${state.participants.size} participant(s), ${state.roster.size} roster name(s), ` +
            `${state.renames.size} rename(s)`,
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
  // participantId → resolved roster name, accumulated from participant-roster
  // (identity only, no capture pipeline). Replayed in full on worker respawn
  // because the MAIN world only ever sends deltas (#23).
  roster: Map<string, { platform: Platform; displayName: string }>;
  // fromId → late-identity join (participant-renamed), keyed on the fallback
  // id so a repeat confirmation overwrites rather than duplicates. Replayed on
  // worker respawn for the same reason as the roster.
  renames: Map<string, { platform: Platform; toId: string }>;
  liveMeeting: { platform: Platform; externalMeetingId: string } | null;
}

/** Regroup the accumulated roster back into per-platform entry batches for the
 * `roster` port message. A tab is single-platform in practice, but grouping
 * keeps the wire shape honest if that ever changes. */
function groupRosterByPlatform(
  roster: Map<string, { platform: Platform; displayName: string }>,
): Map<Platform, RosterEntry[]> {
  const byPlatform = new Map<Platform, RosterEntry[]>();
  for (const [participantId, r] of roster) {
    const list = byPlatform.get(r.platform) ?? [];
    list.push({ participantId, displayName: r.displayName });
    byPlatform.set(r.platform, list);
  }
  return byPlatform;
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
      console.debug(`[ears][relay] joined ${msg.participantId} gen${msg.generation} (${msg.platform})`);
      break;
    case "participant-left":
      state.participants.delete(msg.participantId);
      port.post({ type: "left", participantId: msg.participantId });
      console.debug(`[ears][relay] left ${msg.participantId} gen${msg.generation}`);
      break;
    case "participant-roster": {
      // Identity-only names resolved from the platform roster; remember them for
      // respawn replay and forward so the background upserts the daemon roster.
      const fresh = msg.entries.filter(
        (e) => state.roster.get(e.participantId)?.displayName !== e.displayName,
      );
      for (const entry of msg.entries) {
        state.roster.set(entry.participantId, { platform: msg.platform, displayName: entry.displayName });
      }
      if (fresh.length > 0) {
        port.post({ type: "roster", platform: msg.platform, entries: fresh });
        console.debug(
          `[ears][relay] roster ${fresh.length} name(s) (${msg.platform}): ` +
            fresh.map((e) => `${e.participantId}="${e.displayName}"`).join(", "),
        );
      }
      break;
    }
    case "participant-renamed":
      state.renames.set(msg.fromId, { platform: msg.platform, toId: msg.toId });
      port.post({ type: "renamed", platform: msg.platform, fromId: msg.fromId, toId: msg.toId });
      console.debug(`[ears][relay] renamed ${msg.fromId} → ${msg.toId} (${msg.platform})`);
      break;
    case "status":
      console.debug(`[ears][relay] status: ${msg.text}`);
      break;
    case "log":
      // The MAIN-world hook's tapped console entries; hand them straight to
      // the background store (already batched by the hook).
      if (msg.entries.length) {
        browser.runtime.sendMessage({ kind: "log-batch", entries: msg.entries }).catch(() => {});
      }
      break;
    case "capture-failed": {
      // The participant is still in the call but their capture pipeline died;
      // forward it (with the platform learned at join) so the background can
      // attribute the audio gap. Not a participant-left: don't drop the roster.
      const platform = state.participants.get(msg.participantId)?.platform;
      console.warn(`[ears][relay] capture-failed ${msg.participantId} gen${msg.generation}: ${msg.reason}`);
      if (platform) port.post({ type: "capture-failed", participantId: msg.participantId, platform, reason: msg.reason });
      break;
    }
    case "meeting-started":
      state.liveMeeting = { platform: msg.platform, externalMeetingId: msg.externalMeetingId };
      port.post({
        type: "meeting-started",
        platform: msg.platform,
        externalMeetingId: msg.externalMeetingId,
      });
      console.debug(`[ears][relay] meeting started: ${msg.platform}/${msg.externalMeetingId}`);
      break;
    case "meeting-ended":
      state.liveMeeting = null;
      port.post({
        type: "meeting-ended",
        platform: msg.platform,
        externalMeetingId: msg.externalMeetingId,
      });
      console.debug(`[ears][relay] meeting ended: ${msg.platform}/${msg.externalMeetingId}`);
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
