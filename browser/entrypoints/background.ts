import { defineBackground } from "#imports";
import { browser } from "wxt/browser";
import { EarsSocket, type TransportStatus } from "../lib/transport";
import { ControlSocket } from "../lib/control-transport";
import { MeetingTracker, type BadgeState, type MeetingState } from "../lib/meeting-tracker";
import { applyActionBadge } from "../lib/action-badge";
import { KEEPALIVE_ALARM, SessionTracker } from "../lib/session-state";
import { DEBUG_LOG_KEY } from "../lib/capture-toggle";
import { createBatcher, installConsoleTap, type LogEntry } from "../lib/debug-log";
import { appendEntries, clearEntries, readAllEntries } from "../lib/log-store";
import type { PortMessage } from "../lib/protocol";

// Background context: owns the two WebSockets to earsd. The ingest socket
// accepts the "pcm" port from the isolated relay, decodes each frame, and
// hands it to the transport, which lazily ingest.opens a stream per
// participant and streams binary PCM. The control socket
// (ws://127.0.0.1:<port>/control) carries meeting/session commands: the
// MeetingTracker resolves each started meeting to a daemon-owned meeting UUID
// and opens/closes daemon sessions around it (including the popup's
// pause-transcription toggle — capture is never touched, sessions are
// metadata over the ring buffer).
//
// Chrome runs this as a suspendable MV3 service worker; Firefox as a
// persistent background page. Everything here is written for the weaker
// (Chrome) guarantee: SessionTracker keeps a chrome.alarms keepalive armed
// only while a capture session is active (silence produces no socket traffic,
// so WebSocket-activity keepalive alone can't be relied on), and persists the
// session flag to storage.session so a respawned worker re-arms it. The rest
// of respawn recovery is free: this module's top level reconnects both
// sockets, streams re-open lazily on the next PCM frame, and the content
// relay re-establishes its port on the next post (pcm-port.ts).

const DEFAULT_PORT = 47811;
const PORT_STORAGE_KEY = "earsdPort";
const DEFAULT_CONTROL_PORT = 47812;
const CONTROL_PORT_STORAGE_KEY = "earsdControlPort";

export default defineBackground(() => {
  console.debug("[ears][bg] background loaded");

  // ── Badge state: transport status composed with meeting state ─────────────
  // Transport problems win outright; otherwise the meeting layer's
  // recording/paused/transcribing, else plain "connected".
  let status: TransportStatus = "disconnected";
  let meetingState: MeetingState = "idle";

  function badgeState(): BadgeState {
    if (status !== "connected") return status;
    if (meetingState === "idle") return "connected";
    return meetingState;
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
        meeting: { active: meetings.meetingActive, paused: meetings.paused },
      })
      .catch(() => {});
  }

  const socket = new EarsSocket(DEFAULT_PORT, (s) => {
    status = s;
    console.debug(`[ears][bg] transport status: ${s}`);
    broadcastStatus();
  });

  const control = new ControlSocket(DEFAULT_CONTROL_PORT, (s) => {
    console.debug(`[ears][bg] control transport status: ${s}`);
  });

  const meetings = new MeetingTracker(control, (s) => {
    meetingState = s;
    console.debug(`[ears][bg] meeting state: ${s}`);
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
  let debugLogging = false;
  const logBatch = createBatcher((entries) => void appendEntries(entries).catch(() => {}));
  let untap: (() => void) | null = null;

  function setDebugLogging(on: boolean): void {
    if (on === debugLogging) return;
    debugLogging = on;
    if (on) {
      untap = installConsoleTap("bg", (e) => logBatch.push(e));
      console.debug("[ears][bg] debug logging enabled");
    } else {
      console.debug("[ears][bg] debug logging disabled");
      untap?.();
      untap = null;
      logBatch.flush();
    }
  }

  browser.storage.local
    .get(DEBUG_LOG_KEY)
    .then((v) => setDebugLogging((v as Record<string, unknown>)[DEBUG_LOG_KEY] === true))
    .catch(() => {});

  // v2 recovery loop: every (re)connect hands the tracker a fresh snapshot,
  // and it re-declares whatever the DOM says is live (meeting.start is
  // idempotent). Job telemetry drives the "transcribing" badge with real
  // pipeline state instead of a guessed timer.
  control.onReady = (snapshot, bootChanged) => meetings.onReady(snapshot, bootChanged);
  control.onEvent = (frame) => meetings.jobEvent(frame);

  // participantId → the port (tab) its PCM arrives on, so an ingest-stream
  // open can be routed to that tab's meeting record.
  const participantPorts = new Map<string, string>();
  socket.onStreamOpened = (participantId, platform) => {
    const portId = participantPorts.get(participantId);
    if (portId) meetings.streamOpened(portId, platform, participantId);
  };

  const tracker = new SessionTracker(browser.alarms, browser.storage.session);
  // Respawn path: re-arm the keepalive if a session was active when the old
  // worker died (and clear any stale alarm if not).
  void tracker.restore();

  // The alarm's job is done by firing: the event resets the worker's idle
  // timer (or respawns a dead worker, whose top level then reconnects).
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === KEEPALIVE_ALARM) console.debug("[ears][bg] keepalive tick");
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
  });

  const counts = new Map<string, number>();
  let nextPortId = 0;

  browser.runtime.onConnect.addListener((port) => {
    if (port.name !== "pcm") return;
    const portId = `pcm-${nextPortId++}`;
    console.debug(`[ears][bg] pcm port connected (${portId})`);
    port.onMessage.addListener((raw) => {
      const msg = raw as PortMessage;
      switch (msg.type) {
        case "joined":
          meetings.participantJoined(portId, msg.platform, msg.participantId, msg.displayName);
          return;
        case "roster":
          meetings.rosterUpdate(portId, msg.platform, msg.entries);
          return;
        case "renamed":
          meetings.participantRenamed(portId, msg.platform, msg.fromId, msg.toId);
          return;
        case "left":
          tracker.participantLeft(portId, msg.participantId);
          socket.participantLeft(msg.participantId);
          meetings.participantLeft(portId, msg.participantId);
          participantPorts.delete(msg.participantId);
          return;
        case "capture-failed":
          // A participant's capture died mid-call (e.g. the Meet decoder gave
          // up). The daemon otherwise just sees the source fall silent; log it
          // loudly here so the recorded gap is attributable to a capture
          // failure, not a quiet speaker. The participant stays in the roster
          // (no stream close) — a later renegotiated track re-adopts and
          // resumes capture on its own.
          console.error(
            `[ears][bg] capture failed for ${msg.participantId} (${msg.platform}): ${msg.reason}`,
          );
          return;
        case "meeting-started":
          meetings.meetingStarted(portId, msg.platform, msg.externalMeetingId);
          return;
        case "meeting-ended":
          meetings.meetingEnded(msg.externalMeetingId);
          return;
        case "pcm": {
          tracker.participantActive(portId, msg.participantId, msg.platform);
          participantPorts.set(msg.participantId, portId);
          const pcm = base64ToBytes(msg.b64);
          socket.sendPcm(
            msg.participantId,
            msg.platform,
            pcm,
            meetings.externalIdFor(portId, msg.platform),
          );
          const n = (counts.get(msg.participantId) ?? 0) + 1;
          counts.set(msg.participantId, n);
          if (n % 50 === 0) console.debug(`[ears][bg] forwarded ${n} frames for ${msg.participantId}`);
          return;
        }
      }
    });
    port.onDisconnect.addListener(() => {
      // Tab closed / navigated away mid-call: close its participants' streams
      // now rather than leaking them on earsd until the socket reconnects —
      // and end its meetings (which closes their daemon sessions).
      const orphaned = tracker.portDisconnected(portId);
      for (const id of orphaned) {
        socket.participantLeft(id);
        participantPorts.delete(id);
      }
      meetings.portDisconnected(portId);
      console.debug(
        `[ears][bg] pcm port disconnected (${portId})` +
          (orphaned.length ? ` — closed ${orphaned.length} orphaned stream(s)` : ""),
      );
    });
  });

  // Popup queries and the pause-transcription toggle.
  browser.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    const m = msg as { kind?: string; paused?: boolean; entries?: LogEntry[] };
    // Debug-log traffic: batches forwarded from the relay/hook, plus the
    // popup's export/clear requests.
    if (m.kind === "log-batch") {
      if (debugLogging && m.entries?.length) void appendEntries(m.entries).catch(() => {});
      return undefined; // fire-and-forget
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
        meeting: { active: meetings.meetingActive, paused: meetings.paused },
      });
      return true;
    }
    if (m.kind === "set-transcription-paused") {
      void meetings
        .setPaused(m.paused === true)
        .then(() => broadcastStatus())
        .catch((err) => console.warn("[ears][bg] pause toggle failed:", err));
      sendResponse({ ok: true });
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
