import { defineContentScript } from "#imports";
import { browser } from "wxt/browser";
import {
  CAPTURE_ENABLED_KEY,
  DEBUG_LOG_KEY,
  DEBUG_REPORT_KEY,
  DEBUG_SNAPSHOT_KEY,
  PERF_DETAIL_KEY,
  PERF_ENABLED_KEY,
  resolveCaptureToggleState,
  resolvePerfDetailState,
  resolvePerfToggleState,
} from "../lib/capture-toggle";
import { createBatcher, installConsoleTap } from "../lib/debug-log";
import { ReconnectingPort } from "../lib/pcm-port";
import { Counter, Histogram, PerfCollector } from "../lib/perf";
import { isMainEnvelope, postToMain } from "../lib/protocol";
import {
  emptyRelayState,
  reduceRelay,
  respawnReplay,
  runRelayEffects,
  type RelaySinks,
  type RelayState,
} from "../lib/relay-core";

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
    // Daily's call frame (Cal Video and other embeds) — see identity/daily.ts.
    "https://*.daily.co/*",
    ...(import.meta.env.WXT_DEV_LOCALHOST ? ["http://localhost/*", "http://127.0.0.1/*"] : []),
  ],
  runAt: "document_start",
  // Zoom's web client nests the call in a same-origin iframe (app.zoom.us
  // /wc/<id>/join, one more frame below that), so a top-frame-only injection
  // puts the relay in the parent realm while the media lives further down.
  // Each frame gets its own realm, its own epoch, and its own port; the
  // session layer folds the ports of one call back together.
  allFrames: true,
  main() {
    console.debug("[ears][relay] content relay loaded on", location.host);

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

    // ── Perf instrumentation (perf.ts) ────────────────────────────────────────
    // This world both relays the MAIN world's records and collects its own: the
    // base64 hop below runs here, on the same thread as the page, so its cost
    // belongs in the same picture as the capture path's.
    const perf = new PerfCollector("relay", (records) =>
      browser.runtime.sendMessage({ kind: "perf-batch", records }).catch(() => {}),
    );
    const relayGroup = perf.group("relay");
    const relayMetrics: RelayMetrics = {
      encode: relayGroup.histogram("encode"),
      frames: relayGroup.counter("frames"),
      bytes: relayGroup.counter("bytes"),
      dropped: relayGroup.counter("dropped"),
      unknownParticipant: relayGroup.counter("dropped_no_identity"),
      detail: false,
    };
    let perfOn = false;
    const applyPerfState = (enabled: boolean, detail: boolean): void => {
      postToMain({ kind: "perf-state", enabled, detail });
      relayMetrics.detail = enabled && detail;
      if (enabled === perfOn) return;
      perfOn = enabled;
      if (enabled) perf.start(1000);
      else {
        perf.stop();
        perf.flush();
      }
    };

    browser.storage.local
      .get([PERF_ENABLED_KEY, PERF_DETAIL_KEY])
      .then((v) => {
        const record = v as Record<string, unknown>;
        applyPerfState(
          resolvePerfToggleState(record[PERF_ENABLED_KEY]),
          resolvePerfDetailState(record[PERF_DETAIL_KEY]),
        );
      })
      .catch(() => applyPerfState(true, false)); // unreadable ⇒ tier 1 default

    browser.storage.local.onChanged?.addListener?.((changes) => {
      const c = changes[CAPTURE_ENABLED_KEY];
      if (c) publishToggle(c.newValue);
      // The popup's "Report state" button writes a fresh nonce here; nudge the
      // MAIN world to dump its state to this tab's console.
      if (changes[DEBUG_REPORT_KEY]) postToMain({ kind: "report-state" });
      if (changes[DEBUG_SNAPSHOT_KEY]) postToMain({ kind: "send-track-snapshot" });
      const dl = changes[DEBUG_LOG_KEY];
      if (dl) setDebugLogging(dl.newValue === true);
      if (changes[PERF_ENABLED_KEY] || changes[PERF_DETAIL_KEY]) {
        void browser.storage.local
          .get([PERF_ENABLED_KEY, PERF_DETAIL_KEY])
          .then((v) => {
            const record = v as Record<string, unknown>;
            applyPerfState(
              resolvePerfToggleState(record[PERF_ENABLED_KEY]),
              resolvePerfDetailState(record[PERF_DETAIL_KEY]),
            );
          })
          .catch(() => {});
      }
    });

    // Lifecycle facts this document knows, mirrored from the hook's messages:
    // the live meeting and current participants. This is the durable copy of
    // what the MV3 service worker holds only in memory — the worker can be
    // evicted mid-call and respawn empty, so the relay replays these to every
    // fresh port (see ReconnectingPort's onReconnect). The reducer returns a
    // fresh state per lifecycle message, so this binding is reassigned.
    let state: RelayState = emptyRelayState();

    // Dedicated PCM/lifecycle port to the background. A fresh port after a
    // worker respawn is re-taught the call (respawnReplay, relay-core.ts)
    // ahead of the message that triggered the reconnect.
    const port = new ReconnectingPort(
      () => browser.runtime.connect({ name: "pcm" }),
      (post) => {
        const { messages, log } = respawnReplay(state);
        for (const msg of messages) post(msg);
        console.debug(log);
      },
    );

    // The thin shell around the pure reducer (relay-core.ts): reduce, adopt
    // the new state, execute the effect plan against the chrome surfaces.
    const sinks: RelaySinks = {
      post: (msg) => port.post(msg),
      sendRuntimeMessage: (msg) => void browser.runtime.sendMessage(msg).catch(() => {}),
      tagPlatform: (platform) => perf.tag("platform", platform),
      metrics: relayMetrics,
    };
    window.addEventListener("message", (event: MessageEvent) => {
      if (event.source !== window) return; // only same-window
      if (!isMainEnvelope(event.data)) return;
      const { state: next, effects } = reduceRelay(state, event.data.msg, {
        detail: relayMetrics.detail,
        now: () => performance.now(),
      });
      state = next;
      runRelayEffects(effects, sinks);
    });
  },
});

/** The relay hop's instruments, resolved once and handed to the effect runner
 * (relay-core.ts) so the per-frame path never looks anything up. `detail`
 * gates the timing calls themselves — the counters are cheap enough to always
 * run. */
interface RelayMetrics {
  encode: Histogram;
  frames: Counter;
  bytes: Counter;
  dropped: Counter;
  unknownParticipant: Counter;
  detail: boolean;
}

