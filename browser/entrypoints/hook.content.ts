import { defineContentScript } from "#imports";
import { claimEpoch } from "../lib/epoch";
import { installHook, hookDebugState, livePeerConnections, liveTracks } from "../lib/rtc-hook";
import { setMeetGraphSinks, stopMeetGraphProbe } from "../lib/meet-webaudio-probe";
import { initCapture, captureDebugState, __devCaptureStream } from "../lib/audio-tap";
import {
  attributionDebugState,
  exportAttributionLog,
  setAttributionPlatform,
} from "../lib/attribution-recorder";
import { mainPerf } from "../lib/perf-main";
import { selectAdapter, type PlatformAdapter } from "../lib/identity/adapter";
import { MeetMeetingIdWatcher } from "../lib/identity/meet-meeting-id";
import { MeetMeetingTitleWatcher } from "../lib/identity/meet-meeting-title";
import { startMeetSpeakingWatch } from "../lib/identity/meet-speaking-dom";
import { isControlEnvelope, isMainEnvelope, postToIsolated, type Platform } from "../lib/protocol";
import { createBatcher, installConsoleTap } from "../lib/debug-log";
import { perfTag, setPerfState } from "../lib/perf-main";
import { parseZoomMeetingId } from "../lib/identity/zoom";
import { TeamsMeetingIdWatcher, type TeamsIdSources } from "../lib/identity/teams-meeting-id";
import { TeamsMeetingTitleWatcher } from "../lib/identity/teams-meeting-title";
// Side-effect imports: each adapter registers itself with selectAdapter.
import "../lib/identity/meet";
import "../lib/identity/zoom";
import "../lib/identity/teams";
import "../lib/identity/daily";
import { DailyAudioCheck, parseDailyRoom } from "../lib/identity/daily";
import { platformForHost } from "../lib/site-hooks";

// MAIN-world hook. Registered as a content script so the browser runs it at
// document_start, in the page realm, BEFORE any page script — no fetch race.
// This is what wins the constructor race against Zoom's bootstrap caching
// (verified: injectScript's async <script src> lost that race; see journal).
// The isolated-world relay lives in content.ts.
//
// Capture on/off gate (Phase 7). The toggle lives in storage.local
// (capture-toggle.ts), which this MAIN-world script cannot read — so the hook
// installs unconditionally (passive: it only registers tracks, captures
// nothing) and capture WAITS for content.ts to post the persisted toggle
// state across the world boundary as a `capture-state` control message.
// Chosen over the alternatives because:
//   - The hook must install at document_start regardless of the toggle: if it
//     skipped installation while off, toggling ON mid-call could never work
//     (the page has long since cached the native constructor — Zoom-style).
//     With the hook always resident, enabling capture just starts an epoch,
//     which adopts the hook's live-track registry — mid-call ON is seamless.
//   - Waiting for the async storage read costs nothing: startEpoch() replays
//     liveTracks() on start, so tracks arriving before the state message are
//     picked up then, not lost.
// Toggling OFF claims a fresh epoch WITHOUT starting capture on it: every
// existing pipeline's isCurrentEpoch() check goes false (no new tracks) and
// the superseded epoch's teardown stops the live ones — the exact same
// supersede path a re-injection uses, no new machinery in audio-tap.ts.
export default defineContentScript({
  matches: [
    "https://meet.google.com/*",
    "https://*.zoom.us/*",
    "https://teams.microsoft.com/*",
    "https://*.daily.co/*",
    // Dev harness (dev/); stripped unless WXT_DEV_LOCALHOST is set at build.
    ...(import.meta.env.WXT_DEV_LOCALHOST ? ["http://localhost/*", "http://127.0.0.1/*"] : []),
  ],
  runAt: "document_start",
  world: "MAIN",
  // See content.ts: the hook has to reach the frame that actually constructs
  // the RTCPeerConnection, which on Zoom is not the top one.
  allFrames: true,
  main() {
    installHook();
    // Meet audio-graph probe plumbing (rtc-hook.ts §graph probe). rtc-hook
    // cannot import perf-main or audio-tap (audio-tap imports rtc-hook), so
    // this realm's entrypoint — which already imports both — injects the two
    // capabilities the probe needs: shipping records into the perf ring, and
    // feeding a bridged stream into the real capture pipeline.
    setMeetGraphSinks({
      emitPerf: (metric, fields) => mainPerf().emit(metric, fields),
      bridgeStream: (stream, id) => __devCaptureStream(stream, id, "graph-bridge"),
    });

    const host = location.host;
    // Adapters are per-epoch: each startEpoch mints a fresh one, and the
    // epoch's teardown (audio-tap.ts initCapture's supersede chain) disposes
    // it, so identity state is epoch-scoped rather than page-lifetime
    // (attribution refactor R2; bug B10). This page-load instance only
    // establishes the platform and the missing-adapter warning — the first
    // epoch replaces it.
    let adapter = selectAdapter(host);
    const platform = platformForHost(host, adapter);
    if (!adapter) console.warn(`[ears][hook] no identity adapter for ${host} — using speaker-<n>`);

    let captureOn = false;
    let stopMeetingWatch: (() => void) | null = null;
    let stopSpeakingWatch: (() => void) | null = null;
    let lastMeetingId: string | null = null;

    perfTag("platform", platform);
    // Attribution batches are labelled per page, once — evidence recorded
    // before capture ever starts (e.g. collections edges) still ships.
    setAttributionPlatform(platform);

    // On-demand state snapshot for the popup's "Report state" button. Dumps to
    // THIS tab's console (where the [ears] logs already live) so it can be read
    // mid-meeting; also exposed on window for a direct console call.
    const reportDebugState = (): void => {
      const snapshot = {
        ts: new Date().toISOString(),
        host,
        platform,
        captureOn,
        meetingId: lastMeetingId,
        ...hookDebugState(),
        capture: captureDebugState(),
        attribution: attributionDebugState(),
      };
      console.debug("[ears][debug][state]", snapshot);
    };
    (window as unknown as { __earsReportState?: () => void }).__earsReportState = reportDebugState;
    // On-demand export of the attribution flight recorder's per-call ring as
    // JSONL — call from this tab's DevTools console mid- or post-call:
    //   copy(__earsExportAttribution())
    (window as unknown as { __earsExportAttribution?: () => string }).__earsExportAttribution =
      exportAttributionLog;

    // Debug logging: tap the console and forward entries to the isolated relay
    // (which ships them to the background store). This realm is the page's own,
    // so the tap sees the host site's console too — keep only our `[ears]…`
    // entries. Gated by the debug-log-state control message below.
    const hookLog = createBatcher((entries) => postToIsolated({ kind: "log", entries }));
    let hookUntap: (() => void) | null = null;
    const setDebugLogging = (on: boolean): void => {
      if (on && !hookUntap) {
        hookUntap = installConsoleTap("hook", (e) => {
          if (e.msg.startsWith("[ears]")) hookLog.push(e);
        });
      } else if (!on && hookUntap) {
        hookUntap();
        hookUntap = null;
        hookLog.flush();
      }
    };

    window.addEventListener("message", (event: MessageEvent) => {
      if (event.source !== window) return; // only same-window
      if (!isControlEnvelope(event.data)) return;
      const msg = event.data.msg;
      if (msg.kind === "report-state") {
        reportDebugState();
        return;
      }
      if (msg.kind === "debug-log-state") {
        setDebugLogging(msg.enabled);
        return;
      }
      if (msg.kind === "perf-state") {
        setPerfState(msg.enabled, msg.detail);
        return;
      }
      if (msg.kind !== "capture-state" || msg.enabled === captureOn) return;
      captureOn = msg.enabled;
      if (captureOn) {
        // Fresh adapter for the fresh epoch — the previous epoch's teardown
        // disposed its adapter, and a disposed adapter is inert by contract.
        adapter = selectAdapter(host);
        startEpoch(platform, adapter);
        stopMeetingWatch = startMeetingWatch(platform, (id) => {
          lastMeetingId = id;
          perfTag("meeting", id);
        });
        // Meet speaking-ring → per-turn device onsets for the identity
        // correlator (meet-speaking-dom.ts). Meet-only by adapter contract.
        if (platform === "meet" && adapter?.onDeviceSpeaking) {
          stopSpeakingWatch = startMeetSpeakingWatch((deviceId, at) => {
            try {
              // Reads the current binding, not a capture: a dev re-inject
              // swaps the adapter without restarting this watch.
              adapter?.onDeviceSpeaking?.(deviceId, at);
            } catch {
              // identity is best-effort; a bad onset must never reach the page
            }
          });
        }
      } else {
        stopCapture();
        stopMeetingWatch?.();
        stopMeetingWatch = null;
        stopSpeakingWatch?.();
        stopSpeakingWatch = null;
        lastMeetingId = null;
        perfTag("meeting", undefined);
      }
    });

    // Dev-only: simulate a re-injection (new epoch in the same realm) so the
    // harness can verify the capture-epoch handoff doesn't double streams.
    if (import.meta.env.WXT_DEV_LOCALHOST) {
      const dev = window as unknown as {
        __earsDevReinit?: () => void;
        __earsDevCapture?: (stream: MediaStream, id: string) => void;
      };
      dev.__earsDevReinit = () => {
        if (!captureOn) return;
        // Same per-epoch adapter rule as the real toggle path: the superseded
        // epoch's teardown disposes the adapter it was given.
        adapter = selectAdapter(host);
        startEpoch(platform, adapter);
      };
      dev.__earsDevCapture = (stream, id) => __devCaptureStream(stream, id);
    }
  },
});

function startEpoch(platform: Platform, adapter: PlatformAdapter | null): void {
  const epoch = claimEpoch();
  initCapture({ epoch, platform, adapter });
}

/** See the gate comment above: fresh unowned epoch + superseded teardown. */
function stopCapture(): void {
  claimEpoch();
  (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
  // The graph probe attaches analysers to Meet's own worklets, and an output
  // connection keeps an AudioWorkletNode actively processing. An idle
  // extension must not hold those (and the WASM decoder behind each) alive —
  // monitoring re-arms on the next worklet Meet constructs.
  stopMeetGraphProbe();
  console.debug("[ears][hook] capture disabled — epoch released, pipelines torn down");
}

// How long the meeting-id watcher stays quiet before logging its one
// soft-fail warning. It keeps watching afterwards — the id can still resolve
// late (e.g. tiles mounting slowly) and capture is never gated on it.
const MEETING_ID_POLL_MS = 1000;
const MEETING_ID_SOFT_FAIL_MS = 15_000;

// How long the title watcher keeps polling for a meeting name. Calendar
// names usually appear within seconds of join; past this the call is treated
// as unnamed and the daemon's own default (identity → Meet id) stands.
const MEETING_TITLE_WATCH_MS = 60_000;

/**
 * Meeting start/end marking (Meet only today). Watches both external-id
 * surfaces — tile DOM polling, plus the participant-joined traffic audio-tap
 * already posts (which carries collections-upgraded device ids) — and fires
 * `meeting-started` once the spaces/<space> id resolves; the returned stop
 * function fires `meeting-ended` (capture toggled off, teardown). Soft-fails
 * by design: an unresolved id logs once and skips marking; capture is never
 * blocked or delayed (identity's standing contract, see meet.ts).
 *
 * The meeting's *name* is watched on the same interval. It rides along on
 * `meeting-started` when it is already known at declare time, and arrives as
 * `meeting-renamed` when it resolves later (calendar names often do) — which
 * the background turns into a compare-and-set `session.rename`. No name found
 * sends no title at all.
 */
function startMeetingWatch(platform: Platform, onMeetingId?: (id: string) => void): () => void {
  if (platform === "zoom") return startZoomMeetingWatch(onMeetingId);
  if (platform === "teams") return startTeamsMeetingWatch(onMeetingId);
  if (platform === "daily") return startDailyMeetingWatch(onMeetingId);
  if (platform !== "meet") return () => {};

  let spaceId: string | null = null;
  let title: string | null = null;

  const titleWatcher = new MeetMeetingTitleWatcher((resolved) => {
    console.debug(`[ears][hook] Meet meeting name resolved: ${resolved}`);
    title = resolved;
    // Only a *late* name needs its own message: an early one is already
    // carried by the `meeting-started` below.
    if (spaceId) {
      postToIsolated({
        kind: "meeting-renamed",
        platform,
        externalMeetingId: spaceId,
        title: resolved,
      });
    }
  });

  const watcher = new MeetMeetingIdWatcher((resolvedSpaceId) => {
    console.debug(`[ears][hook] Meet meeting id resolved: ${resolvedSpaceId}`);
    spaceId = resolvedSpaceId;
    onMeetingId?.(resolvedSpaceId);
    postToIsolated({
      kind: "meeting-started",
      platform,
      externalMeetingId: resolvedSpaceId,
      ...(title ? { title } : {}),
    });
  });

  const onMessage = (event: MessageEvent): void => {
    if (event.source !== window || !isMainEnvelope(event.data)) return;
    const msg = event.data.msg;
    if (msg.kind === "participant-joined") watcher.observeCandidate(msg.participant.id);
  };
  window.addEventListener("message", onMessage);

  const startedAt = Date.now();
  let warned = false;
  // The name is scanned first, so a call whose title is already up at join
  // declares with it rather than declaring and immediately renaming.
  titleWatcher.poll(document);
  watcher.poll(document);
  const interval = setInterval(() => {
    if (!titleWatcher.title && Date.now() - startedAt < MEETING_TITLE_WATCH_MS) {
      titleWatcher.poll(document);
    }
    watcher.poll(document);
    if (watcher.spaceId && (titleWatcher.title || Date.now() - startedAt > MEETING_TITLE_WATCH_MS)) {
      clearInterval(interval);
      return;
    }
    if (!warned && !watcher.spaceId && Date.now() - startedAt > MEETING_ID_SOFT_FAIL_MS) {
      warned = true;
      console.warn(
        "[ears][hook] Meet meeting id has not resolved yet — the meeting can't be marked until it does; capture is unaffected",
      );
    }
  }, MEETING_ID_POLL_MS);

  return () => {
    clearInterval(interval);
    window.removeEventListener("message", onMessage);
    if (spaceId) {
      postToIsolated({ kind: "meeting-ended", platform, externalMeetingId: spaceId });
    }
  };
}

/**
 * Zoom meeting start/end marking. The external id is in the URL, so unlike
 * Meet there is nothing to scrape and no soft-fail path — but the web client's
 * page is up *before* the user joins, so declaring on load alone would start a
 * session (and record the mic) for a call they only glanced at. The declare
 * therefore waits for the hook to see a live `RTCPeerConnection`, which is the
 * first hard evidence Zoom is actually in a call.
 *
 * With `allFrames` this runs in every frame of the client. The PC gate is what
 * keeps that honest: only the frame that really holds the connection declares,
 * and if more than one ever does, `meetingStarted` is idempotent on the
 * external id and folds the extra ports into the one session.
 */
function startZoomMeetingWatch(onMeetingId?: (id: string) => void): () => void {
  const meetingId = parseZoomMeetingId(location.pathname);
  if (!meetingId) return () => {};

  let declared = false;
  const declare = (): boolean => {
    if (declared) return true;
    if (livePeerConnections().size === 0) return false;
    declared = true;
    onMeetingId?.(meetingId);
    postToIsolated({ kind: "meeting-started", platform: "zoom", externalMeetingId: meetingId });
    console.debug(`[ears][hook] Zoom meeting declared: ${meetingId}`);
    return true;
  };

  let interval: ReturnType<typeof setInterval> | null = null;
  // Already connected (re-injection mid-call) declares immediately; otherwise
  // poll until the connection comes up.
  if (!declare()) {
    interval = setInterval(() => {
      if (declare() && interval !== null) clearInterval(interval);
    }, MEETING_ID_POLL_MS);
  }

  return () => {
    if (interval !== null) clearInterval(interval);
    if (declared) {
      postToIsolated({ kind: "meeting-ended", platform: "zoom", externalMeetingId: meetingId });
    }
  };
}

const DAILY_CHECK_MS = 2000;

/**
 * Daily meeting start/end marking, plus the audio check. Runs in the call frame
 * (`<sub>.daily.co/<room>`), where the room is in the URL — Zoom's shape, and
 * the same gate: declare only once a peer connection is live, so a pre-join
 * screen nobody went past records nothing.
 *
 * The audio check runs for the whole call. It logs `[ears][daily]` whenever
 * the connection or track counts change, and warns if Daily plays a remote
 * track the hook never registered — the failure that would otherwise look
 * like a successful mic-only recording (journal #157).
 */
function startDailyMeetingWatch(onMeetingId?: (id: string) => void): () => void {
  const room = parseDailyRoom(location.href);
  if (!room) {
    console.debug("[ears][daily] no room in this frame's URL — not declaring a meeting");
    return () => {};
  }

  const check = new DailyAudioCheck();
  let declared = false;
  const tick = (): void => {
    const pcs = livePeerConnections().size;
    if (!declared && pcs > 0) {
      declared = true;
      onMeetingId?.(room);
      postToIsolated({ kind: "meeting-started", platform: "daily", externalMeetingId: room });
      console.debug(`[ears][daily] meeting declared: ${room}`);
    }
    const elementTrackIds: string[] = [];
    for (const el of document.querySelectorAll("audio,video")) {
      const stream = (el as HTMLMediaElement).srcObject;
      if (stream instanceof MediaStream) {
        for (const t of stream.getAudioTracks()) elementTrackIds.push(t.id);
      }
    }
    const { log, warn } = check.observe(
      {
        peerConnections: pcs,
        hookedTrackIds: [...liveTracks().keys()].map((t) => t.id),
        elementTrackIds,
      },
      Date.now(),
    );
    if (log) console.debug(`[ears][daily] ${log}`);
    if (warn) console.warn(`[ears][daily] ${warn}`);
  };

  tick();
  const interval = setInterval(tick, DAILY_CHECK_MS);
  return () => {
    clearInterval(interval);
    if (declared) {
      postToIsolated({ kind: "meeting-ended", platform: "daily", externalMeetingId: room });
    }
  };
}

/**
 * Teams meeting start/end marking. Teams sits between the other two: the id
 * has to be scraped like Meet's, but there is no participant traffic carrying
 * it, so the DOM is the only surface (teams-meeting-id.ts explains which parts
 * of it and what they cost).
 *
 * Everything — including the scraping — is gated on `livePeerConnections()`
 * being non-empty. That gate does double duty here. It stops a pre-join screen
 * declaring a session and recording the mic for a call nobody joined, exactly
 * as it does for Zoom; and it keeps the watcher off the DOM entirely while the
 * user is just sitting in Teams chat with capture enabled, which is the common
 * state and the one where a per-second document sweep would be pure waste.
 *
 * Live evidence says the payoff is real: unlike Zoom, a Teams call carries an
 * actual `MediaStreamTrack`, and the only thing standing between it and the
 * daemon was the missing session (journal #160). Attribution stays `speaker-N`
 * — teams.ts returns null from `identify()` by design.
 */
function startTeamsMeetingWatch(onMeetingId?: (id: string) => void): () => void {
  const sources: TeamsIdSources = {
    url: location.href,
    documentText: () => document.documentElement.textContent ?? "",
    documentHtml: () => document.documentElement.innerHTML,
  };

  // Resolving *is* declaring here: the poll below only runs once a connection
  // is live, so the id landing is already the last missing condition.
  let declared: string | null = null;
  let declaredAt = 0;
  let title: string | null = null;

  // Same early/late split as Meet: a name known at declare rides on
  // `meeting-started`, a later one goes out as `meeting-renamed`.
  const titleWatcher = new TeamsMeetingTitleWatcher((resolved) => {
    console.debug(`[ears][hook] Teams meeting name resolved: ${resolved}`);
    title = resolved;
    if (declared) {
      postToIsolated({ kind: "meeting-renamed", platform: "teams", externalMeetingId: declared, title: resolved });
    }
  });

  const watcher = new TeamsMeetingIdWatcher((threadId) => {
    declared = threadId;
    declaredAt = Date.now();
    onMeetingId?.(threadId);
    postToIsolated({
      kind: "meeting-started",
      platform: "teams",
      externalMeetingId: threadId,
      ...(title ? { title } : {}),
    });
    console.debug(`[ears][hook] Teams meeting declared: ${threadId}`);
  });

  // Timed from the first live peer connection, not from watch start: capture
  // is often enabled long before a call, and a warning about an unresolved id
  // is only meaningful once there is a call to resolve it from.
  let inCallSince: number | null = null;
  let warned = false;

  const tick = (): boolean => {
    if (livePeerConnections().size === 0) return false;
    inCallSince ??= Date.now();
    // The URL changes as Teams routes between pre-join and the call, so it is
    // re-read each tick rather than captured once.
    sources.url = location.href;
    // The name is scanned first so a title already up at join declares with it.
    titleWatcher.poll(document);
    watcher.poll(sources);
    if (declared) return titleWatcher.title !== null || Date.now() - declaredAt > MEETING_TITLE_WATCH_MS;
    if (!warned && Date.now() - inCallSince > MEETING_ID_SOFT_FAIL_MS) {
      warned = true;
      console.warn(
        "[ears][hook] Teams meeting id has not resolved yet — the meeting can't be marked until it does; capture is unaffected",
      );
    }
    return false;
  };

  let interval: ReturnType<typeof setInterval> | null = null;
  if (!tick()) {
    interval = setInterval(() => {
      if (tick() && interval !== null) clearInterval(interval);
    }, MEETING_ID_POLL_MS);
  }

  return () => {
    if (interval !== null) clearInterval(interval);
    if (declared) {
      postToIsolated({ kind: "meeting-ended", platform: "teams", externalMeetingId: declared });
    }
  };
}
