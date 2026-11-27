import { defineBackground } from "#imports";
import { browser } from "wxt/browser";
import { EarsSocket, type TransportStatus } from "../lib/transport";
import { ControlSocket } from "../lib/control-transport";
import { SessionTracker, type BadgeState, type SessionState } from "../lib/session-tracker";
import { applyActionBadge } from "../lib/action-badge";
import { KEEPALIVE_ALARM, KeepaliveTracker } from "../lib/keepalive";
import { DEBUG_LOG_KEY, PERF_ENABLED_KEY, resolvePerfToggleState } from "../lib/capture-toggle";
import {
  parseSiteHookPatterns,
  SITE_HOOK_SCRIPT_IDS,
  SITE_HOOKS_KEY,
  siteHookScripts,
} from "../lib/site-hooks";
import { createBatcher, installConsoleTap, type LogEntry } from "../lib/debug-log";
import {
  appendEntries,
  appendPerfRecords,
  clearEntries,
  clearPerfRecords,
  readAllEntries,
  readAllPerfRecords,
} from "../lib/log-store";
import { PerfCollector, type PerfRecord } from "../lib/perf";
import type { PortMessage } from "../lib/protocol";
import { realTimers } from "../lib/call-gate";
import { StartupSummary } from "../lib/startup-summary";
import {
  composeBadgeState,
  emptyBackgroundPortState,
  reducePortDisconnect,
  reducePortMessage,
  reduceStreamOpened,
  runBackgroundEffects,
  type BackgroundSinks,
} from "../lib/background-core";

// Background context: owns the two WebSockets to earsd. The ingest socket
// accepts the "pcm" port from the isolated relay, decodes each frame, and
// hands it to the transport, which lazily ingest.opens a stream per
// participant and streams binary PCM. The control socket
// (ws://127.0.0.1:<port>/control) carries session commands: the
// SessionTracker resolves each started meeting to a daemon-owned session UUID
// and drives its lifecycle (including the popup's pause-transcription toggle
// — capture is never touched, sessions are metadata over the ring buffer).
//
// Chrome runs this as a suspendable MV3 service worker; Firefox as a
// persistent background page. Everything here is written for the weaker
// (Chrome) guarantee: KeepaliveTracker keeps a chrome.alarms keepalive armed
// only while capture is live (silence produces no socket traffic, so
// WebSocket-activity keepalive alone can't be relied on), and persists the
// live flag to storage.session so a respawned worker re-arms it. The rest
// of respawn recovery is free: this module's top level reconnects both
// sockets, streams re-open lazily on the next PCM frame, and the content
// relay re-establishes its port on the next post (pcm-port.ts).

const DEFAULT_PORT = 47811;
const PORT_STORAGE_KEY = "earsdPort";
const DEFAULT_CONTROL_PORT = 47812;
const CONTROL_PORT_STORAGE_KEY = "earsdControlPort";

export default defineBackground(() => {
  // Tap the console from the first line, before the debug flag is read: a
  // worker start's own lines (and the event that woke it) arrive before the
  // storage read resolves. They wait here and go to the ring only if debug
  // logging turns out to be on.
  let earlyEntries: LogEntry[] | null = [];
  const tapSink = (e: LogEntry): void => {
    if (earlyEntries) earlyEntries.push(e);
    else if (debugLogging) logBatch.push(e);
  };
  let untap: (() => void) | null = installConsoleTap("bg", tapSink);

  // One debug-log line per worker start instead of eight (startup-summary.ts).
  const startup = new StartupSummary((line) => console.debug(line), realTimers);

  // ── Badge state: transport status composed with session state ─────────────
  // Transport problems win outright; otherwise the session layer's
  // recording/paused/transcribing, else plain "connected".
  let status: TransportStatus = "disconnected";
  let sessionState: SessionState = "idle";

  function badgeState(): BadgeState {
    return composeBadgeState(status, sessionState);
  }

  function broadcastStatus(): void {
    const state = badgeState();
    // Reflect the state onto the toolbar icon (badge + tooltip), so it's
    // visible without opening the popup.
    applyActionBadge(browser.action, state);
    // Best-effort: tell any open popup. Ignored if none is listening.
    browser.runtime
      .sendMessage({
        kind: "status",
        status: state,
        session: { active: sessions.sessionActive, paused: sessions.paused },
      })
      .catch(() => {});
  }

  const socket = new EarsSocket(DEFAULT_PORT, (s) => {
    status = s;
    if (!startup.transport("ingest", s)) console.debug(`[ears][bg] transport status: ${s}`);
    broadcastStatus();
  });

  const control = new ControlSocket(DEFAULT_CONTROL_PORT, (s) => {
    if (!startup.transport("control", s)) console.debug(`[ears][bg] control transport status: ${s}`);
  });

  const sessions = new SessionTracker(control, (s) => {
    sessionState = s;
    console.debug(`[ears][bg] session state: ${s}`);
    broadcastStatus();
  });

  // Seed the toolbar icon before the first socket status lands (starts
  // disconnected: clears the badge, sets the "not reachable" tooltip).
  applyActionBadge(browser.action, badgeState());

  // ── Debug logging: tee console → persisted IndexedDB ring ─────────────────
  // The background is the sink: it taps its own console and also receives
  // batched entries forwarded from the content relay and MAIN-world hook (which
  // have no IndexedDB of the extension's origin). All of it lands in a capped
  // ring the popup exports as a file. Gated on DEBUG_LOG_KEY; off by default.
  // The console tap itself is installed at the top of this function; this
  // flag decides whether its entries reach the ring.
  let debugLogging = false;
  const logBatch = createBatcher((entries) => void appendEntries(entries).catch(() => {}));

  /** `announce` is false for the start-up read: the worker-started summary
   * already marks every start, and a line per start is what we're avoiding. */
  function setDebugLogging(on: boolean, announce = true): void {
    // The first call settles the early buffer: ship it or drop it.
    const early = earlyEntries;
    earlyEntries = null;
    if (on && !untap) untap = installConsoleTap("bg", tapSink);
    if (on && !debugLogging) {
      debugLogging = true;
      if (early) for (const e of early) logBatch.push(e);
      if (announce) console.debug("[ears][bg] debug logging enabled");
    } else if (!on && debugLogging) {
      if (announce) console.debug("[ears][bg] debug logging disabled"); // still recorded
      debugLogging = false;
      logBatch.flush();
    }
    if (!on) {
      untap?.();
      untap = null;
    }
  }

  browser.storage.local
    .get(DEBUG_LOG_KEY)
    .then((v) => setDebugLogging((v as Record<string, unknown>)[DEBUG_LOG_KEY] === true, false))
    .catch(() => setDebugLogging(false, false));

  // ── Perf: the store for every context's records, plus this one's own ──────
  // The background is the only context with IndexedDB for the extension origin,
  // so MAIN-world and relay records funnel here. It also owns the ingest socket,
  // which makes it the only place that can see transport back-pressure.
  let perfEnabled = true;
  const perf = new PerfCollector("bg", (records) => void persistPerf(records));
  const transportGroup = perf.group("transport");
  const transport = {
    buffered: transportGroup.gauge("buffered_bytes"),
    sent: transportGroup.counter("frames_sent"),
    bytes: transportGroup.counter("bytes_sent"),
    dropped: transportGroup.counter("frames_dropped"),
    queued: transportGroup.gauge("frames_queued"),
  };
  socket.perf = transport;

  function persistPerf(records: PerfRecord[]): void {
    if (!perfEnabled || records.length === 0) return;
    void appendPerfRecords(records).catch(() => {});
  }

  function setPerfEnabled(on: boolean): void {
    if (on === perfEnabled) return;
    if (on) {
      perfEnabled = true;
      perf.start(1000);
    } else {
      // Flush BEFORE flipping the gate: persistPerf checks `perfEnabled`, so
      // disabling first would silently drop the final partial interval.
      perf.stop();
      perf.flush();
      perfEnabled = false;
    }
  }

  browser.storage.local
    .get(PERF_ENABLED_KEY)
    .then((v) => {
      perfEnabled = false; // force setPerfEnabled to act on the resolved value
      setPerfEnabled(resolvePerfToggleState((v as Record<string, unknown>)[PERF_ENABLED_KEY]));
    })
    .catch(() => {
      perfEnabled = false;
      setPerfEnabled(true);
    });

  // v2 recovery loop: every (re)connect hands the tracker a fresh snapshot,
  // and it re-declares whatever the DOM says is live (session.start is
  // idempotent). Job telemetry drives the "transcribing" badge with real
  // pipeline state instead of a guessed timer.
  control.onReady = (snapshot, bootChanged) => sessions.onReady(snapshot, bootChanged);
  control.onEvent = (frame) => sessions.jobEvent(frame);

  // browser.storage.session is the browser API (browsing-session-scoped
  // storage), not a concept of ours.
  const tracker = new KeepaliveTracker(browser.alarms, browser.storage.session);

  // ── The pure wiring core (background-core.ts) and its chrome shell ────────
  // Every pcm-port message reduces to (state, effects); the effects name the
  // collaborator calls, executed here against the real SessionTracker,
  // KeepaliveTracker, and EarsSocket.
  let portState = emptyBackgroundPortState();
  const sinks: BackgroundSinks = {
    sessions,
    keepalive: tracker,
    ingest: {
      closeStream: (participantId) => socket.participantLeft(participantId),
      sendPcm: (participantId, platform, pcm, externalId, stamp) =>
        socket.sendPcm(participantId, platform, pcm, externalId, stamp),
      sendAttribution: (events, platform, externalId) =>
        socket.sendAttribution(events, platform, externalId),
      sendCaptureFailed: (participantId, platform, reason, externalId) =>
        socket.sendCaptureFailed(participantId, platform, reason, externalId),
    },
  };

  socket.onStreamOpened = (participantId, platform) =>
    runBackgroundEffects(reduceStreamOpened(portState, participantId, platform), sinks);
  // Respawn path: re-arm the keepalive if capture was live when the old
  // worker died (and clear any stale alarm if not).
  void tracker.restore();

  // The alarm's job is done by firing: the event resets the worker's idle
  // timer (or respawns a dead worker, whose top level then reconnects).
  // Any alarm is logged, not only the keepalive: an alarm is one of the
  // events that can wake the worker, and the start-up summary names it.
  browser.alarms.onAlarm.addListener((alarm) => {
    startup.event(`alarm ${alarm.name}`);
    if (startup.collecting) return;
    if (alarm.name === KEEPALIVE_ALARM) console.debug("[ears][bg] keepalive tick");
    else console.debug(`[ears][bg] alarm: ${alarm.name}`);
  });

  // Apply the configured ports, then connect both sockets.
  browser.storage.local
    .get([PORT_STORAGE_KEY, CONTROL_PORT_STORAGE_KEY])
    .then((v) => {
      const record = v as Record<string, unknown>;
      const p = Number(record[PORT_STORAGE_KEY]);
      if (Number.isInteger(p) && p > 0) socket.setPort(p);
      const cp = Number(record[CONTROL_PORT_STORAGE_KEY]);
      if (Number.isInteger(cp) && cp > 0) control.setPort(cp);
      socket.connect();
      control.connect();
    })
    .catch(() => {
      socket.connect();
      control.connect();
    });

  // React to a port change from the options/popup UI.
  browser.storage.local.onChanged?.addListener?.((changes) => {
    const c = changes[PORT_STORAGE_KEY];
    if (c && Number.isInteger(Number(c.newValue))) socket.setPort(Number(c.newValue));
    const cc = changes[CONTROL_PORT_STORAGE_KEY];
    if (cc && Number.isInteger(Number(cc.newValue))) control.setPort(Number(cc.newValue));
    const dl = changes[DEBUG_LOG_KEY];
    if (dl) setDebugLogging(dl.newValue === true);
    const pf = changes[PERF_ENABLED_KEY];
    if (pf) setPerfEnabled(resolvePerfToggleState(pf.newValue));
    const sh = changes[SITE_HOOKS_KEY];
    if (sh) queueSiteHookSync(sh.newValue);
  });

  // ── Site hooks: runtime content scripts for user-enabled origins ──────────
  // storage.local[SITE_HOOKS_KEY] is the source of truth (the popup writes it);
  // the registration is rebuilt from it on every start and change, keeping only
  // patterns whose host permission is still granted. Syncs are chained so two
  // quick changes can't race into a duplicate-id registration.
  let siteHookSync: Promise<void> = Promise.resolve();

  async function syncSiteHooks(raw: unknown): Promise<void> {
    const scripting = browser.scripting;
    if (!scripting?.registerContentScripts) return; // Firefox MV2: no runtime registration
    const granted: string[] = [];
    for (const pattern of parseSiteHookPatterns(raw)) {
      if (await browser.permissions.contains({ origins: [pattern] })) granted.push(pattern);
    }
    const ids = [...SITE_HOOK_SCRIPT_IDS];
    const existing = await scripting.getRegisteredContentScripts({ ids });
    if (existing.length > 0) await scripting.unregisterContentScripts({ ids: existing.map((s) => s.id) });
    if (granted.length > 0) await scripting.registerContentScripts(siteHookScripts(granted));
    if (!startup.siteHooks(granted)) {
      console.debug(`[ears][bg] site hooks registered on ${granted.length} origin(s)`, granted);
    }
  }

  function queueSiteHookSync(raw: unknown): void {
    siteHookSync = siteHookSync
      .then(() => syncSiteHooks(raw))
      .catch((err) => console.warn("[ears][bg] site hook sync failed:", err));
  }

  const resyncSiteHooksFromStorage = (): void => {
    browser.storage.local
      .get(SITE_HOOKS_KEY)
      .then((v) => queueSiteHookSync((v as Record<string, unknown>)[SITE_HOOKS_KEY]))
      .catch(() => {});
  };
  resyncSiteHooksFromStorage();
  // A grant revoked from the extensions page drops that origin's scripts.
  browser.permissions.onRemoved?.addListener(resyncSiteHooksFromStorage);

  let nextPortId = 0;

  browser.runtime.onConnect.addListener((port) => {
    startup.event(`port ${port.name}`);
    if (port.name !== "pcm") return;
    const portId = `pcm-${nextPortId++}`;
    console.debug(`[ears][bg] pcm port connected (${portId})`);
    port.onMessage.addListener((raw) => {
      const { state, effects } = reducePortMessage(portState, portId, raw as PortMessage);
      portState = state;
      runBackgroundEffects(effects, sinks);
    });
    port.onDisconnect.addListener(() => {
      // Tab closed / navigated away mid-call: close its participants' streams
      // now rather than leaking them on earsd until the socket reconnects —
      // and end its sessions. The keepalive tracker both mutates and answers
      // (which participants are now orphaned), so the shell asks it first and
      // hands the answer to the reducer.
      const orphaned = tracker.portDisconnected(portId);
      const { state, effects } = reducePortDisconnect(portState, portId, orphaned);
      portState = state;
      runBackgroundEffects(effects, sinks);
    });
  });

  // Popup queries and the pause-transcription toggle.
  browser.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    const m = msg as {
      kind?: string;
      paused?: boolean;
      entries?: LogEntry[];
      records?: PerfRecord[];
    };
    startup.event(`message ${m.kind ?? "(no kind)"}`);
    // Debug-log traffic: batches forwarded from the relay/hook, plus the
    // popup's export/clear requests.
    if (m.kind === "log-batch") {
      if (debugLogging && m.entries?.length) void appendEntries(m.entries).catch(() => {});
      return undefined; // fire-and-forget
    }
    // Perf traffic. Separate channel and separate ring from the console log —
    // see perf.ts for why these must not share the console tap.
    if (m.kind === "perf-batch") {
      if (m.records?.length) persistPerf(m.records);
      return undefined; // fire-and-forget
    }
    if (m.kind === "get-perf-log") {
      readAllPerfRecords()
        .then((records) => sendResponse({ records }))
        .catch(() => sendResponse({ records: [] }));
      return true;
    }
    if (m.kind === "clear-perf-log") {
      clearPerfRecords()
        .then(() => sendResponse({ ok: true }))
        .catch(() => sendResponse({ ok: false }));
      return true;
    }
    if (m.kind === "get-debug-log") {
      readAllEntries()
        .then((entries) => sendResponse({ entries }))
        .catch(() => sendResponse({ entries: [] }));
      return true;
    }
    if (m.kind === "clear-debug-log") {
      clearEntries()
        .then(() => sendResponse({ ok: true }))
        .catch(() => sendResponse({ ok: false }));
      return true;
    }
    if (m.kind === "get-status") {
      sendResponse({
        status: badgeState(),
        session: { active: sessions.sessionActive, paused: sessions.paused },
      });
      return true;
    }
    if (m.kind === "set-transcription-paused") {
      void sessions
        .setPaused(m.paused === true)
        .then(() => broadcastStatus())
        .catch((err) => console.warn("[ears][bg] pause toggle failed:", err));
      sendResponse({ ok: true });
      return true;
    }
    return undefined;
  });
});
